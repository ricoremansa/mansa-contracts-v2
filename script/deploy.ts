import 'dotenv/config';
import { command, subcommands, option, run, string } from 'cmd-ts';

import type {
  AddressLike,
  BaseContract,
  ContractFactory,
  Signer,
  TransactionRequest,
} from 'ethers';
import {
  FireblocksWeb3Provider,
  ChainId,
  ApiBaseUrl,
} from '@fireblocks/fireblocks-web3-provider';
import { File } from 'cmd-ts/batteries/fs';
import fs from 'fs/promises';
import {
  Fireblocks,
  BasePath,
  AbiFunction,
  TokenLinkRequestDtoTypeEnum,
} from '@fireblocks/ts-sdk';
import { Mansa } from '../typechain-types';
import * as Contracts from '../typechain-types';
import * as readline from 'readline';
import type * as Hardhat from 'hardhat';
import {
  SmartContracts,
  SmartContractTypes,
} from '../typechain-types/_contracts';
import type { FactoryOptions } from 'hardhat/types';

const privateKeyOption = option({
  type: File,
  long: 'private-key-path',
  short: 'p',
  env: 'FIREBLOCKS_API_PRIVATE_KEY_PATH',
  description: "The path to Fireblocks's private key file",
});

const apiKeyOption = option({
  type: string,
  long: 'api-key',
  short: 'k',
  env: 'FIREBLOCKS_API_KEY',
  description: 'The API key for Fireblocks',
});

const networkOptions = option({
  type: {
    from: async (val: string) => {
      if (val === 'arbitrumSepolia') return val;
      return 'arbitrumSepolia';
    },
  },
  long: 'network',
  short: 'n',
  defaultValue: () => 'arbitrumSepolia',
  env: 'HARDHAT_NETWORK',
  description: 'The network to deploy to',
});

const fireblocksUrl = ApiBaseUrl.Production;

const deployCmd = command({
  name: 'deploy',
  args: {
    privateKeyPath: privateKeyOption,
    apiKey: apiKeyOption,
    network: networkOptions,
  },
  handler: async ({ privateKeyPath, apiKey }) => {
    const privateKey = (await fs.readFile(privateKeyPath))?.toString();

    if (!privateKey) {
      throw new Error('Private key not found');
    }

    const fireblocks = new Fireblocks({
      basePath: `${fireblocksUrl}/v1`,
      apiKey: apiKey,
      secretKey: privateKey,
    });

    const fireblocksProvider = new FireblocksWeb3Provider({
      apiBaseUrl: fireblocksUrl, // If using a sandbox workspace
      privateKey: privateKey,
      apiKey: apiKey,
      vaultAccountIds: 4,
      chainId: ChainId.ARBITRUM_SEPOLIA,

      logTransactionStatusChanges: true, // Verbose logging
      enhancedErrorHandling: true,
      // fallbackFeeLevel: 'MEDIUM',
    });

    process.env.HARDHAT_NETWORK = 'arbitrumSepolia';
    const hardhat = (await import('hardhat')).default;

    await deployContracts({ fireblocks, fireblocksProvider, hardhat }).catch(
      (e) => {
        console.error(e);
      },
    );
  },
});

type Ctx = {
  fireblocks: Fireblocks;
  fireblocksProvider: FireblocksWeb3Provider;
  hardhat: typeof Hardhat;
};

