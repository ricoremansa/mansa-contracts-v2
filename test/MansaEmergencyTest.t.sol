// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Mansa} from "../src/Mansa.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "./MockUSD.sol";

contract MansaEdgeCasesTest is Test {
    Mansa mansa;
    Allowlist allowlist;
    MockUSD usd;

    address admin;
    address custodian;
    address user1;
    address user2;

    function setUp() public {
        admin = address(this);
        custodian = makeAddr("custodian");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        allowlist = new Allowlist();
        allowlist.addToAllowlist(admin);
        allowlist.addToAllowlist(custodian);
        allowlist.addToAllowlist(user1);
        allowlist.addToAllowlist(user2);

        usd = new MockUSD();
        usd.mint(custodian, 1_000_000 * 1e6);

        Mansa impl = new Mansa();
        bytes memory data = abi.encodeCall(
            Mansa.initialize,
            (allowlist, "Mansa Token", "MANSA", usd, custodian)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        mansa = Mansa(address(proxy));

        allowlist.addToAllowlist(address(mansa));

        mansa.grantRole(mansa.ADMIN_ROLE(), admin);
        mansa.setOpen(true);
        mansa.setMinInvestmentAmount(1);
        mansa.setMaxInvestmentAmount(1_000_000 * 1e6);
        mansa.setMinWithdrawalAmount(1);
        mansa.setMaxWithdrawalAmount(1_000_000 * 1e6);

        usd.mint(user1, 100_000 * 1e6);
        usd.mint(user2, 100_000 * 1e6);

        vm.startPrank(user1);
        usd.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usd.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(custodian);
        usd.approve(address(mansa), type(uint256).max);
        vm.stopPrank();
    }

    function test_ClaimInvestmentAsAdmin() public {
        vm.startPrank(user1);
        mansa.requestInvestment("INV-ADMIN", 1_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(admin);
        mansa.approveThenClaimInvestment("INV-ADMIN", user1);
        vm.stopPrank();

        uint256 shares = mansa.balanceOf(user1);
        uint256 expectedShares = mansa.convertToShares(1_000 * 1e6);

        assertEq(shares, expectedShares);
    }

   

    function test_OperatorCanClaim() public {
        // Setup operator
        vm.startPrank(user1);
        mansa.setOperator(user2, true);
        mansa.requestInvestment("INV-OPERATOR", 1_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(admin);
        mansa.approveInvestment("INV-OPERATOR");
        vm.stopPrank();

        // Operator claims for user1
        vm.startPrank(user2);
        mansa.claimInvestment("INV-OPERATOR", user1);
        vm.stopPrank();

        uint256 shares = mansa.balanceOf(user1);
        uint256 expectedShares = mansa.convertToShares(1_000 * 1e6);

        assertEq(shares, expectedShares);
    }

    function test_TvlWarningEmits() public {
        // Lower maxTvlGrowthFactor for test
        vm.startPrank(admin);
        mansa.setMaxTvlGrowthFactor(2); // 2x allowed growth
        vm.stopPrank();

        vm.startPrank(user1);
        mansa.requestInvestment("INV-TVLGROW", 1_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(admin);
        mansa.approveThenClaimInvestment("INV-TVLGROW", user1);
        vm.stopPrank();

        uint256 initialTvl = mansa.getUpdatedTvl();

        // Warp 365 days with high yield to trigger suspicious growth
        vm.startPrank(admin);
        mansa.setDailyYieldMicrobip(1_000_000); // High yield for test
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Expect revert on updateTvl() because growth exceeds allowed factor
        vm.startPrank(user1);
        vm.expectRevert(Mansa.TvlIncreaseTooLarge.selector);

        mansa.requestInvestment("INV-TOO-MUCH", 1_000 * 1e6);
        vm.stopPrank();
    }
}
