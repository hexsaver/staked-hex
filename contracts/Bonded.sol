// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@hexcommunity/hex/contracts/IHEX.sol";
import "./IStaking.sol";

interface IStaker is IStaking {
  function stakableChange(bool sub, uint96 amount) external;
}

abstract contract IStakable {
  bool public staked;
  uint256 public amountStaked;

  function stakeCanEnd() virtual external view returns (bool);
  function stake(uint256 amount, uint256 endTimestamp) virtual external returns(uint256);
  function stakeFor(address user, uint256 amount, uint256 endTimestamp) virtual external returns(uint256);
  function unstake(uint256 amount, bytes calldata data) virtual external returns(uint256);
  function balanceOf() virtual external view returns(uint256);
}

// actually holds the staked tokens
// balanceOf must be run against this contract
abstract contract HEXBonded is IStakable {
  address _targetContract;
  address _controller;
  uint256 STAKE_ID_PARAM_SIZE = 40;
  uint256 HEART_SIZE = 72;

  constructor(address targetContract_) {
    _controller = msg.sender;
    _targetContract = targetContract_;
  }

  modifier onlyController() {
    require(msg.sender == _controller);
    _;
  }

  function stakeCanEnd() external view override returns (bool) {
    (
      ,
      ,
      ,
      ,
      ,
      uint16 unlockedDay,
    ) = HEXData(_targetContract).stakeLists(address(this), 0);
    return unlockedDay >= IHEXGlobalsAndUtility(_targetContract).currentDay();
  }

  function stake(uint256 amount, uint256 endTimestamp) onlyController external override returns(uint256) {
    uint256 endDay = (endTimestamp - HEXData(_targetContract).LAUNCH_TIME()) / 1 days;
    IHEX(_targetContract).stakeStart(amount, endDay - IHEXGlobalsAndUtility(_targetContract).currentDay());
    // this would not be ok if there were multiple stakes
    // that could happen at same time - not possible with this contract
    amountStaked = amount;
    staked = true;
    (
      ,
      uint72 stakedHearts,
      ,
      ,
      ,
      ,
    ) = HEXData(_targetContract).stakeLists(address(this), 0);
    return uint256(stakedHearts);
  }

  // will never work for hex
  function stakeFor(address /* user */, uint256 amount, uint256 endTimestamp) external override returns(uint256) {
    // user is ignored
    return this.stake(amount, endTimestamp);
  }

  // look into this: https://github.com/ethereum/solidity/issues/12103
  function unstake(uint256 /* amount */, bytes calldata /* data */) onlyController external override returns(uint256) {
    // amount is ignored - hex only unstakes everything
    // index is always zero because only one stake can ever happen at a time
    uint256 bal = IERC20(_targetContract).balanceOf(address(this));
    (
      uint40 stakeId,
      ,
      ,
      ,
      ,
      ,
    ) = HEXData(_targetContract).stakeLists(address(this), 0);
    IHEX(_targetContract).stakeEnd(0, stakeId);
    return IERC20(_targetContract).balanceOf(address(this)) - bal;
  }

  function balanceOf() external view override returns(uint256) {
    uint256 amount = amountStaked;
    if (amount == 0) {
      amount = IERC20(_targetContract).balanceOf(address(this));
    }
    return amount;
  }
}

