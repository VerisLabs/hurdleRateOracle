//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ReentrancyGuard} from "@solady/utils/ReentrancyGuard.sol";

/// @title Hurdle Rate Oracle
/// @notice Oracle contract that fetches and stores rates for multiple tokens
/// @dev Uses Chainlink Functions to fetch rates using a bitmap with fixed positions, allowing scaling up to 16 rates without additional costs
/// @custom:security ReentrancyGuard, ConfirmedOwner
contract HurdleRateOracle is FunctionsClient, ConfirmedOwner, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;

    ////////////////////////////////////////////////////////////////
    ///                        CONSTANTS                         ///
    ////////////////////////////////////////////////////////////////

    /// @notice Maximum allowed rate in basis points (100%)
    /// @dev 10000 basis points = 100%
    uint16 public constant MAX_RATE_BPS = 10000;
    /// @notice Gas limit for Chainlink Functions callback
    uint32 public constant CALLBACK_GAS_LIMIT = 300000;
    /// @notice Minimum time interval between rate updates
    /// @dev Prevents excessive updates and potential manipulation
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;

    ////////////////////////////////////////////////////////////////
    ///                      STATE VARIABLES                     ///
    ////////////////////////////////////////////////////////////////

    /// @notice Chainlink Functions DON ID (immutable)
    bytes32 public immutable donId;
    /// @notice Chainlink Functions subscription ID
    uint64 public subscriptionId;
    /// @notice Contract pause state
    bool public paused;

    /// @notice JavaScript source code for Chainlink Functions request
    string private source;
    /// @notice Bitmap tracking registered token positions
    uint256 private registeredPositions;
    /// @notice Current rates for all tokens packed into a single uint256
    /// @dev Each rate occupies 16 bits, allowing for up to 16 different rates
    uint256 public currentRates;
    /// @notice Timestamp of the last rate update
    uint256 public lastUpdateTimestamp;

    /// @notice Maps request IDs to their pending status
    mapping(bytes32 => bool) public pendingRequests;
    /// @notice Maps token addresses to their position in the rates bitmap
    mapping(address => uint8) public tokenToPosition;

    ////////////////////////////////////////////////////////////////
    ///                         ERRORS                           ///
    ////////////////////////////////////////////////////////////////

    error InvalidPosition(uint8 position);
    error RequestNotFound();
    error TokenNotRegistered();
    error TokenAlreadyRegistered();
    error UpdateTooFrequent();
    error InvalidRates();
    error InvalidSubscription();
    error RateLimit();
    error InvalidSubscriptionId();
    error Paused();
    error AddressZero();
    error InvalidSource();

    ////////////////////////////////////////////////////////////////
    ///                         EVENTS                           ///
    ////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new rate update request is initiated
    /// @param requestId The ID of the Chainlink Functions request
    event RateUpdateRequested(bytes32 indexed requestId);

    /// @notice Emitted when a rate update request is successfully fulfilled
    /// @param requestId The unique identifier of the fulfilled request
    /// @param newRates The new rates bitmap that was set
    /// @param timestamp The timestamp when rates were updated
    event RateUpdateFulfilled(
        bytes32 indexed requestId,
        uint256 newRates,
        uint256 timestamp
    );

    /// @notice Emitted when a new token is registered
    /// @param token The address of the registered token
    /// @param position The position assigned to the token in the rates bitmap
    event TokenRegistered(address indexed token, uint8 position);

    /// @notice Emitted when a Chainlink Functions request fails
    /// @param requestId The unique identifier of the failed request
    /// @param error The error data returned by Chainlink Functions
    event RequestFailed(bytes32 indexed requestId, bytes error);

    /// @notice Emitted when the subscription ID is updated
    /// @param oldSubId The previous subscription ID
    /// @param newSubId The new subscription ID
    event SubscriptionIdUpdated(uint64 oldSubId, uint64 newSubId);

    /// @notice Emitted when the source code is updated
    /// @param newSource The new source code
    event SourceUpdated(string newSource);

    /// @notice Emitted when the pause state is changed
    /// @param paused The new pause state
    event PauseStateChanged(bool paused);

    ////////////////////////////////////////////////////////////////
    ///                      MODIFIERS                           ///
    ////////////////////////////////////////////////////////////////

    modifier isNotPaused() {
        if (paused) revert Paused();
        _;
    }

    ////////////////////////////////////////////////////////////////
    ///                     INITIALIZATION                       ///
    ////////////////////////////////////////////////////////////////

    /// @notice Constructor initializes the oracle with required parameters
    /// @param router Chainlink Functions router address
    /// @param _subscriptionId Initial Chainlink Functions subscription ID
    /// @param _source Initial JavaScript source code for rate fetching
    constructor(
        address router,
        uint64 _subscriptionId,
        string memory _source
    ) FunctionsClient(router) ConfirmedOwner(msg.sender) {
        if (router == address(0)) revert AddressZero();
        if (_subscriptionId == 0) revert InvalidSubscription();
        subscriptionId = _subscriptionId;
        source = _source;

        donId = 0x66756e2d626173652d6d61696e6e65742d310000000000000000000000000000; // DON ID (Base)

        _registerToken(0x4200000000000000000000000000000000000006, 0); // WETH (Base)
        _registerToken(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 1); // USDCe (Base)
    }

    ////////////////////////////////////////////////////////////////
    ///                     ADMIN FUNCTIONS                      ///
    ////////////////////////////////////////////////////////////////

    /// @notice Sets the contract's pause state
    /// @param _paused New pause state
    /// @dev Only callable by contract owner
    function setPause(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStateChanged(_paused);
    }

    /// @notice Sets the source code for the Chainlink Functions request
    /// @param _source The new source code to set
    /// @dev Only callable by contract owner
    function setSource(string memory _source) external onlyOwner {
        if (bytes(_source).length == 0) revert InvalidSource();
        source = _source;
        emit SourceUpdated(_source);
    }

    /// @notice Sets the Chainlink Functions subscription ID
    /// @param newSubscriptionId The new subscription ID to set
    /// @dev Only callable by contract owner
    function setSubscriptionId(uint64 newSubscriptionId) external onlyOwner {
        if (newSubscriptionId == 0 || newSubscriptionId == subscriptionId)
            revert InvalidSubscriptionId();
        subscriptionId = newSubscriptionId;
        emit SubscriptionIdUpdated(subscriptionId, newSubscriptionId);
    }

    /// @notice Registers a new token at a specific position
    /// @param token Token address to register
    /// @param position Position in the rates bitmap (0-15)
    /// @dev Only callable by contract owner
    function registerToken(address token, uint8 position) external onlyOwner {
        _registerToken(token, position);
    }

    function _registerToken(address token, uint8 position) private {
        if (token == address(0)) revert AddressZero();
        if (position >= 16) revert InvalidPosition(position);
        if (registeredPositions & (1 << position) != 0)
            revert TokenAlreadyRegistered();

        registeredPositions |= 1 << position;
        tokenToPosition[token] = position;

        emit TokenRegistered(token, position);
    }

    ////////////////////////////////////////////////////////////////
    ///                      PUBLIC FUNCTIONS                    ///
    ////////////////////////////////////////////////////////////////

    /// @notice Triggers a rate update via Chainlink Functions
    /// @dev Protected against reentrancy and rate update frequency manipulation
    function updateRates() external nonReentrant isNotPaused {
        if (block.timestamp - lastUpdateTimestamp < MIN_UPDATE_INTERVAL)
            revert UpdateTooFrequent();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);

        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            CALLBACK_GAS_LIMIT,
            donId
        );

        pendingRequests[requestId] = true;

        emit RateUpdateRequested(requestId);
    }

    ////////////////////////////////////////////////////////////////
    ///                     INTERNAL FUNCTIONS                   ///
    ////////////////////////////////////////////////////////////////

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (!pendingRequests[requestId]) revert RequestNotFound();
        delete pendingRequests[requestId];

        if (err.length > 0) {
            emit RequestFailed(requestId, err);
            return;
        }

        uint256 newRates = abi.decode(response, (uint256));
        if (newRates == 0) revert InvalidRates();

        currentRates = newRates;
        lastUpdateTimestamp = block.timestamp;

        emit RateUpdateFulfilled(requestId, newRates, block.timestamp);
    }

    ////////////////////////////////////////////////////////////////
    ///                     VIEW FUNCTIONS                       ///
    ////////////////////////////////////////////////////////////////

    /// @notice Retrieves the rate for a specific token
    /// @param token Address of the token
    /// @return rate Current rate in basis points
    /// @return timestamp Timestamp of the last rate update
    function getRate(
        address token
    ) external view returns (uint16 rate, uint256 timestamp) {
        uint8 position = tokenToPosition[token];
        if (registeredPositions & (1 << position) == 0)
            revert TokenNotRegistered();
        assembly {
            rate := and(
                shr(mul(position, 16), sload(currentRates.slot)),
                0xFFFF
            )
        }
        return (rate, lastUpdateTimestamp);
    }

    /// @notice Returns all current rates as a packed uint256
    /// @return Packed rates bitmap
    function getAllRates() external view returns (uint256) {
        return currentRates;
    }

    /// @notice Retrieves rate for a specific position in the bitmap
    /// @param position Position to query (0-15)
    /// @return Rate at the specified position in basis points
    function getRateByPosition(uint8 position) external view returns (uint16) {
        if (position >= 16) revert InvalidPosition(position);
        return uint16((currentRates >> (position * 16)) & 0xFFFF);
    }

    /// @notice Utility function to create a rates bitmap
    /// @param rates Array of rates to pack into bitmap
    /// @return bitmap Packed rates bitmap
    /// @dev Each rate must be <= MAX_RATE_BPS
    function getBitmap(
        uint16[] calldata rates
    ) external pure returns (uint256 bitmap) {
        if (rates.length > 16) revert RateLimit();

        unchecked {
            for (uint256 i; i < rates.length; ++i) {
                if (rates[i] > MAX_RATE_BPS) revert InvalidRates();
                bitmap |= uint256(rates[i]) << (i * 16);
            }
        }
    }

    /// @notice Returns the bitmap of registered token positions
    /// @dev Each bit represents a position (0-15), where 1 indicates a registered token
    /// @return Bitmap where set bits (1) represent positions that have registered tokens
    function getRegisteredPositions() external view returns (uint256) {
        return registeredPositions;
    }
}
