// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Mansa} from "../src/Mansa.sol"; // Original Mansa contract (V1)
import {MansaV2} from "../src/MansaV2.sol"; // New MansaV2 implementation

import {Allowlist} from "../src/Allowlist.sol";
import {MockUSD} from "../test/MockUSD.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract UUPSUpgradeTest is Test {
    Mansa public implementationV1;
    MansaV2 public implementationV2;
    ERC1967Proxy public proxy;
    Mansa public mansa;

    // Mock dependencies
    Allowlist public allowlist;
    MockUSD public usdToken;
    address private admin;
    address public custodian = address(0xBEEF);

      function setUp() public {
        // Deploy mocks
        allowlist = new Allowlist();
        usdToken = new MockUSD();
        // Deploy V1 implementation
        admin = address(this);

        implementationV1 = new Mansa();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            Mansa.initialize.selector,
            allowlist,
            "Mansa",
            "MSA",
            usdToken,
            custodian
        );

        // Deploy proxy pointing to V1
        proxy = new ERC1967Proxy(address(implementationV1), initData);

        // Cast proxy to Mansa
        mansa = Mansa(address(proxy));

        // Setup allowlist
        allowlist.addToAllowlist(address(this));
        allowlist.addToAllowlist(custodian);
    }

       function testUpgradeToV2() public {
        // Deploy V2 implementation
        implementationV2 = new MansaV2();

        // Before upgrade, version() should revert
        vm.expectRevert();
        MansaV2(address(mansa)).version();

        // Perform UUPS upgrade
        mansa.grantRole(mansa.UPGRADER_ROLE(), admin);

        mansa.upgradeToAndCall(address(implementationV2), "");

        // After upgrade, version() should return "MansaV2"
        string memory ver = MansaV2(address(mansa)).version();
        assertEq(ver, "MansaV2");
    }

      function testIncreaseMaxInvestment() public {
        // Deploy V2 and upgrade
        implementationV2 = new MansaV2();
        mansa.grantRole(mansa.UPGRADER_ROLE(), admin);
        mansa.grantRole(mansa.ADMIN_ROLE(), admin);

        mansa.upgradeToAndCall(address(implementationV2), "");

        // Cast to V2
        MansaV2 mansaV2 = MansaV2(address(mansa));

        console.log("Old maxInvestment:", mansa.maxInvestmentAmount());

        // Increase by 100
        vm.prank(address(this));
        mansaV2.increaseMaxInvestment(100);
        assertEq(mansa.maxInvestmentAmount(), 100);
        console.log("New maxInvestment:", mansa.maxInvestmentAmount());

        // Increase again
        vm.prank(address(this));
        mansaV2.increaseMaxInvestment(50);
        assertEq(mansa.maxInvestmentAmount(), 150);
        console.log("Final maxInvestment:", mansa.maxInvestmentAmount());
    }

    function testStorageLayoutPreserved() public {
    // Salva valor antes do upgrade
    uint256 originalMax = mansa.maxInvestmentAmount();

    // Faz upgrade para V2
    implementationV2 = new MansaV2();
    mansa.grantRole(mansa.UPGRADER_ROLE(), admin);
    mansa.upgradeToAndCall(address(implementationV2), "");

    // Recheca se o valor persistiu
    assertEq(mansa.maxInvestmentAmount(), originalMax, "Storage layout quebrado");
}



function testV2_IncreaseMaxInvestment() public {
    implementationV2 = new MansaV2();
    mansa.grantRole(mansa.UPGRADER_ROLE(), admin);
    mansa.grantRole(mansa.ADMIN_ROLE(), admin);
    mansa.upgradeToAndCall(address(implementationV2), "");

    MansaV2 mansaV2 = MansaV2(address(mansa));

    uint256 oldMax = mansa.maxInvestmentAmount();
    mansaV2.increaseMaxInvestment(100 * 10 ** 6);

    assertEq(
        mansa.maxInvestmentAmount(),
        oldMax + 100 * 10 ** 6,
        "Max investment should increase"
    );
}

function testV2_IncreaseMaxInvestment_FailsWithoutRole() public {
    implementationV2 = new MansaV2();
    mansa.grantRole(mansa.UPGRADER_ROLE(), admin);
    mansa.upgradeToAndCall(address(implementationV2), "");

    vm.expectRevert();
    MansaV2(address(mansa)).increaseMaxInvestment(100);
}
function testV2_RenounceCustodian() public {
    implementationV2 = new MansaV2();
    mansa.grantRole(mansa.UPGRADER_ROLE(), admin);
    mansa.grantRole(mansa.DEFAULT_ADMIN_ROLE(), admin);
    mansa.upgradeToAndCall(address(implementationV2), "");

    MansaV2 mansaV2 = MansaV2(address(mansa));
    address previousCustodian = mansa.custodian();

    vm.expectEmit(true, true, false, true);
    emit Mansa.CustodianChanged(previousCustodian, address(0), admin);

    mansaV2.renounceCustodian();

    assertEq(
        mansa.custodian(),
        address(0),
        "Custodian should be set to zero address"
    );
}


}
 