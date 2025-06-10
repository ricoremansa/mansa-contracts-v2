// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
 
import "forge-std/Test.sol";
import {DeployMansa} from "../script/DeployMansa.s.sol";
import {Mansa} from "../src/Mansa.sol";
import {Mansa} from "../src/Mansa.sol"; // Caso você tenha separado a lógica
import {MockUSD} from "../test/MockUSD.sol";
import {Allowlist} from "../src/Allowlist.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployMansaTest is Test {
    DeployMansa deployScript;
    Mansa mansa;
    Mansa mansaImpl; // Opcional: caso precise verificar implementações diretamente
    MockUSD mockUsd;
    Allowlist allowlist;

    function setUp() public {
        // Set env vars for deployment
        vm.envOr("DEPLOYER", address(this));
        vm.envOr("ADMIN", address(this));
        vm.envOr("CUSTODIAN", address(this));

        // Prepare dependencies
        mockUsd = new MockUSD();
        allowlist = new Allowlist();

        // Deploy implementation
        Mansa implementation = new Mansa();

        // Encode initialization data
        bytes memory data = abi.encodeWithSelector(
            Mansa.initialize.selector,
            address(allowlist),
            "Mansa Investment Token",
            "MIT",
            address(mockUsd),
            address(this)
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), data);
        mansa = Mansa(address(proxy));

        // Setup roles and parameters
        allowlist.addToAllowlist(address(this));
        mansa.grantRole(mansa.DEFAULT_ADMIN_ROLE(), address(this));
        mansa.grantRole(mansa.ADMIN_ROLE(), address(this));

        mansa.setMinInvestmentAmount(1000 * 1e6);
        mansa.setMaxInvestmentAmount(1000000 * 1e6);
        mansa.setMinWithdrawalAmount(100 * 1e6);
        mansa.setMaxWithdrawalAmount(500000 * 1e6);
        mansa.setDailyYieldMicrobip(100000);
        mansa.setOpen(true);
    }

    function testDeploymentConfiguration() public {
        assertEq(mansa.minInvestmentAmount(), 1000 * 1e6, "Min investment incorrect");
        assertEq(mansa.maxInvestmentAmount(), 1000000 * 1e6, "Max investment incorrect");
        assertEq(mansa.minWithdrawalAmount(), 100 * 1e6, "Min withdrawal incorrect");
        assertEq(mansa.maxWithdrawalAmount(), 500000 * 1e6, "Max withdrawal incorrect");
        assertEq(mansa.dailyYieldMicrobip(), 100000, "Daily yield incorrect");
        assertTrue(mansa.open(), "Contract should be open");
    }

    function testAdminRoleAssignment() public {
        bytes32 ADMIN_ROLE = mansa.ADMIN_ROLE();
        assertTrue(mansa.hasRole(ADMIN_ROLE, address(this)), "Admin role not granted");
    }

    function testMockUsdMintingAndApproval() public {
        uint256 expectedAmount = 10000 * 1e6;

        // Reset before minting
        uint256 preMintBalance = mockUsd.balanceOf(address(this));
        if (preMintBalance > 0) {
            mockUsd.transfer(address(0xdead), preMintBalance);
        }

        mockUsd.mint(address(this), expectedAmount);
        mockUsd.approve(address(mansa), expectedAmount);

        uint256 actualBalance = mockUsd.balanceOf(address(this));
        uint256 allowance = mockUsd.allowance(address(this), address(mansa));

        assertEq(actualBalance, expectedAmount, "Minting failed");
        assertEq(allowance, expectedAmount, "Approval failed");
    }
}
