// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol"; // Import FixedPointMathLib for rpow

import {Mansa} from "../src/Mansa.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "./MockUSD.sol";
import {VaultMathLib} from "../src/VaultMathLib.sol"; // Ensure this import path is correct


contract ERC7540Compliance is Test {
    using FixedPointMathLib for uint256; // Use FixedPointMathLib in tests for calculations

    Allowlist allowlist;
    MockUSD usd;
    Mansa mansaProxy;

    address admin;
    address custodian;
    address investor;

    event Deposit(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    function setUp() public {
        admin = address(this);
        custodian = makeAddr("custodian");
        investor = makeAddr("investor");

        allowlist = new Allowlist();
        allowlist.addToAllowlist(admin);
        allowlist.addToAllowlist(custodian);
        allowlist.addToAllowlist(investor);

        usd = new MockUSD();
        usd.mint(custodian, 10_000_000 * 1e6);

        mansaProxy = new Mansa();
        mansaProxy.initialize(
            allowlist,
            "Mansa Token",
            "MANSA",
            usd,
            custodian
        );

        allowlist.addToAllowlist(address(mansaProxy));

        mansaProxy.grantRole(mansaProxy.ADMIN_ROLE(), admin);
        mansaProxy.setOpen(true);
        mansaProxy.setMinInvestmentAmount(1);
        mansaProxy.setMaxInvestmentAmount(1_000_000 * 1e6);
        mansaProxy.setMinWithdrawalAmount(1);
        mansaProxy.setMaxWithdrawalAmount(1_000_000 * 1e6);

        usd.mint(investor, 1_000_000 * 1e6);

        vm.startPrank(investor);
        usd.approve(address(mansaProxy), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(custodian);
        usd.approve(address(mansaProxy), type(uint256).max);
        vm.stopPrank();
    }

    function testDepositWrapperEmits() public {
        uint256 assets = 1_000 * 1e6; // Assets in USD decimals (6)

        uint256 expectedShares;
        if (mansaProxy.totalAssets() == 0) { // Handle bootstrap case for initial mint
            expectedShares = assets * (10 ** mansaProxy.decimalsOffset());
        } else {
            // Arguments: assets (USD), totalShares (MANSA), totalAssets (USD in vault)
            // VaultMathLib._toShares expects inputs where assets and totalAssets are at asset.decimals,
            // and totalShares at vault.decimals.
            // We need to scale `totalAssets()` to the same decimal base as `totalSupply()` for the ratio.
            // Or, more correctly, scale `assets` to Mansa's decimals for the ratio.
            // The `convertToShares` in Mansa already handles this scaling.
            expectedShares = mansaProxy.convertToShares(assets);
        }

        vm.startPrank(investor);

        vm.expectEmit(true, true, false, true);
        emit Deposit(investor, investor, assets, expectedShares);

        uint256 actualShares = mansaProxy.requestDeposit(
            "REQ-DEP-7540",
            assets
        );

        vm.stopPrank();

        assertEq(actualShares, expectedShares);
    }

    function testWithdrawFlowAndWrapperEmits() public {
        vm.startPrank(investor);
        // Invest 2,000 USD (2 * 1e9 actual value)
        mansaProxy.requestInvestment("INV-7540", 2_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(admin);
        mansaProxy.approveInvestment("INV-7540");
        vm.stopPrank();

        vm.startPrank(investor);
        mansaProxy.claimInvestment("INV-7540", investor);
        vm.stopPrank();

        uint256 withdrawAssets = 500 * 1e6; // Withdraw 500 USD (5 * 1e8 actual value)

        // Use Mansa's `convertToShares` to get the expected shares for withdrawal
        uint256 expectedShares = mansaProxy.convertToShares(withdrawAssets);



        vm.startPrank(investor);
        uint256 actualShares = mansaProxy.requestWithdraw(
            "REQ-WDR-7540",
            withdrawAssets
        );
        vm.stopPrank();

        assertGt(actualShares, 0, "Shares should be > 0");
        assertEq(actualShares, expectedShares, "Actual shares for withdrawal mismatch expected shares");


        vm.startPrank(admin);
        mansaProxy.approveWithdrawal("REQ-WDR-7540");
        vm.stopPrank();

        // Ensure custodian has enough USD to fulfill withdrawal
        deal(address(usd), custodian, 10_000_000 * 1e6);

        vm.prank(custodian);
        usd.approve(address(mansaProxy), type(uint256).max);

        uint256 preUsdBalance = usd.balanceOf(investor); // USD balance (6 decimals)
        uint256 preShares = mansaProxy.balanceOf(investor); // Mansa shares (18 decimals)

        vm.startPrank(investor);
        mansaProxy.claimWithdrawal("REQ-WDR-7540");
        vm.stopPrank();

        // Assertions for shares and USD balances
        // actualShares should be the shares burned, so subtract it from preShares
        assertEq(mansaProxy.balanceOf(investor), preShares - actualShares, "Investor Mansa balance incorrect after withdrawal");
        // withdrawAssets is the USD amount requested and should be received
        assertEq(usd.balanceOf(investor), preUsdBalance + withdrawAssets, "Investor USD balance incorrect after withdrawal");
    }

    function testZeroSupplySymmetry() public {
        assertEq(mansaProxy.totalSupply(), 0);
        assertEq(mansaProxy.totalAssets(), 0);

        assertEq(mansaProxy.convertToShares(0), 0);
        assertEq(mansaProxy.convertToAssets(0), 0);
    }
}
