import "@matterlabs/hardhat-zksync-solc";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "hardhat-contract-sizer";
import "hardhat-gas-reporter";
import "hardhat-typechain";
import "solidity-coverage";

// If no network is specified, use the default config
if (!process.env.CHAIN_ETH_NETWORK) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require("dotenv").config();
}

// These are L2/ETH networks defined by environment in `dev.env` of zksync-era default development environment
// const DEFAULT_L2_NETWORK = "http://127.0.0.1:3050";
const DEFAULT_ETH_NETWORK = "http://127.0.0.1:8545";

const zkSyncBaseNetworkEnv =
  process.env.CONTRACTS_BASE_NETWORK_ZKSYNC === "true"
    ? {
        ethNetwork: "localL1",
        zksync: true,
      }
    : {};

export default {
  defaultNetwork: "sepolia",
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 28000,
      },
      outputSelection: {
        "*": {
          "*": ["storageLayout"],
        },
      },
      evmVersion: "cancun",
    },
    eraVersion: "1.0.1",
  },
  zksolc: {
    compilerSource: "binary",
    version: "1.5.11",
    settings: {
      isSystem: true,
    },
  },
  contractSizer: {
    runOnCompile: false,
    except: ["dev-contracts", "zksync/libraries", "common/libraries"],
  },
  paths: {
    sources: "./contracts",
  },
  networks: {
    env: {
      url: process.env.ETH_CLIENT_WEB3_URL?.split(",")[0],
      ...zkSyncBaseNetworkEnv,
    },
    hardhat: {
      allowUnlimitedContractSize: false,
      forking: {
        url: "https://eth-goerli.g.alchemy.com/v2/" + process.env.ALCHEMY_KEY,
        enabled: process.env.TEST_CONTRACTS_FORK === "1",
      },
    },
    sepolia: {
      url: "https://rpc.ankr.com/eth_sepolia/" + process.env.ANKR_KEY,
      accounts: [process.env.GORVENER_PRIVATE_KEY],
      gas: 5000000,
    },
    localL1: {
      url: DEFAULT_ETH_NETWORK,
    },
  },
  etherscan: {
    apiKey: process.env.MISC_ETHERSCAN_API_KEY,
  },
  gasReporter: {
    enabled: true,
  },
};