async function deployContracts({
  fireblocks,
  fireblocksProvider,

  hardhat,
}: Ctx) {
  await hardhat.run('compile');
  const ethers = hardhat.ethers;

  const provider = new ethers.BrowserProvider(fireblocksProvider);
  const signer = await provider.getSigner();
  const { deployContract } = initTools(hardhat, signer);

  /**
   * Utility function to deploy a contract, check size and gas estimate, and publish to Fireblocks
   */

  /**
   * Deployment script starts here
   */

  // Constants from the original script
  const TOKEN_NAME = 'Mansa Investment Token';
  const TOKEN_SYMBOL = 'MIT';
  const MOCK_USD_NAME = 'Mock USD';
  const MOCK_USD_SYMBOL = 'MUSD';
  const MIN_INVESTMENT = 1000n * 10n ** 6n; // 1,000 MockUSD
  const MAX_INVESTMENT = 1000000n * 10n ** 6n; // 1,000,000 MockUSD
  const MIN_WITHDRAWAL = 100n * 10n ** 6n; // 100 MockUSD
  const MAX_WITHDRAWAL = 500000n * 10n ** 6n; // 500,000 MockUSD
  const INITIAL_DAILY_YIELD = 100000n; // 0.01% daily (≈3.65% APY)

  // Get deployment addresses
  const deployer = await signer.getAddress();
  const custodian = deployer; // Using deployer as custodian for now
  const admin = deployer; // Using deployer as admin for now

  console.log('---- Stage 1: Deploying base contracts ----');

  // // 1. Deploy MockUSD token
  const mockUsd = await deployContract('MockUSD');
  await addToFireblocks(fireblocks, hardhat, {
    assetName: 'MockUSD',
    address: mockUsd,
    contractName: 'MockUSD',
    type: 'FUNGIBLE_TOKEN',
  });

  // // 2. Deploy Allowlist contract
  const allowlist = await deployContract('Allowlist');

  await addToFireblocks(fireblocks, hardhat, {
    assetName: 'Allowlist',
    address: allowlist,
    contractName: 'Allowlist',
    type: 'TOKEN_UTILITY',
  });

  // // 3. Add deployer, custodian, and admin to allowlist
  console.log('____ Configuring Allowlist contract ____');
  await allowlist.addToAllowlist(deployer);
  // await allowlist.addToAllowlist(custodian);
  // await allowlist.addToAllowlist(admin);

  // 4. Deploy Mansa contract with MockUSD
  console.log('---- Stage 2: Setting up Mansa contract ----');

  const VaultMathLib = await deployContract('VaultMathLib');

  const mansaFactory = await await ethers.getContractFactory('Mansa', {
    signer,
    libraries: {
      VaultMathLib: VaultMathLib,
    },
  });

  const args = (await Promise.all([
    allowlist.getAddress(),
    TOKEN_NAME,
    TOKEN_SYMBOL,
    mockUsd.getAddress(),
    custodian,
  ])) satisfies Parameters<Mansa['initialize']>;

  console.log('Deploying Mansa contract (with proxy)...');
  const mansaDeployment = await hardhat.upgrades.deployProxy(
    mansaFactory,
    args,
    {
      kind: 'uups',
      unsafeAllow: ['external-library-linking'],
    },
  );

  const mansa = await mansaDeployment.waitForDeployment();

  await verifyContract(hardhat, 'Mansa', await mansa.getAddress(), args, true);

  await addToFireblocks(fireblocks, hardhat, {
    assetName: 'Mansa',
    address: mansaDeployment,
    contractName: 'Mansa',
    type: 'FUNGIBLE_TOKEN',
  });
  console.log(
    `Mansa contract deployed to: "${await mansaDeployment.getAddress()}"`,
  );

  // 5. Configure Mansa contract
  console.log('____ Configuring Mansa contract ____');

  // Temporary grant ADMIN_ROLE to admin to set initial parameters
  console.log('Granting ADMIN_ROLE to admin...');
  await mansa.grantRole(await mansa.ADMIN_ROLE(), admin);

  // Set investment/withdrawal limits
  console.log('Setting investment/withdrawal limits...');
  await mansa.setMinInvestmentAmount(MIN_INVESTMENT);
  await mansa.setMaxInvestmentAmount(MAX_INVESTMENT);
  await mansa.setMinWithdrawalAmount(MIN_WITHDRAWAL);
  await mansa.setMaxWithdrawalAmount(MAX_WITHDRAWAL);

  // Set yield and open the contract
  await mansa.setDailyYieldMicrobip(INITIAL_DAILY_YIELD);
  await mansa.setOpen(true);

  console.log(
    '---- Stage 3(final): Minting MockUSD and approving Mansa contract ----',
  );

  // // 7. Mint MockUSD for testing
  const initialMintAmount = 10000000n * 10n ** 6n; // 10 million Mock USD
  await mockUsd.mint(deployer, initialMintAmount);
  console.log('Minted', initialMintAmount / 10n ** 6n, 'MockUSD to deployer');

  // // 8. Mint and approve MockUSD for custodian
  await mockUsd.mint(custodian, initialMintAmount);
  console.log('Minted', initialMintAmount / 10n ** 6n, 'MockUSD to custodian');

  await mockUsd.approve(await mansa.getAddress(), ethers.MaxUint256);
  console.log('Approved MockUSD for Mansa contract from deployer');

  // Log deployment summary
  console.log('\n=== Deployment Summary ===');
  console.log('MockUSD:', await mockUsd.getAddress());
  console.log('Allowlist:', await allowlist.getAddress());
  console.log('Mansa:', await mansa.getAddress());
  console.log('Custodian:', custodian);
  console.log('Admin:', admin);
  console.log('Min Investment:', MIN_INVESTMENT / 10n ** 6n, 'MockUSD');
  console.log('Max Investment:', MAX_INVESTMENT / 10n ** 6n, 'MockUSD');
  console.log(
    'Initial Daily Yield:',
    INITIAL_DAILY_YIELD.toString(),
    'microbips',
  );
  console.log('Contract Open Status:', await mansa.open());
}

/**
 * Initialize tools for deployment
 */
