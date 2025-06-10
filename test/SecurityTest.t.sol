// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Mansa} from "../src/Mansa.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "./MockUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol"; // Import Strings utility

contract SecurityTest is Test {
    Mansa public mansa;
    Allowlist public allowlist;
    MockUSD public usdToken;

    // --- GLOBALS ---
    address public owner;
    address public admin;
    address public attacker;
    address public user1;
    address public user2;
    address public custodian;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // --- SETUP ---
    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        custodian = makeAddr("custodian");

        usdToken = new MockUSD();
        usdToken.mint(custodian, 10_000_000 * 1e6);

        allowlist = new Allowlist();
        vm.prank(owner);
        allowlist.grantRole(allowlist.DEFAULT_ADMIN_ROLE(), owner);
        allowlist.addToAllowlist(owner);
        allowlist.addToAllowlist(admin);
        allowlist.addToAllowlist(attacker);
        allowlist.addToAllowlist(user1);
        allowlist.addToAllowlist(user2);
        allowlist.addToAllowlist(custodian);
        allowlist.addToAllowlist(address(this));

        Mansa impl = new Mansa();
        bytes memory data = abi.encodeCall(
            Mansa.initialize,
            (allowlist, "Mansa Token", "MANSA", usdToken, custodian)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        mansa = Mansa(address(proxy));

        vm.prank(owner);
        allowlist.addToAllowlist(address(mansa));
        
        vm.prank(owner);
        mansa.grantRole(DEFAULT_ADMIN_ROLE, admin);
        vm.prank(owner);
        mansa.grantRole(ADMIN_ROLE, admin);

        vm.prank(admin);
        mansa.setOpen(true);
        vm.prank(admin);
        mansa.setMinInvestmentAmount(1); // Set low for dust attacks
        vm.prank(admin);
        mansa.setMaxInvestmentAmount(1_000_000_000 * 1e6); // Maximize for testing large values
        vm.prank(admin);
        mansa.setMinWithdrawalAmount(1); // Set low for dust attacks
        vm.prank(admin);
        mansa.setMaxWithdrawalAmount(1_000_000_000 * 1e6); // Maximize for testing large values

        usdToken.mint(attacker, 1_000_000 * 1e6);
        usdToken.mint(user1, 1_000_000 * 1e6);
        usdToken.mint(user2, 1_000_000 * 1e6);

        vm.startPrank(attacker);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user1);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        // FIX: Add custodian approval for withdrawals
        vm.startPrank(custodian);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();
    }

    // --- Vector 1: Rounding Error Exploitation ---
    
    function test_Attack_RepeatedDepositRounding() public {
        uint256 initialAttackerBalance = usdToken.balanceOf(attacker);

        // Attacker repeatedly requests and claims tiny deposits
        // IMPORTANT: Use Strings.toString(i) for unique request IDs
        for (uint256 i = 0; i < 100; i++) {
            string memory reqId = string(abi.encodePacked("deposit-", Strings.toString(i)));
            vm.prank(attacker);
            mansa.requestInvestment(reqId, 1);
            vm.prank(admin);
            mansa.approveInvestment(reqId);
            vm.prank(attacker);
            mansa.claimInvestment(reqId, attacker);
        }

        // Attacker attempts to withdraw their entire balance
        uint256 attackerShares = mansa.balanceOf(attacker);
        uint256 assetsToWithdraw = mansa.previewRedeem(attackerShares);
        
        // FIX: Use requestWithdraw instead of requestWithdrawal to avoid context issues
        vm.prank(attacker);
        uint256 sharesToBurn = mansa.requestWithdraw("withdraw-all", assetsToWithdraw);
        
        vm.prank(admin);
        mansa.approveWithdrawal("withdraw-all");

        vm.prank(attacker);
        mansa.claimWithdrawal("withdraw-all");

        // Assert that the attacker did not profit from rounding errors
        assertApproxEqAbs(usdToken.balanceOf(attacker), initialAttackerBalance, 1, "Attacker should not profit significantly from rounding");
    }

    // --- Vector 2: Yield Inflation Attack ---

    function test_Immunity_DirectTransferDoesNotInflateSharePrice() public {
        // 1. user1 establishes a fair share price by completing a full deposit cycle.
        uint256 depositAmount = 1000 * 1e6;
        vm.prank(user1);
        mansa.requestInvestment("deposit1", depositAmount);
        vm.prank(admin);
        mansa.approveInvestment("deposit1");
        vm.prank(user1);
        mansa.claimInvestment("deposit1", user1);
        
        uint256 shares1 = mansa.balanceOf(user1);
        assertGt(shares1, 0);

        // 2. Attacker transfers assets directly to the custodian, attempting to manipulate the TVL
        uint256 attackAmount = 10_000 * 1e6;
        vm.prank(attacker);
        usdToken.transfer(custodian, attackAmount);

        // 3. Assert that the vault's internal accounting is unaffected
        assertEq(mansa.totalAssets(), depositAmount, "Direct transfer should not affect internal TVL");

        // 4. user2 deposits the same amount as user1
        vm.prank(user2);
        mansa.requestInvestment("deposit2", depositAmount);
        vm.prank(admin);
        mansa.approveInvestment("deposit2");
        vm.prank(user2);
        mansa.claimInvestment("deposit2", user2);
        
        uint256 shares2 = mansa.balanceOf(user2);

        // 5. Assert user2 received the same number of shares, proving the share price was not manipulated
        assertEq(shares2, shares1, "Share price should not be inflated by direct transfers");
    }

    // --- Vector 5: Misaligned Previews and Logic ---
    
    function test_PreviewDeposit_AlignsWithConvertToShares() public {
        uint256 depositAmount = 12345 * 1e6;
        
        // Ensure some assets are in the vault to have a non-1:1 ratio
        vm.prank(user1);
        mansa.requestInvestment("setup", 100_000 * 1e6);
        vm.prank(admin);
        mansa.approveInvestment("setup");
        vm.prank(user1);
        mansa.claimInvestment("setup", user1);

        vm.warp(block.timestamp + 10 days); // Accrue some yield

        uint256 previewedShares = mansa.previewDeposit(depositAmount);
        uint256 calculatedShares = mansa.convertToShares(depositAmount);
        
        assertEq(previewedShares, calculatedShares, "previewDeposit should equal convertToShares");
    }

    function test_PreviewWithdraw_AlignsWithConvertToAssets() public {
        uint256 depositAmount = 100_000 * 1e6;
        
        vm.prank(user1);
        mansa.requestInvestment("setup", depositAmount);
        vm.prank(admin);
        mansa.approveInvestment("setup");
        vm.prank(user1);
        mansa.claimInvestment("setup", user1);

        vm.warp(block.timestamp + 10 days); // Accrue some yield

        uint256 sharesToWithdraw = mansa.balanceOf(user1) / 2;
        
        uint256 previewedAssets = mansa.previewRedeem(sharesToWithdraw);
        uint256 calculatedAssets = mansa.convertToAssets(sharesToWithdraw);
        
        assertApproxEqAbs(previewedAssets, calculatedAssets, 1, "previewRedeem should approximately equal convertToAssets");
    }
}