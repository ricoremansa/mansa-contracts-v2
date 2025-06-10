import { HardhatUserConfig } from 'hardhat/config';
// import '@nomicfoundation/hardhat-ethers';
import '@nomicfoundation/hardhat-toolbox';
// import '@nomicfoundation/hardhat-foundry';
import '@nomicfoundation/hardhat-verify';
import 'hardhat-contract-sizer';
import '@openzeppelin/hardhat-upgrades';

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.26',
    settings: {
      // evmVersion: 'paris',
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 1,
      },
    },
  },
  paths: {
    sources: './src',
    tests: './test',
  },
  contractSizer: {
    runOnCompile: true,
    only: ["Mansa"],
  },

  networks: {
    arbitrumSepolia: {
      url: 'https://sepolia-rollup.arbitrum.io/rpc',
      allowUnlimitedContractSize: true,
      // accounts: [process.env.PRIVATE_KEY!],
    },
  },
  etherscan: {
    apiKey: {
      arbitrumSepolia: 'JGVCDN3MEB8NJV5QW25MUTQ22J5YIV24GG',
    },
  },
  // sourcify: {
  //   enabled: true,
  // },
};

export default config;
