// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Mansa} from "../src/Mansa.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "./MockUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AdditionalSecurityTests is Test {
    Mansa public mansa;
    Allowlist public allowlist;
    MockUSD public usdToken;

    address public owner;
    address public admin;
    address public user1;
    address public user2;
    address public custodian;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

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
        mansa.setMinInvestmentAmount(1);
        vm.prank(admin);
        mansa.setMaxInvestmentAmount(1_000_000_000 * 1e6);
        vm.prank(admin);
        mansa.setMinWithdrawalAmount(1);
        vm.prank(admin);
        mansa.setMaxWithdrawalAmount(1_000_000_000 * 1e6);

        // CORREÇÃO: Não mintar USD para os usuários aqui, fazer isso apenas quando necessário
        // para evitar confusão com balanços

        vm.startPrank(user1);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(custodian);
        usdToken.approve(address(mansa), type(uint256).max);
        vm.stopPrank();
    }

    function test_DecimalPrecisionWithExtremeValues() public {
        vm.prank(admin);
        mansa.setMaxTvlGrowthFactor(type(uint256).max);
        
        // CORREÇÃO: Mintar exatamente 1 wei para user1
        usdToken.mint(user1, 1);
        
        // Verificar balance inicial
        assertEq(usdToken.balanceOf(user1), 1, "User1 should have exactly 1 wei USD");
        
        vm.startPrank(user1);
        mansa.requestInvestment("tiny-1", 1);
        vm.stopPrank();
        
        vm.prank(admin);
        mansa.approveInvestment("tiny-1");
        
        vm.prank(user1);
        mansa.claimInvestment("tiny-1", user1);
        
        uint256 tinyShares = mansa.balanceOf(user1);
        console.log("Shares from 1 wei USD:", tinyShares);
        
        assertEq(tinyShares, 1e12, "Should mint exactly 10^12 shares for 1 wei USD");
        
        uint256 assetsFromTinyShares = mansa.convertToAssets(tinyShares);
        assertEq(assetsFromTinyShares, 1, "Should convert back to exactly 1 wei USD");
        
        // Teste com valor grande
        uint256 largeAmount = 1_000_000_000 * 1e6; // 1 bilhão USD
        usdToken.mint(user2, largeAmount);
        
        vm.startPrank(user2);
        usdToken.approve(address(mansa), largeAmount);
        mansa.requestInvestment("large-1", largeAmount);
        vm.stopPrank();
        
        vm.prank(admin);
        mansa.approveInvestment("large-1");
        
        vm.prank(user2);
        mansa.claimInvestment("large-1", user2);
        
        uint256 largeShares = mansa.balanceOf(user2);
        assertTrue(largeShares > 0, "Should mint shares for large deposit");
        console.log("Shares from 1B USD:", largeShares);
        
        // Teste withdrawal de 1 wei
        vm.prank(user1);
        uint256 withdrawnShares = mansa.requestWithdraw("tiny-withdraw", 1);
        
        assertEq(withdrawnShares, 1e12, "Should burn exactly 10^12 shares for 1 wei USD withdrawal");
        
        vm.prank(admin);
        mansa.approveWithdrawal("tiny-withdraw");
        
        // Verificar balance antes do claim
        assertEq(usdToken.balanceOf(user1), 0, "User1 should have 0 USD before claim");
        
        vm.prank(user1);
        mansa.claimWithdrawal("tiny-withdraw");
        
        assertEq(mansa.balanceOf(user1), 0, "Should have 0 shares after withdrawal");
        assertEq(usdToken.balanceOf(user1), 1, "Should receive exactly 1 wei USD");
    }

    function test_MaxTvlGrowthFactorValidation() public {
        // Mintar USD para user1
        usdToken.mint(user1, 1_000_000 * 1e6);
        
        vm.prank(user1);
        mansa.requestInvestment("first", 100 * 1e6);
        vm.prank(admin);
        mansa.approveThenClaimInvestment("first", user1);
        
        uint256 initialTvl = mansa.getUpdatedTvl();
        assertEq(initialTvl, 100 * 1e6);
        
        // Factor = 1: não permite crescimento
        vm.prank(admin);
        mansa.setMaxTvlGrowthFactor(1);
        
        vm.prank(user1);
        vm.expectRevert(Mansa.TvlIncreaseTooLarge.selector);
        mansa.requestInvestment("no-growth", 1);
        
        // Factor = 10: permite crescimento 10x
        vm.prank(admin);
        mansa.setMaxTvlGrowthFactor(10);
        
        vm.prank(user1);
        mansa.requestInvestment("growth-allowed", 900 * 1e6);
        // Deve funcionar sem revert
    }

    function test_PreventSandwichAttackOnYield() public {
        // Setup com valores apropriados
        vm.prank(admin);
        mansa.setMaxTvlGrowthFactor(100); // Permite crescimento 100x
        
        // Mintar USD para users
        usdToken.mint(user1, 10_000 * 1e6);
        usdToken.mint(user2, 90_000 * 1e6);
        
        // User1 deposita primeiro
        vm.prank(user1);
        mansa.requestInvestment("initial", 10_000 * 1e6);
        vm.prank(admin);
        mansa.approveThenClaimInvestment("initial", user1);
        
        uint256 user1Shares = mansa.balanceOf(user1);
        uint256 initialTvl = mansa.getUpdatedTvl();
        
        // Admin define yield alto
        vm.prank(admin);
        mansa.setDailyYieldMicrobip(100_000); // 1% diário
        
        // Attacker (user2) tenta front-run
        vm.prank(user2);
        mansa.requestInvestment("sandwich", 90_000 * 1e6);
        vm.prank(admin);
        mansa.approveThenClaimInvestment("sandwich", user2);
        
        uint256 attackerSharesBefore = mansa.balanceOf(user2);
        uint256 tvlBefore = mansa.getUpdatedTvl();
        
        // Tempo passa e yield acumula
        vm.warp(block.timestamp + 1 days);
        
        uint256 tvlAfter = mansa.getUpdatedTvl();
        uint256 yieldGenerated = tvlAfter - tvlBefore;
        console.log("Yield generated:", yieldGenerated);
        
        // Attacker tenta sair imediatamente
        uint256 attackerAssets = mansa.convertToAssets(attackerSharesBefore);
        vm.prank(user2);
        mansa.requestWithdraw("exit", attackerAssets);
        
        // CORREÇÃO: Verificar que o withdrawal precisa de aprovação manual
        // tentando fazer claim diretamente (deve falhar com NotApproved)
        vm.prank(user2);
        vm.expectRevert(Mansa.NotApproved.selector);
        mansa.claimWithdrawal("exit");
        
        // Isso prova que o withdrawal não é aprovado automaticamente
        // e o admin tem tempo para detectar e prevenir o ataque
        
        // Admin pode rejeitar o withdrawal suspeito
        vm.prank(admin);
        mansa.rejectWithdrawal("exit");
        
        // Após rejeição, tentar claim ainda retorna NotApproved
        // (não AlreadyRejected porque o contrato primeiro verifica aprovação)
        vm.prank(user2);
        vm.expectRevert(Mansa.NotApproved.selector);
        mansa.claimWithdrawal("exit");
        
        // Verificar que o attacker não conseguiu lucrar com o yield
        uint256 attackerFinalBalance = usdToken.balanceOf(user2);
        assertEq(attackerFinalBalance, 0, "Attacker should not have withdrawn any USD");
    }

    function test_RoundingAlwaysFavorsProtocol() public {
        vm.prank(admin);
        mansa.setMaxTvlGrowthFactor(1000000);
        
        // Mintar USD para user1
        usdToken.mint(user1, 1_000_000 * 1e6);
        
        // Depositar valor que pode causar arredondamento
        uint256 depositAmount = 333333; // 0.333333 USD
        
        vm.prank(user1);
        mansa.requestInvestment("rounding-1", depositAmount);
        vm.prank(admin);
        mansa.approveThenClaimInvestment("rounding-1", user1);
        
        uint256 shares = mansa.balanceOf(user1);
        uint256 assetsFromShares = mansa.convertToAssets(shares);
        
        assertLe(assetsFromShares, depositAmount, "Rounding should favor protocol");
        console.log("Deposited:", depositAmount);
        console.log("Can withdraw:", assetsFromShares);
        console.log("Protocol keeps:", depositAmount - assetsFromShares);
        
        // Tentar sacar exatamente o valor depositado
        vm.prank(user1);
        uint256 withdrawShares = mansa.requestWithdraw("withdraw-all", depositAmount);
        
        console.log("Shares owned:", shares);
        console.log("Shares needed for full withdrawal:", withdrawShares);
        
        // Se não tem shares suficientes, deve ser >= shares owned
        assertGe(withdrawShares, shares, "Should need at least all shares");
    }


   

}