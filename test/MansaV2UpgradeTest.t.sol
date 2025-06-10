// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Mansa} from "../src/Mansa.sol";
import {MansaV2} from "../src/MansaV2.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "./MockUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// FIX: Removed unused import that was causing a compilation error.
// import {Upgrades} from "foundry-upgrades/Upgrades.sol";

contract MansaV2UpgradeTest is Test {
    Mansa public mansa;
    Allowlist public allowlist;
    MockUSD public usdToken;

    // --- GLOBALS ---
    address public owner;
    address public admin;
    address public user1;
    address public user2;
    address public custodian;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // --- SETUP ---
    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
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
        allowlist.addToAllowlist(user1);
        allowlist.addToAllowlist(user2);
        allowlist.addToAllowlist(custodian);

        Mansa implV1 = new Mansa();
        bytes memory data = abi.encodeCall(
            Mansa.initialize,
            (allowlist, "Mansa Token", "MANSA", usdToken, custodian)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implV1), data);
        mansa = Mansa(address(proxy));

        vm.prank(owner);
        allowlist.addToAllowlist(address(mansa));
        
        // --- IMPORTANT: Grant roles to admin BEFORE admin uses them ---
        vm.prank(owner);
        mansa.grantRole(DEFAULT_ADMIN_ROLE, admin);
        vm.prank(owner);
        mansa.grantRole(ADMIN_ROLE, admin);
        vm.prank(owner);
        mansa.grantRole(UPGRADER_ROLE, owner); // Owner retains UPGRADER_ROLE for future upgrades

        // Now admin can safely call functions requiring ADMIN_ROLE
        vm.prank(admin);
        mansa.setOpen(true);
        vm.prank(admin);
        mansa.setMinInvestmentAmount(1); // Set a minimal investment amount
        vm.prank(admin);
        mansa.setMaxInvestmentAmount(1_000_000_000 * 1e6); // Set a large max investment amount (e.g., 1 billion USD equivalent)
        vm.prank(admin);
        mansa.setMinWithdrawalAmount(1); // Set a minimal withdrawal amount
        vm.prank(admin);
        mansa.setMaxWithdrawalAmount(1_000_000_000 * 1e6); // Set a large max withdrawal amount
        vm.prank(admin);
        mansa.setDailyYieldMicrobip(10_000); // Set a reasonable daily yield

        usdToken.mint(user1, 1_000_000 * 1e6);
        usdToken.mint(user2, 1_000_000 * 1e6);

        vm.startPrank(user1);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();
    }

    // --- UPGRADE & TEST ---

    function test_UpgradeToV2_And_CheckState() public {
        // 1. Perform action on V1
        vm.prank(user1);
        mansa.requestDeposit("deposit1", 1000 * 1e6);

        // 2. Upgrade the contract
        MansaV2 implV2 = new MansaV2();
        vm.prank(owner);
        mansa.upgradeToAndCall(address(implV2), abi.encodeCall(MansaV2.initializeV2, (42)));

        MansaV2 mansaV2 = MansaV2(payable(address(mansa)));
        
        // 3. Check V2 state
        assertEq(mansaV2.version(), "MansaV2");
        assertEq(mansaV2.newConfig(), 42);

        // 4. Verify state from V1 is preserved
        vm.prank(admin);
        mansaV2.approveInvestment("deposit1");

        vm.prank(user1);
        mansaV2.claimInvestment("deposit1", user1);
        
        assertGt(mansaV2.balanceOf(user1), 0);
        assertEq(mansaV2.totalAssets(), 1000 * 1e6);
    }
    
    function testV2_CorrectWithdrawalLogicAfterUpgrade() public {
        // Setup user1 with committed funds in V1
        uint256 investAmount = 2000 * 1e6;
        uint256 commitUntil = block.timestamp + 30 days;
        vm.prank(user1);
        mansa.requestInvestmentCommitted("commit-v1", investAmount, commitUntil);
        vm.prank(admin);
        mansa.approveInvestment("commit-v1");
        vm.prank(user1);
        mansa.claimInvestment("commit-v1", user1);

        // Upgrade to V2
        MansaV2 implV2 = new MansaV2();
        vm.prank(owner);
        mansa.upgradeToAndCall(address(implV2), ""); // No need to init again

        MansaV2 mansaV2 = MansaV2(payable(address(mansa)));
        
        // Try to withdraw committed funds using V2's logic
        vm.prank(user1);
        vm.expectRevert(Mansa.CommittedBalance.selector);
        mansaV2.requestWithdrawal("fail-withdraw", 100 * 1e6);

        // Warp time past commitment
        vm.warp(commitUntil + 1);

        // Now withdrawal should succeed
        vm.prank(user1);
        (uint256 shares) = mansaV2.requestWithdrawal("pass-withdraw", 100 * 1e6);
        assertTrue(shares > 0);
    }

    function testV2_MaxWithdrawIsCorrect() public {
        // Setup with user1 and user2
        vm.prank(user1);
        mansa.requestDeposit("dep1", 5000 * 1e6);
        vm.prank(admin);
        mansa.approveInvestment("dep1");
        vm.prank(user1);
        mansa.claimInvestment("dep1", user1);

        // Upgrade to V2
        MansaV2 implV2 = new MansaV2();
        vm.prank(owner);
        mansa.upgradeToAndCall(address(implV2), "");
        MansaV2 mansaV2 = MansaV2(payable(address(mansa)));

        // Reserve some shares
        vm.prank(user1);
        mansaV2.requestWithdrawal("reserving", 1000 * 1e6);
        vm.prank(admin);
        mansaV2.approveWithdrawal("reserving");

        uint256 balance = mansaV2.balanceOf(user1);
        uint256 reserved = mansaV2.convertToShares(1000 * 1e6);
        
        uint256 expectedMaxShares = balance - reserved;
        uint256 expectedMaxAssets = mansaV2.convertToAssets(expectedMaxShares);
        
        assertEq(mansaV2.maxRedeem(user1), expectedMaxShares);
        assertEq(mansaV2.maxWithdraw(user1), expectedMaxAssets);
    }
}
