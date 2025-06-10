// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Mansa} from "../src/Mansa.sol";
import {MansaV2} from "../src/MansaV2.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "./MockUSD.sol";

contract UUPSERC4626ReadOnlyTest is Test {
    Allowlist allowlist;
    MockUSD usd;
    Mansa mansaProxy;
    MansaV2 vault;

    address admin;
    address custodian = address(0xC);
    address investor = address(0xA);

    function setUp() public {
        admin = address(this);

        allowlist = new Allowlist();
        usd = new MockUSD();

        allowlist.addToAllowlist(admin);
        allowlist.addToAllowlist(custodian);
        allowlist.addToAllowlist(investor);

        Mansa impl = new Mansa();
        bytes memory data = abi.encodeCall(
            Mansa.initialize,
            (allowlist, "Mansa Token", "MANSA", usd, custodian)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        mansaProxy = Mansa(address(proxy));

        mansaProxy.grantRole(mansaProxy.DEFAULT_ADMIN_ROLE(), admin);
        mansaProxy.grantRole(mansaProxy.ADMIN_ROLE(), admin);

        mansaProxy.setOpen(true);
        mansaProxy.setMinInvestmentAmount(1);
        mansaProxy.setMaxInvestmentAmount(100_000);
        mansaProxy.setMinWithdrawalAmount(1);
        mansaProxy.setMaxWithdrawalAmount(100_000);
        mansaProxy.setDailyYieldMicrobip(0);

        usd.mint(investor, 10_000);
        vm.prank(investor);
        usd.approve(address(mansaProxy), type(uint256).max);
    }

    function upgradeToV2() internal {
        MansaV2 newImpl = new MansaV2();
        mansaProxy.grantRole(mansaProxy.UPGRADER_ROLE(), admin);
        mansaProxy.upgradeToAndCall(address(newImpl), "");
        vault = MansaV2(address(mansaProxy));
    }

    function testERC4626ReadOnly() public {
        // Deposit & claim before upgrade
        vm.prank(investor);
        mansaProxy.requestInvestment("INV-1", 5_000);
        mansaProxy.approveInvestment("INV-1");
        vm.prank(investor);
        mansaProxy.claimInvestment("INV-1", investor);

        // Upgrade
        upgradeToV2();

        // Now ERC-4626 checks AFTER deposit/claim
        assertEq(vault.asset(), address(usd));
        assertEq(vault.totalAssets(), 5_000);

        uint256 shareAmount = vault.convertToShares(1_000);
        assertGt(shareAmount, 0, "convertToShares must be > 0");

        assertEq(vault.convertToAssets(shareAmount), 1_000);

        // maxDeposit / maxMint
        assertEq(vault.maxDeposit(investor), 100_000);
        assertEq(vault.maxMint(investor), vault.convertToShares(100_000));

        // previewDeposit / previewMint
        uint256 previewShares = vault.previewDeposit(1_000);
        assertGt(previewShares, 0, "previewDeposit must be > 0");
        assertEq(previewShares, vault.convertToShares(1_000));

        uint256 mintPreviewAssets = vault.previewMint(previewShares);
        assertEq(mintPreviewAssets, 1_000);

        // previewWithdraw / previewRedeem
        uint256 withdrawShares = vault.convertToShares(1_000);

        // ✅ --- FIX IS HERE ---
        // The original test called vault.previewWithdraw(withdrawShares) which is incorrect.
        // The correct function to get assets from shares is previewRedeem.
        uint256 previewAssetsFromShares = vault.previewRedeem(withdrawShares);
        assertEq(previewAssetsFromShares, 1_000);
        // ✅ --------------------

        // This is a correct use of previewWithdraw: give assets, get shares.
        uint256 previewSharesFromAssets = vault.previewWithdraw(1_500);
        assertGt(previewSharesFromAssets, 0);


        assertEq(vault.decimalsOffset(), 12);
        assertEq(vault.maxWithdraw(investor), 5_000);
    }
function testRequestWithdrawFlowsThroughAsyncLogic() public {
    // Initial deposit & claim BEFORE upgrade
    vm.prank(investor);
    mansaProxy.requestInvestment("INV-2", 2_000);
    mansaProxy.approveInvestment("INV-2");
    vm.prank(investor);
    mansaProxy.claimInvestment("INV-2", investor);

    // Upgrade
    upgradeToV2();

    // Calcular shares para retirada e garantir valor esperado de assets
    uint256 sharesToWithdraw = vault.convertToShares(500);
    uint256 withdrawAmount = vault.convertToAssets(sharesToWithdraw);

    // Emitir evento com valores corretos
    vm.prank(investor);
    vm.expectEmit(true, true, false, true);
    emit Withdraw(investor, investor, withdrawAmount, sharesToWithdraw);

    // Request withdrawal usando o valor de assets com simetria
    vault.requestWithdraw("WDR-1", withdrawAmount);

    // Aprovações
    vault.approveWithdrawal("WDR-1");
    vm.prank(custodian);
    usd.approve(address(vault), type(uint256).max);

    // Pre-claim balance
    uint256 preShares = vault.balanceOf(investor);
    uint256 preAssets = usd.balanceOf(investor);

    // Claim withdrawal
    vm.prank(investor);
    vault.claimWithdrawal("WDR-1");

    // Pós-claim
    uint256 postShares = vault.balanceOf(investor);
    uint256 postAssets = usd.balanceOf(investor);

    assertEq(postShares, preShares - sharesToWithdraw);
    assertEq(postAssets, preAssets + withdrawAmount);
}

function testProxyRespectsOriginalSenderInAllowlist() public {
    upgradeToV2();
    allowlist.removeFromAllowlist(address(vault));

    vm.prank(investor);
    usd.approve(address(vault), type(uint256).max);

    vm.prank(investor);
    vault.requestInvestment("INV-PROXY", 1_000);

    vm.prank(admin); // Só o admin pode aprovar
    vault.approveInvestment("INV-PROXY");

    vm.prank(investor);
    vault.claimInvestment("INV-PROXY", investor);

    assertGt(vault.balanceOf(investor), 0, "Investor should receive shares");
    assertEq(vault.getUpdatedTvl(), 1_000, "TVL should be updated correctly");
}


    // ERC4626 Withdraw event
    event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
}