function initTools(hardhat: typeof Hardhat, signer: Signer) {
  const ethers = hardhat.ethers;

  return {
    deployContract: async <T extends SmartContractTypes>(
      contractName: T | string,
      options: {
        factory?: FactoryOptions;
      } = {},
      ...deployArgs: T extends SmartContractTypes
        ? Parameters<SmartContracts[T]['factory']['deploy']>
        : any[]
    ) => {
      const { factory: factoryOptions = {} } = options;

      const factory = await ethers.getContractFactory(contractName, {
        signer,
        ...factoryOptions,
      });

      console.log(`Deploying contract "${contractName}"...`);

      const contract = await factory
        .deploy(...(deployArgs || []), {})
        .catch((e) => {
          console.error(e);
          throw Error('Failed to deploy tx');
        });
      await contract.waitForDeployment();

      console.log(
        `Contract ${contractName} deployed to: "${await contract.getAddress()}"`,
      );

      verifyContract(
        hardhat,
        contractName,
        await contract.getAddress(),
        deployArgs,
      );

      return contract as T extends SmartContractTypes
        ? SmartContracts[T]['contract']
        : BaseContract;
    },
  };
}

async function addToFireblocks(
  fireblocks: Fireblocks,
  hardhat: typeof Hardhat,
  data: {
    assetName: string;
    type?: TokenLinkRequestDtoTypeEnum;
    address: AddressLike;
    contractName: SmartContractTypes;
  },
) {
  const baseAssetId = 'ETH-AETH_SEPOLIA';

  const { assetName: assetId, type = 'TOKEN_UTILITY', contractName } = data;

  const address = await (typeof data.address === 'string'
    ? data.address
    : 'getAddress' in data.address
    ? data.address.getAddress()
    : data.address);

  console.warn(
    `Whitelist the asset "${assetId}" in blockchain "${baseAssetId}": ${address}`,
  );

  const linkResponse = await fireblocks.tokenization
    .link({
      tokenLinkRequestDto: {
        type,
        displayName: assetId,
        contractAddress: address,
        baseAssetId,
      },
    })
    .catch((e) => {
      console.error(e);
      return null;
    });

  const linkId = linkResponse?.data?.id;

  const contractArtifact = await hardhat.artifacts.readArtifact(
    data.contractName,
  );

  await fireblocks.deployedContracts
    .addContractABI({
      addAbiRequestDto: {
        baseAssetId,
        contractAddress: address,
        name: assetId,
        abi: contractArtifact.abi,
      },
    })
    .catch((e) => {
      console.error('Failed to add contract ABI to Fireblocks', e);
    });

  console.log('linkId', linkId || linkResponse?.data);

  // Add Contract to whitelist
  const timestamp = new Date().toISOString();
  const whitelistResponse = await fireblocks.contracts
    .createContract({
      createContractRequest: {
        name: `DEPLOYMENT_${data.assetName.replace(' ', '_')}_${timestamp}`,
      },
    })
    .catch((e) => {
      console.error(e);
      return null;
    });

  const contractId = whitelistResponse?.data?.id;

  if (!contractId) {
    console.warn(
      `Could not create whitelist for contract ${contractName} with address "${address}".`,
    );
    return;
  }

  await fireblocks.contracts
    .addContractAsset({
      contractId,
      assetId: baseAssetId,
      addContractAssetRequest: {
        address,
      },
    })
    .catch((e) => {
      console.error('Failed to add contract to whitelist', e);

      console.warn(
        'Visit https://console.fireblocks.io/v2/tokenization and whitelist the address before continuing',
      );

      const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
      });

      // Wait for user to follow the instructions in the link above
      return new Promise<void>((resolve) => {
        rl.question(
          'Follow the instructions in the link above and press "Enter" to continue...',
          () => {
            rl.close();
            resolve();
          },
        );
      });
    });
}

async function verifyContract(
  hardhat: typeof Hardhat,
  contractName: string,
  address: string,
  deployArgs: unknown[],
  suppressError?: boolean,
) {
  console.log(`Verifying contract ${contractName} at ${address}...`);

  // Verify contract
  await hardhat
    .run('verify:verify', {
      network: 'arbitrumSepolia',
      address,
      constructorArgsParams: deployArgs,
    })
    .catch((e) => {
      if (!suppressError) {
        console.error(e);
        console.warn(
          'Failed to verify contract. Please verify manually using the following command: "npx hardhat verify --network arbitrumSepolia --constructor-args arguments.ts <CONTRACT_ADDRESS>"',
          { contractName, contractAddress: address, deployArgs },
        );
      }
      else {
        console.warn(`Failed to verify contract "${contractName}" at "${address}"`);
      }
    });
}

run(deployCmd, process.argv.slice(2)).then(
  () => {
    process.exit(0);
  },
  (e) => {
    console.error(e);
    process.exit(1);
  },
);
