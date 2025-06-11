// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// OpenZeppelin v5.x Upgradeable
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Allowlist} from "./Allowlist.sol";
import {VaultMathLib} from "./VaultMathLib.sol";
import "forge-std/console.sol"; // Added for debugging output

contract Mansa is
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // --- State Variables ---
    Allowlist public allowlist;
    IERC20 public usdToken;
    address public custodian;
    uint256 public minInvestmentAmount;
    uint256 public maxInvestmentAmount;
    uint256 public minWithdrawalAmount;
    uint256 public maxWithdrawalAmount;
    bool public open;
    uint256 public dailyYieldMicrobip;
    uint256 public updatedTvlAt;
    uint256 public updatedTvl;
    uint256 public maxTvlGrowthFactor;
    uint256 public emergencyPauseStart;

    mapping(string => bool) private rejectedInvestmentRequests;
    mapping(string => bool) private rejectedWithdrawalRequests;
    mapping(address => uint256) public pendingRefunds;
    mapping(address => uint256) public commitedBalanceOf;
    mapping(address => uint256) public commitedUntil;
    mapping(address => mapping(address => bool)) private _operators;
    mapping(string => InvestmentRequest) internal investmentRequests;
    mapping(string => WithdrawalRequest) internal withdrawalRequests;
    mapping(address => uint256) internal reservedWithdrawalShares;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    enum ClaimInitiator {
        USER,
        OPERATOR,
        ADMIN
    }

    // --- Errors ---
    error NotAllowlisted();
    error EmptyRequestId();
    error InvestmentClosed();
    error AmountBelowMinimum();
    error AmountAboveMaximum();
    error RequestIdExists();
    error RequestNotFound();
    error AlreadyApproved();
    error AlreadyClaimed();
    error NotOwnerOrOperator();
    error ReceiverNotAllowlisted();
    error CommittedBalance();
    error InsufficientBalance();
    error InvalidOperator();
    error InvalidCustodian();
    error CustodianNotAllowlisted();
    error NotApproved();
    error AlreadyRejected();
    error NoRefundAvailable();
    error TvlIncreaseTooLarge();
    error ZeroAmountNotAllowed();

    // --- Events ---
    event InvestmentRequested(
        string requestId,
        uint256 amount,
        address indexed investor,
        uint256 commitedUntil
    );
    event InvestmentApproved(
        string requestId,
        uint256 amount,
        address indexed investor,
        address indexed approver,
        uint256 timestamp
    );
    event InvestmentClaimed(
        string requestId,
        uint256 amount,
        address indexed investor,
        address indexed receiver,
        uint256 shares
    );
    event WithdrawalRequested(
        string requestId,
        uint256 amount,
        address indexed investor
    );
    event WithdrawalApproved(
        string requestId,
        uint256 amount,
        address indexed investor,
        address indexed approver,
        uint256 timestamp
    );
    event WithdrawalClaimed(
        string requestId,
        uint256 amount,
        address indexed investor,
        uint256 shares
    );
    event OperatorChanged(
        address indexed owner,
        address indexed operator,
        bool authorized
    );
    event CustodianChanged(
        address oldCustodian,
        address newCustodian,
        address indexed admin
    );
    event InvestmentRejected(
        string requestId,
        uint256 amount,
        address indexed investor,
        address indexed rejector,
        uint256 timestamp
    );
    event WithdrawalRejected(
        string requestId,
        uint256 amount,
        address indexed investor,
        address indexed rejector,
        uint256 timestamp
    );
    event RefundClaimed(address indexed investor, uint256 amount);
    event Deposit(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event TvlUpdated(uint256 tvl, uint256 timestamp);
    event MaxTvlGrowthFactorChanged(
        uint256 oldFactor,
        uint256 newFactor,
        address indexed admin
    );
    event EmergencyWithdrawal(
        address indexed user,
        uint256 amount,
        address indexed admin,
        uint256 timestamp
    );
    event EmergencyPauseActivated(address indexed admin, uint256 timestamp);
    event EmergencyPauseLifted(address indexed admin, uint256 timestamp);
    event AllowlistChanged(
        address indexed oldAllowlist,
        address indexed newAllowlist,
        address indexed admin
    );
    event MinInvestmentAmountChanged(
        uint256 oldAmount,
        uint256 newAmount,
        address indexed admin
    );
    event MaxInvestmentAmountChanged(
        uint256 oldAmount,
        uint256 newAmount,
        address indexed admin
    );
    event MinWithdrawalAmountChanged(
        uint256 oldAmount,
        uint256 newAmount,
        address indexed admin
    );
    event MaxWithdrawalAmountChanged(
        uint256 oldAmount,
        uint256 newAmount,
        address indexed admin
    );
    event OpenStatusChanged(
        bool oldStatus,
        bool newStatus,
        address indexed admin
    );
    event DailyYieldChanged(
        uint256 oldYield,
        uint256 newYield,
        address indexed admin
    );

    // --- Structs ---
    struct InvestmentRequest {
        uint256 amount;
        address investor;
        bool approved;
        bool claimed;
        uint256 commitedUntil;
    }

    struct WithdrawalRequest {
        uint256 amount;
        uint256 shares;
        address investor;
        bool approved;
        bool claimed;
    }

    uint256[50] private __gap;

    // OpenZeppelin's default _msgSender() handles context correctly for proxies.
    // No override needed unless specific debugging or custom behavior is required.
    // function _msgSender() internal view override returns (address) {
    //     // console.log("--- DEBUG: _msgSender() called ---");
    //     // console.log("msg.sender (raw):", msg.sender);
    //     // console.log("tx.origin (raw):", tx.origin);
    //     return super._msgSender();
    // }

    // --- Initialization & Upgradeability ---
    function initialize(
        Allowlist _allowlist,
        string memory name_,
        string memory symbol_,
        IERC20 _usdToken,
        address _custodian
    ) public initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        require(
            address(_allowlist) != address(0),
            "Allowlist address cannot be zero"
        ); // Fixed: Finding 3
        require(
            address(_usdToken) != address(0),
            "USD token address cannot be zero"
        ); // Fixed: Finding 3
        require(_custodian != address(0), "Custodian address cannot be zero"); // Fixed: Finding 3
        allowlist = _allowlist;
        usdToken = _usdToken;
        custodian = _custodian;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        maxTvlGrowthFactor = 2;

        // --- DEBUG LOGS: Initialize ---
        console.log("--- DEBUG: Initialize ---");
        console.log("Mansa token decimals:", decimals());
        console.log(
            "USD token decimals:",
            IERC20Metadata(address(_usdToken)).decimals()
        );
        console.log("decimalsOffset:", decimalsOffset());
        console.log("Initial minInvestmentAmount:", minInvestmentAmount);
        console.log("Initial maxInvestmentAmount:", maxInvestmentAmount);
        console.log("Initial minWithdrawalAmount:", minWithdrawalAmount);
        console.log("Initial minWithdrawalAmount:", maxWithdrawalAmount);
        console.log("--- END DEBUG LOGS ---");
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    modifier onlyAllowlisted() {
        if (!allowlist.isAllowlisted(_msgSender())) revert NotAllowlisted();
        _;
    }

    modifier validateRequestId(string memory requestId) {
        if (bytes(requestId).length == 0) revert EmptyRequestId();
        _;
    }

    function requestInvestment(
        string memory requestId,
        uint256 amount
    ) public whenNotPaused onlyAllowlisted validateRequestId(requestId) {
        _requestInvestment(requestId, amount, 0);
    }

    function requestInvestmentCommitted(
        string memory requestId,
        uint256 amount,
        uint256 _commitedUntil
    ) public whenNotPaused onlyAllowlisted validateRequestId(requestId) {
        _requestInvestment(requestId, amount, _commitedUntil);
    }

    function _requestInvestment(
        string memory requestId,
        uint256 amount,
        uint256 _commitedUntil
    ) internal virtual nonReentrant {
        if (amount == 0) revert ZeroAmountNotAllowed(); // Fixed: Finding 10
        if (!open) revert InvestmentClosed();
        if (amount < minInvestmentAmount) revert AmountBelowMinimum();
        // --- DEBUG LOGS: _requestInvestment pre-max check ---
        console.log("--- DEBUG: _requestInvestment pre-max check ---");
        console.log("Requested amount:", amount);
        console.log("Max Investment Amount:", maxInvestmentAmount);
        console.log("--- END DEBUG LOGS ---");
        if (amount > maxInvestmentAmount) revert AmountAboveMaximum();
        if (investmentRequests[requestId].investor != address(0))
            revert RequestIdExists();
        uint256 lastRecordedTvl = updatedTvl;
        uint256 currentAccruedTvl = getUpdatedTvl();
        if (lastRecordedTvl > 0 && maxTvlGrowthFactor > 0) {
            if (
                currentAccruedTvl + amount >
                lastRecordedTvl * maxTvlGrowthFactor
            ) {
                revert TvlIncreaseTooLarge();
            }
        }
        address investor = _msgSender();
        usdToken.safeTransferFrom(investor, custodian, amount);
        investmentRequests[requestId] = InvestmentRequest({
            amount: amount,
            investor: investor,
            approved: false,
            claimed: false,
            commitedUntil: _commitedUntil
        });
        emit InvestmentRequested(requestId, amount, investor, _commitedUntil);
    }

    function approveInvestment(
        string memory requestId
    ) public onlyRole(ADMIN_ROLE) validateRequestId(requestId) {
        InvestmentRequest storage request = investmentRequests[requestId];
        if (request.investor == address(0)) revert RequestNotFound();
        if (request.approved) revert AlreadyApproved();
        if (rejectedInvestmentRequests[requestId]) revert AlreadyRejected();
        request.approved = true;
        // CORRECTED: Added 'request.amount' back to the emit statement
        emit InvestmentApproved(
            requestId,
            request.amount,
            request.investor,
            _msgSender(),
            block.timestamp
        );
    }

    function claimInvestment(
        string memory requestId,
        address receiver
    ) public whenNotPaused validateRequestId(requestId) {
        _claimInvestment(
            requestId,
            receiver,
            isOperator(investmentRequests[requestId].investor, _msgSender())
                ? ClaimInitiator.OPERATOR
                : ClaimInitiator.USER
        );
    }

    function approveThenClaimInvestment(
        string memory requestId,
        address receiver
    ) public onlyRole(ADMIN_ROLE) whenNotPaused validateRequestId(requestId) {
        approveInvestment(requestId);
        _claimInvestment(requestId, receiver, ClaimInitiator.ADMIN);
    }

    function _claimInvestment(
        string memory requestId,
        address receiver,
        ClaimInitiator initiator
    ) internal virtual nonReentrant {
        address caller = _msgSender();
        InvestmentRequest storage request = investmentRequests[requestId];
        if (request.investor == address(0)) revert RequestNotFound();
        if (!request.approved) revert NotApproved();
        if (request.claimed) revert AlreadyClaimed();
        if (initiator != ClaimInitiator.ADMIN) {
            if (
                caller != request.investor &&
                !isOperator(request.investor, caller)
            ) {
                revert NotOwnerOrOperator();
            }
        }
        if (!allowlist.isAllowlisted(receiver)) revert ReceiverNotAllowlisted();
        request.claimed = true;

        // Fixed: Finding 2 - Removed hardcoded 10^12, using convertToShares
        uint256 mintedShares = convertToShares(request.amount);

        uint256 currentTvl = getUpdatedTvl();
        uint256 newTvl = currentTvl + request.amount;
        updateTvl(newTvl);

        _mint(receiver, mintedShares);
        if (request.commitedUntil > block.timestamp) {
            commitedBalanceOf[receiver] += mintedShares;
            commitedUntil[receiver] = request.commitedUntil;
        }

        // --- DEBUG LOGS: _claimInvestment Success ---
        console.log("--- DEBUG: _claimInvestment Success ---");
        console.log("Request ID:", requestId);
        console.log("Investor:", request.investor);
        console.log("Receiver:", receiver);
        console.log("Amount deposited (assets):", request.amount);
        console.log("Shares minted:", mintedShares);
        console.log("Receiver's balance after mint:", balanceOf(receiver));
        console.log("Current totalSupply:", totalSupply());
        console.log("Current totalAssets (updatedTvl):", updatedTvl);
        console.log("--- END DEBUG LOGS ---");

        emit InvestmentClaimed(
            requestId,
            request.amount,
            request.investor,
            receiver,
            mintedShares
        );
    }

    function requestDeposit(
        string calldata requestId,
        uint256 assets
    )
        external
        whenNotPaused
        onlyAllowlisted
        validateRequestId(requestId)
        returns (uint256 shares)
    {
        _requestInvestment(requestId, assets, 0);
        shares = convertToShares(assets); // Shares calculated with floor for minting
        emit Deposit(_msgSender(), _msgSender(), assets, shares);
        return shares;
    }

    function requestWithdraw(
        string calldata requestId,
        uint256 assets
    )
        external
        whenNotPaused
        onlyAllowlisted
        validateRequestId(requestId)
        returns (uint256 shares)
    {
        // Calculate shares using ceil for withdrawal to ensure the user has enough shares to burn
        shares = VaultMathLib._toSharesCeil(
            assets,
            totalSupply(),
            totalAssets()
        );
        _requestWithdrawal(requestId, assets, shares);
        emit Withdraw(_msgSender(), _msgSender(), assets, shares);
        return shares;
    }

    function requestWithdrawal(
        string calldata requestId,
        uint256 assets
    )
        external
        whenNotPaused
        onlyAllowlisted
        validateRequestId(requestId)
        returns (uint256 shares)
    {
        shares = VaultMathLib._toSharesCeil(
            assets,
            totalSupply(),
            totalAssets()
        );
        _requestWithdrawal(requestId, assets, shares);
        emit Withdraw(_msgSender(), _msgSender(), assets, shares);
        return shares;
    }

    // In the Mansa contract, modify _requestWithdrawal function:

    function _requestWithdrawal(
        string memory requestId,
        uint256 amount,
        uint256 /* shares */
    ) internal virtual {
        if (amount == 0) revert ZeroAmountNotAllowed(); // Fixed: Finding 10
        if (!open) revert InvestmentClosed();
        if (amount < minWithdrawalAmount) revert AmountBelowMinimum();
        if (amount > maxWithdrawalAmount) revert AmountAboveMaximum();
        if (withdrawalRequests[requestId].investor != address(0))
            revert RequestIdExists();

        address owner = _msgSender();

        // FIX: Add explicit balance check with detailed debugging
        uint256 totalUserShares = balanceOf(owner);

        // DEBUG: Add comprehensive logging
        console.log("=== WITHDRAWAL DEBUG DETAILED ===");
        console.log("owner (_msgSender()):", owner);
        console.log("balanceOf(owner):", totalUserShares);
        console.log("totalSupply():", totalSupply());
        console.log("totalAssets():", totalAssets());

        // FIX: Ensure we have a valid total supply and assets before calculating shares
        if (totalSupply() == 0 || totalAssets() == 0) {
            revert InsufficientBalance();
        }

        uint256 sharesToBurnCalculated = VaultMathLib._toSharesCeil(
            amount,
            totalSupply(),
            totalAssets()
        );

        console.log("amount (USD):", amount);
        console.log("totalUserShares:", totalUserShares);
        console.log(
            "reservedWithdrawalShares:",
            reservedWithdrawalShares[owner]
        );
        console.log("committedBalanceOf:", commitedBalanceOf[owner]);
        console.log("committedUntil:", commitedUntil[owner]);
        console.log("now:", block.timestamp);
        console.log("sharesToBurnCalculated:", sharesToBurnCalculated);

        // FIX: More explicit balance validation
        if (totalUserShares == 0) {
            console.log("ERROR: User has zero shares but trying to withdraw");
            revert InsufficientBalance();
        }

        if (
            commitedBalanceOf[owner] > 0 &&
            block.timestamp < commitedUntil[owner]
        ) {
            uint256 availableAfterBurn = totalUserShares >=
                sharesToBurnCalculated
                ? totalUserShares - sharesToBurnCalculated
                : 0;

            if (availableAfterBurn < commitedBalanceOf[owner]) {
                revert CommittedBalance();
            }

            if (totalUserShares < sharesToBurnCalculated) {
                console.log(
                    "FAIL: totalUserShares < sharesToBurnCalculated (committed case)"
                );
                revert InsufficientBalance();
            }
        } else {
            if (totalUserShares < sharesToBurnCalculated) {
                console.log(
                    "FAIL: totalUserShares < sharesToBurnCalculated (normal case)"
                );
                revert InsufficientBalance();
            }
        }

        // Check available shares after reserved withdrawals
        uint256 availableShares = totalUserShares -
            reservedWithdrawalShares[owner];
        if (availableShares < sharesToBurnCalculated) {
            console.log("FAIL: availableShares < sharesToBurnCalculated");
            revert InsufficientBalance();
        }

        withdrawalRequests[requestId] = WithdrawalRequest({
            amount: amount,
            shares: sharesToBurnCalculated,
            investor: owner,
            approved: false,
            claimed: false
        });

        // Emit the withdrawal requested event
        emit WithdrawalRequested(requestId, amount, owner);
    }

    function approveWithdrawal(
        string memory requestId
    ) public onlyRole(ADMIN_ROLE) validateRequestId(requestId) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.investor == address(0)) revert RequestNotFound();
        if (request.approved) revert AlreadyApproved();
        if (rejectedWithdrawalRequests[requestId]) revert AlreadyRejected();
        request.approved = true;
        reservedWithdrawalShares[request.investor] += request.shares;
        emit WithdrawalApproved(
            requestId,
            request.amount,
            request.investor,
            _msgSender(),
            block.timestamp
        );
    }

    function claimWithdrawal(
        string memory requestId
    ) public whenNotPaused onlyAllowlisted validateRequestId(requestId) {
        _claimWithdrawal(
            requestId,
            isOperator(withdrawalRequests[requestId].investor, _msgSender())
                ? ClaimInitiator.OPERATOR
                : ClaimInitiator.USER
        );
    }

    function approveThenClaimWithdrawal(
        string memory requestId
    ) public onlyRole(ADMIN_ROLE) whenNotPaused validateRequestId(requestId) {
        approveWithdrawal(requestId);
        _claimWithdrawal(requestId, ClaimInitiator.ADMIN);
    }

    function _claimWithdrawal(
        string memory requestId,
        ClaimInitiator initiator
    ) internal virtual nonReentrant {
        address caller = _msgSender();
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.investor == address(0)) revert RequestNotFound();
        if (!request.approved) revert NotApproved();
        if (request.claimed) revert AlreadyClaimed();

        if (initiator != ClaimInitiator.ADMIN) {
            if (
                caller != request.investor &&
                !isOperator(request.investor, caller)
            ) {
                revert NotOwnerOrOperator();
            }
        }

        uint256 reserved = reservedWithdrawalShares[request.investor];
        require(
            reserved >= request.shares,
            "Insufficient reserved shares for this request"
        );
        reservedWithdrawalShares[request.investor] -= request.shares;

        uint256 sharesToBurn = request.shares;
        uint256 amountToTransfer = convertToAssets(sharesToBurn); // convertToAssets uses floor division
        if (amountToTransfer == 0) revert ZeroAmountNotAllowed();

        uint256 currentTvl = getUpdatedTvl();
        uint256 newTvl = currentTvl >= amountToTransfer
            ? currentTvl - amountToTransfer
            : 0;
        updateTvl(newTvl);

        _burn(request.investor, sharesToBurn);
        usdToken.safeTransferFrom(
            custodian,
            request.investor,
            amountToTransfer
        );
        request.claimed = true;

        emit WithdrawalClaimed(
            requestId,
            amountToTransfer,
            request.investor,
            sharesToBurn
        );
    }

    function rejectInvestment(
        string memory requestId
    ) public onlyRole(ADMIN_ROLE) validateRequestId(requestId) nonReentrant {
        InvestmentRequest storage request = investmentRequests[requestId];
        if (request.investor == address(0)) revert RequestNotFound();
        if (request.claimed) revert AlreadyClaimed();
        if (rejectedInvestmentRequests[requestId]) revert AlreadyRejected();

        rejectedInvestmentRequests[requestId] = true;
        pendingRefunds[request.investor] += request.amount;

        emit InvestmentRejected(
            requestId,
            request.amount,
            request.investor,
            _msgSender(),
            block.timestamp
        );
    }

    function rejectWithdrawal(
        string memory requestId
    ) public onlyRole(ADMIN_ROLE) validateRequestId(requestId) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        if (request.investor == address(0)) revert RequestNotFound();
        if (request.claimed) revert AlreadyClaimed();
        if (rejectedWithdrawalRequests[requestId]) revert AlreadyRejected();

        if (request.approved) {
            // Refund reserved shares if the withdrawal was approved before rejection
            reservedWithdrawalShares[request.investor] -= request.shares;
            request.approved = false; // Mark as not approved anymore
        }

        rejectedWithdrawalRequests[requestId] = true;
        emit WithdrawalRejected(
            requestId,
            request.amount,
            request.investor,
            _msgSender(),
            block.timestamp
        );
    }

    function claimRefund() external nonReentrant {
        address owner = _msgSender();
        uint256 amount = pendingRefunds[owner];
        if (amount == 0) revert NoRefundAvailable();

        pendingRefunds[owner] = 0;
        // Transfer from custodian to owner for the refund
        // Fixed: Finding 7 - Transfer from custodian, not contract itself
        usdToken.safeTransferFrom(custodian, owner, amount);

        emit RefundClaimed(owner, amount);
    }

    // Removed the public 'mint' function to prevent unbacked minting.
    // This addresses Finding 4 (Unbacked Minting) and Finding 12 (Dual Access for mint)
    // The internal _mint function is still used by contract logic for asset-backed operations.

    function emergencyWithdraw(
        address user,
        uint256 usdAmount
    ) public onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (usdAmount == 0) revert ZeroAmountNotAllowed(); // Fixed: Finding 10
        if (!allowlist.isAllowlisted(user)) revert ReceiverNotAllowlisted();

        // Use ceil division to determine shares to burn for emergency withdrawal
        uint256 mansaSharesToBurn = VaultMathLib._toSharesCeil(
            usdAmount,
            totalSupply(),
            totalAssets()
        );

        if (balanceOf(user) < mansaSharesToBurn) revert InsufficientBalance();

        uint256 currentTvl = getUpdatedTvl();
        uint256 newTvl = currentTvl >= usdAmount ? currentTvl - usdAmount : 0;
        updateTvl(newTvl); // Fixed: Finding 11

        _burn(user, mansaSharesToBurn);
        usdToken.safeTransferFrom(custodian, user, usdAmount);
        emit EmergencyWithdrawal(
            user,
            usdAmount,
            _msgSender(),
            block.timestamp
        );
    }

    function initiateEmergencyPause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
        emergencyPauseStart = block.timestamp;
        emit EmergencyPauseActivated(_msgSender(), emergencyPauseStart);
    }

    function liftEmergencyPause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
        emit EmergencyPauseLifted(_msgSender(), block.timestamp);
    }

    function setAllowlist(
        address newAllowlist
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAllowlist != address(0), "Allowlist address cannot be zero");
        address oldAllowlist = address(allowlist);
        allowlist = Allowlist(newAllowlist);
        emit AllowlistChanged(oldAllowlist, newAllowlist, _msgSender()); // Fixed: Finding 5 - Added function and event
    }

    function setMaxTvlGrowthFactor(
        uint256 newFactor
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFactor >= 1, "Factor must be >= 1");

        uint256 oldFactor = maxTvlGrowthFactor;
        maxTvlGrowthFactor = newFactor;
        emit MaxTvlGrowthFactorChanged(oldFactor, newFactor, _msgSender());
    }

    function setCustodian(
        address _custodian
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_custodian == address(0)) revert InvalidCustodian();
        if (!allowlist.isAllowlisted(_custodian))
            revert CustodianNotAllowlisted();
        address oldCustodian = custodian;
        custodian = _custodian;
        emit CustodianChanged(oldCustodian, _custodian, _msgSender());
    }

    function setMinInvestmentAmount(
        uint256 amount
    ) public onlyRole(ADMIN_ROLE) {
        uint256 oldAmount = minInvestmentAmount;
        minInvestmentAmount = amount;
        emit MinInvestmentAmountChanged(oldAmount, amount, _msgSender());
    }

    function setMaxInvestmentAmount(
        uint256 amount
    ) public onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmountNotAllowed(); // Fixed: Finding 10
        uint256 oldAmount = maxInvestmentAmount;
        maxInvestmentAmount = amount;
        emit MaxInvestmentAmountChanged(oldAmount, amount, _msgSender());
    }

    function setMinWithdrawalAmount(
        uint256 amount
    ) public onlyRole(ADMIN_ROLE) {
        uint256 oldAmount = minWithdrawalAmount;
        minWithdrawalAmount = amount;
        emit MinWithdrawalAmountChanged(oldAmount, amount, _msgSender());
    }

    function setMaxWithdrawalAmount(
        uint256 amount
    ) public onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmountNotAllowed();
        uint256 oldAmount = maxWithdrawalAmount;
        maxWithdrawalAmount = amount;
        emit MaxWithdrawalAmountChanged(oldAmount, amount, _msgSender());
    }

    function setOpen(bool _open) public onlyRole(ADMIN_ROLE) {
        bool oldStatus = open;
        open = _open;
        emit OpenStatusChanged(oldStatus, _open, _msgSender());
    }

    function setDailyYieldMicrobip(
        uint256 _dailyYieldMicrobip
    ) public onlyRole(ADMIN_ROLE) {
        uint256 oldYield = dailyYieldMicrobip;
        dailyYieldMicrobip = _dailyYieldMicrobip;
        emit DailyYieldChanged(oldYield, _dailyYieldMicrobip, _msgSender());
    }

    function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function asset() public view returns (address) {
        return address(usdToken);
    }

    function totalAssets() public view returns (uint256) {
        return getUpdatedTvl();
    }

    function updateTvl(uint256 newTvl) internal virtual {
        uint256 currentTvl = this.getUpdatedTvl();

        if (currentTvl > 0 && maxTvlGrowthFactor > 0) {
            // Protege contra overflow: se a multiplicação excede o uint256, usa max diretamente
            uint256 maxAllowed = currentTvl > type(uint256).max / maxTvlGrowthFactor
                ? type(uint256).max
                : currentTvl * maxTvlGrowthFactor;

            if (newTvl > maxAllowed) revert TvlIncreaseTooLarge(); // Fixed: Finding 6
        }

        updatedTvl = newTvl;
        updatedTvlAt = block.timestamp;
        emit TvlUpdated(newTvl, block.timestamp);
    }

    function getUpdatedTvl() public view returns (uint256) {
        return
            VaultMathLib.accrueTvl(
                updatedTvl,
                updatedTvlAt,
                dailyYieldMicrobip,
                block.timestamp
            );
    }

    // Converts shares to assets (rounding down). This is used when giving assets out.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return VaultMathLib._toAssets(shares, totalSupply(), totalAssets());
    }

    // Converts assets to shares (rounding down for deposits/minting).
    // This is used for standard deposits.
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalAssets() == 0 || totalSupply() == 0) {
            return assets * (10 ** decimalsOffset());
        }
        return VaultMathLib._toShares(assets, totalSupply(), totalAssets());
    }

    function decimalsOffset() public view returns (uint8) {
        uint8 vaultDecimals = decimals(); // Mansa token decimals (typically 18)
        uint8 assetDecimals = IERC20Metadata(asset()).decimals(); // Underlying asset decimals (e.g., MockUSD, 6)
        return
            vaultDecimals > assetDecimals ? vaultDecimals - assetDecimals : 0;
    }

    function setOperator(
        address operator,
        bool authorized
    ) public onlyAllowlisted {
        if (operator == address(0)) revert InvalidOperator();
        _operators[_msgSender()][operator] = authorized;
        emit OperatorChanged(_msgSender(), operator, authorized);
    }

    function isOperator(
        address owner,
        address operator
    ) public view returns (bool) {
        return _operators[owner][operator];
    }

    function checkCustodianHealth()
        public
        view
        returns (uint256 internalTvl, uint256 custodianBalance)
    {
        internalTvl = totalAssets();
        custodianBalance = usdToken.balanceOf(custodian);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        return maxInvestmentAmount;
    }

    function maxMint(address) public view virtual returns (uint256) {
        // Use ceil division to tell user max shares they can mint for max assets,
        // as this is a preview of *how many* shares they'll get.
        // Needs totalAssets() and totalSupply() to be non-zero for accurate calculation.
        if (totalAssets() == 0 || totalSupply() == 0) {
            // If vault is empty, max mint is maxInvestmentAmount scaled to shares
            return maxInvestmentAmount * (10 ** decimalsOffset());
        }
        return
            VaultMathLib._toSharesCeil(
                maxInvestmentAmount,
                totalSupply(),
                totalAssets()
            );
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        // Max assets user can withdraw based on max redeemable shares (rounding down)
        return convertToAssets(maxRedeem(owner));
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        uint256 totalUserShares = balanceOf(owner);
        uint256 committed = commitedBalanceOf[owner];
        uint256 reserved = reservedWithdrawalShares[owner];

        if (committed > 0 && block.timestamp < commitedUntil[owner]) {
            if (totalUserShares <= committed) return 0;
            totalUserShares -= committed;
        }

        if (totalUserShares <= reserved) return 0;
        return totalUserShares - reserved;
    }

    // Preview: how many shares would `assets` give? (Rounding down, conservative)
    function previewDeposit(
        uint256 assets
    ) public view virtual returns (uint256) {
        return convertToShares(assets);
    }

    // Preview: how many assets would `shares` give? (Rounding down, conservative)
    function previewMint(uint256 shares) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    // Preview: how many shares would `assets` require to withdraw? (Rounding up, conservative for the contract)
    function previewWithdraw(
        uint256 assets
    ) public view virtual returns (uint256) {
        if (totalAssets() == 0) return 0; // No assets, no shares to withdraw
        return VaultMathLib._toSharesCeil(assets, totalSupply(), totalAssets());
    }

    // Preview: how many assets would `shares` yield on redemption? (Rounding down, conservative)
    function previewRedeem(
        uint256 shares
    ) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    // Custom approve function to prevent front-running attacks on allowance changes
    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        address owner = _msgSender();
        // Disallow setting non-zero allowance if allowance is already non-zero
        // to prevent front-running where an attacker consumes the allowance before the new one is set.
        if (amount > 0 && allowance(owner, spender) > 0)
            revert("ERC20: approve from non-zero to non-zero allowance");
        _approve(owner, spender, amount);
        return true;
    }

    // Internal hook for ERC20 transfers
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // Prevent transfers of committed shares
        if (from != address(0) && to != address(0)) {
            if (!allowlist.isAllowlisted(to)) revert ReceiverNotAllowlisted(); // Ensure receiver is allowlisted
            if (commitedBalanceOf[from] > 0) {
                // If the sender has committed balance and the commitment is still active,
                // ensure they don't transfer committed shares.
                if (
                    block.timestamp < commitedUntil[from] &&
                    balanceOf(from) - amount < commitedBalanceOf[from]
                ) {
                    revert CommittedBalance();
                }
            }
        }
        super._update(from, to, amount);
    }
}