abstract contract DebtManager is ERC20 {
  using Math for uint256;

  uint256 public constant HEARTS_SIZE = 96;
  uint256 public constant ADDRESS_SIZE = 160;
  uint256 fixedFactor = 1e12;
  address targetContract;

  // will hold pending balances to add to the batch during next iteration
  uint72 heartsBalanceOf;
  uint40 stakeIdParam;
  // properties to update
  // in some cases, we will start the stake after we want to
  // - maybe the runner just doesn't want to spend that much
  uint16 cadence;
  uint256 firstStakeTokens;
  uint8 withdrawBasis;

  uint8 rolloverBasis;
  uint96 payout;
  uint96 contributions;
  uint56 end;
  uint56 batchStart;
  uint256 gasRequiredToStart;
  uint256 stakableAmount;

  uint8 stage = 0;

  // uint256[]=address(160)+hearts(int72)
  // the delta of hearts to add to the batch on the next roll over
  // for each address
  uint256[] redemptions;
  mapping(address => uint256) redemptionAddressIndex;
  uint96 redemptionLoopIndex;
  uint96 redemptionTotal;
  uint96 redeeming;

  uint256[] deposits;
  mapping(address => uint256) depositAddressIndex;
  uint96 depositLoopIndex;
  uint96 depositTotal;
  uint96 depositing;

  // the first stop for hearts when they are deposited in the contract
  // attributedTo is a non tradable asset
  // - can only be minted / burned against the erc20
  mapping(address => uint96) attributedTo;
  mapping(address => uint96) withdrawable;
  mapping(address => bool) earningsAreStaked;

  // this number sets up the ratio of the amount of
  // shares to be created in the future - it is changed only
  // when the supply is distributed or deposited into on a closed loop
  uint256 supplyLimit;
  // the total number of staked tokens at any given time
  uint256 stakedTokens;

  address _treasuryContract;
  address _erc20Contract;
  string private _symbol;
  uint256 _gasRequiredToStart;
  uint256 _totalSupply;

  /**
    * @dev PUBLIC FACING: constructor to intiate the contract
    * deploy the contract by targeting the hex contract
    * @param treasuryContract_ First day of data range
    */
  constructor(address treasuryContract_, address erc20Contract_, string memory symbol_, uint256 gasRequiredToStart_)
  {
    _treasuryContract = treasuryContract_;
    _erc20Contract = erc20Contract_;
    _symbol = symbol_;
    _gasRequiredToStart = gasRequiredToStart_;
  }

  function decimals() public pure override returns (uint8) {
    return 8;
  }

  function name() public view virtual override returns(string memory) {
    string memory late = "";
    if (IStakable(_treasuryContract).staked() && IStakable(_treasuryContract).stakeCanEnd()) {
      late = "*";
    }
    bytes memory baseName = abi.encodePacked("s", symbol());
    return string(abi.encodePacked(baseName, late));
  }

  function mint(uint96 amount) public {
    address staker = _msgSender();
    uint96 attributedShares = attributedTo[staker];
    require(attributedShares >= amount, "DebtManager: attributedTo must be >= than mint amount");
    // write
    _mint(staker, amount);
    // when you mint shares, they are no longer attributed to you
    // in the grand scheme of rolling stakes over
    attributedTo[staker] = attributedShares - amount;
  }

  /**
    * @dev amount of shares as erc20 to burn
    * @param amount uint96 the number of shares to burn (make non tradable)
    */
  function burn(uint96 amount) public {
    address staker = _msgSender();
    // don't need to check amount because if they have the token
    // there are no constraints
    _burn(staker, uint256(amount));
    attributedTo[staker] = attributedTo[staker] + amount;
  }

  /**
    * @dev redeem takes a currently minted token, burns it,
    * and redeems that burned token against the
    */
  function redeem(uint96 amount, uint96 redemption) public {
    address staker = _msgSender();
    // don't attribute to sender, because later, when the stake ends
    // the shares will be converted to underlying asset
    burn(amount);
    setRedemption(staker, redemption);
  }

  function createRedemption(uint96 amount) public {
    setRedemption(_msgSender(), amount);
  }

  function setRedemption(address staker, uint96 amount) internal returns(uint96) {
    // maybe add event
    uint96 index = uint96(redemptionAddressIndex[staker]);
    // redemptions are always in share terms
    uint256 redemption = (uint256(uint160(staker)) << HEARTS_SIZE) | amount;
    // if redemption is already in list, then just update it
    if (redemptions.length > index) {
      uint256 previous = redemptions[index];
      redemptions[index] = redemption;
      (, uint96 prev) = _loadUpdate(previous);
      redemptionTotal = redemptionTotal + amount - prev;
    } else {
      index = uint96(deposits.length);
      redemptions.push(redemption);
      redemptionTotal += amount;
    }
    return index;
  }

  function setDeposit(address staker, uint96 amount) internal returns(uint96) {
    uint96 index = uint96(depositAddressIndex[staker]);
    // deposits are always in token terms
    uint256 deposit = (uint256(uint160(staker)) << HEARTS_SIZE) | amount;
    // if deposit is already in list, then
    if (deposits.length > index) {
      uint256 previous = deposits[index];
      deposits[index] = deposit;
      (, uint96 prev) = _loadUpdate(previous);
      depositTotal = depositTotal + amount - prev;
    } else {
      index = uint96(deposits.length);
      deposits.push(deposit);
      depositTotal += amount;
    }
    return index;
  }

  function _loadUpdate(uint256 update) public pure returns(address, uint96) {
    uint96 hearts = uint96(update);
    address addr = address(uint160(update >> HEARTS_SIZE));
    return (addr, hearts);
  }

  modifier recognizeWork(bool ignoreWork) {
    if (ignoreWork) {
      _;
      return;
    }
    uint256 gas = gasleft();
    _;
    uint256 used = gas - gasleft();
    uint256 earned = payout - contributions;
    uint256 fees = ((earned * 5) / 10000) * used;
    address staker = _msgSender();
    if (earningsAreStaked[staker]) {
      // mint unredeemed credits
      // credits that are rolling over
    } else {
      // partition units (wei, hearts)
    }
  }

  function completeStake(bool ignoreWork) public recognizeWork(ignoreWork) returns(bool) {
    stakeEnd();
    if (gasleft() > 1000000) {
      if (stage == 6) {
        bool _redemptions = distributeRedemptions();
        if (!_redemptions) {
          return _redemptions;
        }
      }
      return applyDeposits();
    }
    return false;
  }
  /**
    * @dev step ends a stake, iterates over needed updates, and then starts a stake
    * @param ignoreWork bool allows the step to bypass work calculations if a runner decides to forgo the payment
    */
  function step(bool ignoreWork) external {
    if (completeStake(ignoreWork) && gasleft() >= gasRequiredToStart) {
      this.stakeStart();
    }
  }

  /**
    * @dev ends a stake if it needs to be
    */
  function stakeEnd() public {
    // stake may already be done
    if (!IStakable(_treasuryContract).staked()) {
      // HEX.stakeEnd was already called
      return;
    }
    // because batches are a single pool, we have to require no stakes to end early
    require(IStakable(_treasuryContract).stakeCanEnd(), "Bonded: unable to end a stake early");
    // nothing called on root contract or good accounting already called
    IStakable(_treasuryContract).unstake(0, bytes(""));
    stakedTokens = 0;
    end = end + cadence + 1;
    stage = 4;
  }

  function applyDeposits() public returns(bool) {
    uint96 depositsLength = uint96(deposits.length);
    require(!IStakable(_treasuryContract).staked(), "DebtManager: cannot apply deposits until stake has ended");
    if (depositsLength > 0) {
      bool notEnoughGas = true;
      uint96 depositingTotal = depositing;
      for (uint96 i = depositLoopIndex; i < depositsLength; i += 1) {
        if (((i + 1) % 5) == 0) {
          notEnoughGas = gasleft() < 500000;
          if (notEnoughGas) {
            depositLoopIndex = i;
            break;
          }
        }
        depositingTotal += applyDeposit(i);
      }
      if (notEnoughGas) {
        depositing = depositingTotal;
        return false;
      }
      depositLoopIndex = 0;
      stakableAmount += depositingTotal;
      depositing = 0;
      delete deposits;
    }
    return true;
  }

  function applyDeposit(uint96 i) internal returns(uint96) {
    (address staker, uint96 units) = _loadUpdate(deposits[i]);
    uint256 stakerShares = uint256(units) * uint256(supplyLimit) / balanceOfAsset();
    uint96 shares = uint96(stakerShares);
    attributedTo[staker] += shares;
    delete depositAddressIndex[staker];
    return shares;
  }

  function distributeRedemptions() public returns(bool) {
    uint256 redemptionsLength = redemptions.length;
    require(!IStakable(_treasuryContract).staked(), "Bonded: cannot attribute updates until unstake occurs");
    require(stage == 5, "Bonded: cannot distribute until stake ends");
    if (redemptionsLength > 0) {
      if (stage != 5) {
        stage = 5;
      }
      bool notEnoughGas = true;
      uint96 redeemingTotal = redeeming;
      for (uint96 i = redemptionLoopIndex; i < redemptionsLength; i += 1) {
        if (((i + 1) % 5) == 0) {
          notEnoughGas = gasleft() < 500000;
          if (notEnoughGas) {
            redemptionLoopIndex = i;
            break;
          }
        }
        redeemingTotal += distributeRedemption(i);
      }
      if (notEnoughGas) {
        redeeming = redeemingTotal;
        return false;
      }
      // reset values to allow start stake to go through
      redemptionLoopIndex = 0;
      stakableAmount -= redeemingTotal;
      redeeming = 0;
      delete redemptions;
      stage = 6;
    }
    return true;
  }

  function distributeRedemption(uint96 i) internal returns(uint96) {
    (address staker, uint96 units) = _loadUpdate(redemptions[i]);

    uint96 current = attributedTo[staker];
    uint96 next = 0;
    if (units < current) {
      next = current - units;
    } else {
      next = 0;
    }
    attributedTo[staker] = next;
    uint96 shares = current - next;
    withdrawable[staker] = shares * uint96(balanceOfAsset()) / uint96(supplyLimit);
    delete redemptionAddressIndex[staker];
    return shares;
  }

  function fee(uint256 a, uint256 basisPoints) public pure returns(uint256) {
    return factor(a, basisPoints, 10000);
  }

  function factor(uint256 base, uint256 up, uint256 down) public pure returns(uint256) {
    return base * up / down;
  }

  /**
    * @dev get the total balance (erc20) applied to this contract
    */
  function balanceOfAsset() public view returns (uint256) {
    return IERC20(_erc20Contract).balanceOf(address(this));
  }

  /**
    * @dev stakeStart starts the stake from this contract
    */
  function stakeStart() external {
    uint256 currentDay = IHEX(_erc20Contract).currentDay();
    require(end <= currentDay, "Bonded: batch has not yet ended");
    uint256 start = end - cadence;
    if (start < currentDay) {
      start = currentDay;
    }
    uint256 duration = end - start;
    uint256 balance = IERC20(_erc20Contract).balanceOf(_treasuryContract);
    // because this is always the same amount of time,
    // the number of shares in the future goes down
    stakedTokens = IStakable(_treasuryContract).stake(balance, duration);
    // for the first stake, the supply limit == the shares
    // shares floats against the total so that we use the ratio to denote ownership
    // over the pool without using %
    if (supplyLimit == 0) {
      supplyLimit = stakedTokens;
    }
    // reset iteration breadcrumbs
    stage = 2;
  }

  /**
    * @dev simply credit previously transferred hearts to a batch
    * @param amount uint96 amount to credit to a batch
    */
  function creditToBatch(uint96 amount) public {
    address staker = _msgSender();
    if (firstStakeTokens > 0) {
      uint96 index = setDeposit(staker, amount);
      if (!IStakable(_treasuryContract).staked()) {
        applyDeposit(index);
      }
    } else {
      // stake has never started - we are in a pending phase
      IERC20(_erc20Contract).transferFrom(staker, _treasuryContract, amount);
      attributedTo[staker] += amount;
      stage = 1; // allows us to skip directly to stakeStart
    }
  }
  function debitFromBatch(uint96 amount) public {
    require(!IStakable(_treasuryContract).staked(), "DebtManager: unable to debit unless batch is not staked");
    address staker = _msgSender();
    attributedTo[staker] = attributedTo[staker] - amount;
    IERC20(_erc20Contract).transferFrom(_treasuryContract, staker, amount);
  }

  function includeFeeInNextStake(bool includeFee) external {
    earningsAreStaked[_msgSender()] = includeFee;
  }
}

contract BondedTokenFactory {
  // create erc20s to be tradable shares for the same, repeating stake
}
