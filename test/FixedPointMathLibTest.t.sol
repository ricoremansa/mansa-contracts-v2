// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/FixedPointMathLib.sol";
 
contract FixedPointMathLibTest is Test {
    using FixedPointMathLib for uint256;

    function test_mulWadDown() public {
        assertEq(FixedPointMathLib.mulWadDown(2e18, 3e18), 6e18);
        assertEq(FixedPointMathLib.mulWadDown(1e18, 5e17), 5e17); // 1 * 0.5
    }

    function test_mulWadUp() public {
        assertEq(FixedPointMathLib.mulWadUp(2e18, 3e18), 6e18);
        assertEq(FixedPointMathLib.mulWadUp(1e18, 5e17 + 1), 5e17 + 1); // rounding up
    }

    function test_divWadDown() public {
        assertEq(FixedPointMathLib.divWadDown(6e18, 2e18), 3e18);
    }

    function test_divWadUp() public {
        assertEq(FixedPointMathLib.divWadUp(6e18, 2e18), 3e18);
        assertEq(FixedPointMathLib.divWadUp(1e18, 3e18), 333_333_333_333_333_334);
    }

    function test_mulDivDown() public {
        assertEq(FixedPointMathLib.mulDivDown(6, 3, 2), 9); // (6*3)/2 = 9
    }

    function test_mulDivUp() public {
        assertEq(FixedPointMathLib.mulDivUp(6, 3, 2), 9);
        assertEq(FixedPointMathLib.mulDivUp(7, 3, 2), 11); // (7*3)/2 = 10.5 → 11
    }

    function test_rpow_base0_exp0() public {
        assertEq(FixedPointMathLib.rpow(0, 0, 1e18), 1e18);
    }

    function test_rpow_base0_expN() public {
        assertEq(FixedPointMathLib.rpow(0, 5, 1e18), 0);
    }

    function test_rpow_baseN_exp0() public {
        assertEq(FixedPointMathLib.rpow(5e18, 0, 1e18), 1e18);
    }

    function test_rpow_baseN_exp1() public {
        assertEq(FixedPointMathLib.rpow(5e18, 1, 1e18), 5e18);
    }

    function test_sqrt() public {
        assertEq(FixedPointMathLib.sqrt(4), 2);
        assertEq(FixedPointMathLib.sqrt(9), 3);
        assertEq(FixedPointMathLib.sqrt(1e18), 1e9);
    }

    function test_unsafeMod() public {
        assertEq(FixedPointMathLib.unsafeMod(10, 3), 1);
        assertEq(FixedPointMathLib.unsafeMod(10, 0), 0); // edge case: doesn't revert
    }

    function test_unsafeDiv() public {
        assertEq(FixedPointMathLib.unsafeDiv(10, 2), 5);
        assertEq(FixedPointMathLib.unsafeDiv(10, 0), 0); // edge case: doesn't revert
    }

    function test_unsafeDivUp() public {
        assertEq(FixedPointMathLib.unsafeDivUp(9, 2), 5);
        assertEq(FixedPointMathLib.unsafeDivUp(10, 2), 5);
        assertEq(FixedPointMathLib.unsafeDivUp(10, 0), 0); // edge case
    }
}
