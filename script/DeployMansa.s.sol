// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol"; 
import {Mansa} from "../src/Mansa.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD} from "../test/MockUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployMansa
 * @notice Deployment script for the Mansa tokenized investment contract
 */
contract DeployMansa is Script {
    // Configuration variables - modify these values before deployment
    string private constant TOKEN_NAME = "Mansa Investment Token";
    string private constant TOKEN_SYMBOL = "MIT";
    string private constant MOCK_USD_NAME = "Mock USD";
    string private constant MOCK_USD_SYMBOL = "MUSD";

    // Minimum amounts for investments and withdrawals (in MockUSD decimals - 6)
    uint256 private constant MIN_INVESTMENT = 1000 * 1e6; // 1,000 MockUSD
    uint256 private constant MAX_INVESTMENT = 1000000 * 1e6; // 1,000,000 MockUSD
    uint256 private constant MIN_WITHDRAWAL = 100 * 1e6; // 100 MockUSD
    uint256 private constant MAX_WITHDRAWAL = 500000 * 1e6; // 500,000 MockUSD

    // Initial daily yield in microbips (1/10000 of a basis point)
    // 100000 = 0.01% daily (≈3.65% APY)
    uint256 private constant INITIAL_DAILY_YIELD = 100000;

    function run() external {
        // Get deployment addresses from environment or use defaults
        address deployer = vm.envOr("DEPLOYER", address(msg.sender));
        address custodian = vm.envOr("CUSTODIAN", deployer);
        address admin = vm.envOr("ADMIN", deployer);

        // Start broadcasting transactions
        vm.startBroadcast(deployer);

        // 1. Deploy MockUSD token for testing
        console.log("Deploying MockUSD token...");
        MockUSD mockUsd = new MockUSD();
        console.log("MockUSD deployed at:", address(mockUsd));

        // 2. Deploy Allowlist contract
        console.log("Deploying Allowlist contract...");
        Allowlist allowlist = new Allowlist();
        console.log("Allowlist deployed at:", address(allowlist));

        // 3. Add deployer, custodian, and admin to allowlist
        console.log("Adding addresses to allowlist...");
        allowlist.addToAllowlist(deployer);
        allowlist.addToAllowlist(custodian);
        allowlist.addToAllowlist(admin);
        console.log("Initial addresses added to allowlist");

        // 4. Deploy Mansa contract with MockUSD
        console.log("Deploying Mansa contract...");

        // Deploy da implementação
        Mansa implementation = new Mansa();

        // Encode da chamada de initialize()
        bytes memory initData = abi.encodeCall(
            Mansa.initialize,
            (
                allowlist,
                "Mansa Token",
                "MANSA",
                IERC20(address(mockUsd)),
                custodian
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        console.log("Proxy deployed at:", address(proxy));
        console.log("Implementation deployed at:", address(implementation));

        Mansa mansa = Mansa(address(proxy));

        // 4. Configure Mansa contract with initial settings
        console.log("Configuring Mansa contract...");

        // Set investment/withdrawal limits
        mansa.setMinInvestmentAmount(MIN_INVESTMENT);
        mansa.setMaxInvestmentAmount(MAX_INVESTMENT);
        mansa.setMinWithdrawalAmount(MIN_WITHDRAWAL);
        mansa.setMaxWithdrawalAmount(MAX_WITHDRAWAL);

        // Set yield and open the contract for investments
        mansa.setDailyYieldMicrobip(INITIAL_DAILY_YIELD);
        mansa.setOpen(true);

        // 5. Grant ADMIN_ROLE to admin address if different from deployer
        if (admin != deployer) {
            bytes32 ADMIN_ROLE = mansa.ADMIN_ROLE();
            mansa.grantRole(ADMIN_ROLE, admin);
            console.log("ADMIN_ROLE granted to:", admin);
        }

        // 6. Optionally give control of Allowlist to Mansa contract
        // Uncomment the following if you want Mansa to control the allowlist
        // allowlist.transferOwnership(address(mansa));
        // console.log("Allowlist ownership transferred to Mansa");

        vm.stopBroadcast();

        // Log deployment summary
        // 7. Mint some MockUSD to the deployer for testing
        uint256 initialMintAmount = 10000000 * 1e6; // 10 million Mock USD
        mockUsd.mint(deployer, initialMintAmount);
        console.log("Minted", initialMintAmount / 1e6, "MockUSD to deployer");

        // 8. Approve MockUSD for custodian (to handle withdrawals)
        mockUsd.mint(custodian, initialMintAmount);
        mockUsd.approve(address(mansa), type(uint256).max);
        console.log("Minted", initialMintAmount / 1e6, "MockUSD to custodian");
        console.log("Approved MockUSD for Mansa contract from deployer");

        console.log("\n=== Deployment Summary ===");
        console.log("MockUSD:", address(mockUsd));
        console.log("Allowlist:", address(allowlist));
        console.log("Mansa:", address(mansa));
        console.log("Custodian:", custodian);
        console.log("Admin:", admin);
        console.log("Min Investment:", MIN_INVESTMENT / 1e6, "MockUSD");
        console.log("Max Investment:", MAX_INVESTMENT / 1e6, "MockUSD");
        console.log("Initial Daily Yield:", INITIAL_DAILY_YIELD, "microbips");
        console.log("Contract Open Status:", mansa.open());
    }
}
