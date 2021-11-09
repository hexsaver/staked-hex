// hardhat.config.ts
const {
  ALCHEMY_API,
  ETHERSCAN_API_KEY,
  INFURA_API_KEY,
  RINKEBY_PRIVATE_KEY,
} = process.env
import { HardhatUserConfig } from "hardhat/types"
import "@nomiclabs/hardhat-waffle"
import "hardhat-typechain"
import "@nomiclabs/hardhat-etherscan"
// import "tsconfig-paths/register"
const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  solidity: {
    compilers: [
      {
        version: '0.8.9',
        settings: {},
      // }, {
        // version: '0.5.13',
        // settings: {},
      }
    ],
  },
  networks: {
    hardhat: {
      forking: {
        url: `${ALCHEMY_API}`
      }
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${INFURA_API_KEY}`,
      accounts: [`${RINKEBY_PRIVATE_KEY}`],
    },
  },
  etherscan: {
    apiKey: `${ETHERSCAN_API_KEY}`,
  },
};
export default config;