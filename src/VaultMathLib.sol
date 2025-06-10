// VaultMathLib.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Import FixedPointMathLib for `rpow` functionality
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// This library is for pure mathematical calculations,
// it does not inherently know about specific token decimals.
// The caller (e.g., Mansa contract) must handle decimal scaling
// before passing values to these functions.
library VaultMathLib {
    // Enable `rpow` and other FixedPointMathLib functions on `uint256` type
    using FixedPointMathLib for uint256;

    // Fixed-point base for calculations using FixedPointMathLib, typically 1e18
    uint256 internal constant FIXED_POINT_ONE = 1e18;

    // The scale of dailyYieldMicrobip (10^10 as per your comment: 1/10000 of a basis point, which is 1e-4 * 1e-6 = 1e-10)
    uint256 internal constant MICROBIP_DENOMINATOR = 1e10;

    /**
     * @dev Accrues yield to the TVL with compound interest using FixedPointMathLib's rpow.
     * @param lastTvl The current Total Value Locked (assets).
     * @param lastUpdatedAt The timestamp when the TVL was last updated.
     * @param dailyYieldMicrobip Daily yield rate in microbips (e.g., 10 for 10 microbips).
     * @param currentTimestamp The current block timestamp.
     * @return The TVL after accruing yield.
     */
    function accrueTvl(
        uint256 lastTvl,
        uint256 lastUpdatedAt,
        uint256 dailyYieldMicrobip,
        uint256 currentTimestamp
    ) internal pure returns (uint256) {
        if (currentTimestamp <= lastUpdatedAt || lastTvl == 0 || dailyYieldMicrobip == 0) {
            return lastTvl;
        }

        uint256 daysCount = (currentTimestamp - lastUpdatedAt) / 1 days;

        // Calculate the daily rate in FIXED_POINT_ONE scale
        // dailyRate = dailyYieldMicrobip / MICROBIP_DENOMINATOR
        // Scaled to FIXED_POINT_ONE: (dailyYieldMicrobip * FIXED_POINT_ONE) / MICROBIP_DENOMINATOR
        uint256 dailyRateScaled = (dailyYieldMicrobip * FIXED_POINT_ONE) / MICROBIP_DENOMINATOR;

        // The base for rpow is (1 + dailyRateScaled)
        uint256 baseForRpow = FIXED_POINT_ONE + dailyRateScaled;

        // factor = (1 + dailyRate)^daysCount, scaled by FIXED_POINT_ONE
        uint256 factor = baseForRpow.rpow(daysCount, FIXED_POINT_ONE);

        // Calculate the new TVL: lastTvl * factor / FIXED_POINT_ONE
        uint256 result = (lastTvl * factor) / FIXED_POINT_ONE;

        return result;
    }

    /**
     * @dev Converts shares to assets based on the current vault ratio.
     * This function performs the core ERC4626 ratio calculation.
     * Assumes `shares` and `totalShares` are in the same decimal base (e.g., Mansa's decimals).
     * Assumes `totalAssets` is in its natural decimal base (e.g., USD's decimals).
     * @param shares The amount of shares to convert (scaled to vault.decimals).
     * @param totalShares The total supply of shares in the vault (scaled to vault.decimals).
     * @param totalAssets The total amount of assets held by the vault (scaled to asset.decimals).
     * @return The equivalent amount of assets (scaled to asset.decimals).
     */
    function _toAssets(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAssets
    ) internal pure returns (uint256) {
        if (totalShares == 0) return 0; // If no shares, cannot convert from shares
        if (shares == 0) return 0;

        // Core ERC4626 formula: (shares * totalAssets) / totalShares
        // This calculation expects `totalAssets` and `totalShares` to represent the true ratio.
        // `shares` should be in the same scale as `totalShares`.
        // The result will be in the same scale as `totalAssets`.
        return (shares * totalAssets) / totalShares;
    }

    /**
     * @dev Converts assets to shares based on the current vault ratio.
     * This function performs the core ERC4626 ratio calculation.
     * Assumes `assets` and `totalAssets` are in the same decimal base (e.g., USD's decimals).
     * Assumes `totalShares` is in its natural decimal base (e.g., Mansa's decimals).
     * @param assets The amount of assets to convert (scaled to asset.decimals).
     * @param totalShares The total supply of shares in the vault (scaled to vault.decimals).
     * @param totalAssets The total amount of assets held by the vault (scaled to asset.decimals).
     * @return The equivalent amount of shares (scaled to vault.decimals).
     */
    function _toShares(
        uint256 assets,
        uint256 totalShares,
        uint256 totalAssets
    ) internal pure returns (uint256) {
        if (totalAssets == 0) return 0; // Cannot convert to shares if no assets backing them (initial mint handled by Mansa)
        if (assets == 0) return 0;

        // Core ERC4626 formula: (assets * totalShares) / totalAssets
        // This calculation expects `assets` and `totalAssets` to be in the same scale.
        // The result will be in the same scale as `totalShares`.
        return (assets * totalShares) / totalAssets;
    }

    /**
     * @dev Converts shares to assets, rounding up.
     * @param shares The amount of shares to convert.
     * @param totalShares The total supply of shares in the vault.
     * @param totalAssets The total amount of assets held by the vault.
     * @return The equivalent amount of assets (rounded up).
     */
    function _toAssetsCeil(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAssets
    ) internal pure returns (uint256) {
        if (totalShares == 0) return 0;
        if (shares == 0) return 0;
        // Ceil division: (a * b + c - 1) / c
        return (shares * totalAssets + totalShares - 1) / totalShares;
    }

    /**
     * @dev Converts assets to shares, rounding up.
     * @param assets The amount of assets to convert.
     * @param totalShares The total supply of shares in the vault.
     * @param totalAssets The total amount of assets held by the vault.
     * @return The equivalent amount of shares (rounded up).
     */
    function _toSharesCeil(
        uint256 assets,
        uint256 totalShares,
        uint256 totalAssets
    ) internal pure returns (uint256) {
        if (totalAssets == 0) return 0; // Initial mint handled by Mansa
        if (assets == 0) return 0;
        // Ceil division: (a * b + c - 1) / c
        return (assets * totalShares + totalAssets - 1) / totalAssets;
    }
}