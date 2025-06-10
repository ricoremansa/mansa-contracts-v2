// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./Mansa.sol";

/**
 * @title MansaV2
 * @dev An upgraded extension of the Mansa contract.
 * @notice This version correctly overrides withdrawal logic to be proxy-aware
 * and implements ERC4626 view functions while respecting all balance commitments and reservations.
 */
contract MansaV2 is Mansa {
    uint256 public newConfig;

    /**
     * @dev Initializer for the V2 contract. Can only be called once after an upgrade.
     * @param config A new configuration parameter for V2.
     */
    function initializeV2(uint256 config) external reinitializer(2) {
        newConfig = config;
    }

    /**
     * @dev Returns the contract version.
     */
    function version() external pure returns (string memory) {
        return "MansaV2";
    }

    /**
     * @dev Increases the maximum investment amount.
     * @param additional The amount to add to the current maximum.
     */
    function increaseMaxInvestment(
        uint256 additional
    ) external onlyRole(ADMIN_ROLE) {
        uint256 oldMax = maxInvestmentAmount;
        uint256 newMax = oldMax + additional;
        setMaxInvestmentAmount(newMax);
    }
    
    /**
     * @dev Allows the DEFAULT_ADMIN_ROLE to renounce the custodian.
     * This is a sensitive function and should be used with extreme caution.
     */
    function renounceCustodian() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCustodian(address(0));
    }


    /**
     * @dev Internal function to set a new custodian. Made internal to be called by safer, role-protected functions.
     * @param newCustodian The address of the new custodian.
     */
    function _setCustodian(address newCustodian) internal {
        address old = custodian;
        custodian = newCustodian;
        emit CustodianChanged(old, newCustodian, _msgSender());
    }

    /**
     * @dev Overrides the base _requestWithdrawal function to correctly use _msgSender() in a proxy context.
     * This version incorporates all the security checks from the hardened base contract.
     */
    function _requestWithdrawal(
        string memory requestId,
        uint256 amount,
        uint256 shares
    ) internal virtual override {
        require(amount > 0, "Amount must be greater than zero");

        if (!open) revert InvestmentClosed();
        if (amount < minWithdrawalAmount) revert AmountBelowMinimum();
        if (amount > maxWithdrawalAmount) revert AmountAboveMaximum();
        if (withdrawalRequests[requestId].investor != address(0))
            revert RequestIdExists();

        address owner = _msgSender();

        uint256 userShares = balanceOf(owner);
        uint256 assetsFromUserShares = convertToAssets(userShares);

        if (assetsFromUserShares < amount) {
            revert InsufficientBalance();
        }

        if (
            commitedBalanceOf[owner] > 0 &&
            block.timestamp < commitedUntil[owner] &&
            userShares - shares < commitedBalanceOf[owner]
        ) {
            revert CommittedBalance();
        }

        withdrawalRequests[requestId] = WithdrawalRequest({
            amount: amount,
            shares: shares,
            investor: owner,
            approved: false,
            claimed: false
        });
    }

    // --- Overridden ERC-4626 Read-Only Functions ---

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view virtual override returns (uint256) {
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view virtual override returns (uint256) {
        return super.maxRedeem(owner);
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return super.previewDeposit(assets);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        return super.previewMint(shares);
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        return super.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return super.previewRedeem(shares);
    }
}
