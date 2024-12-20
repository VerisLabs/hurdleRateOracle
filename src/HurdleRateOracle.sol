// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/// @title Hurdle Rate Oracle
/// @notice Oracle contract that fetches and stores APY rates for Lido and USDY
/// @dev Uses Chainlink Functions to fetch rates and maintains historical data
contract HurdleRateOracle is FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;

    ////////////////////////////////////////////////////////////////
    ///                         ERRORS                             ///
    ////////////////////////////////////////////////////////////////

    error RequestNotFound();
    error IndexOutOfBounds();
    error InvalidTimeRange();
    error InvalidSubscriptionId();

    ////////////////////////////////////////////////////////////////
    ///                        CONSTANTS                           ///
    ////////////////////////////////////////////////////////////////

    // Source code for the Chainlink Functions request
    string private source;

    ////////////////////////////////////////////////////////////////
    ///                      STATE VARIABLES                       ///
    ////////////////////////////////////////////////////////////////

    bytes32 private s_lastRequestId;
    bytes private s_lastResponse;
    bytes private s_lastError;
    uint32 public constant CALLBACK_GAS_LIMIT = 300000;
    uint64 public subscriptionId;
    bytes32 public constant donId = 0x66756e2d626173652d6d61696e6e65742d310000000000000000000000000000;

    /// @notice Current Lido staking APY in basis points
    uint16 public currentLidoRate;
    /// @notice Current USDY APY in basis points
    uint16 public currentUsdyRate;
    /// @notice Timestamp of the last rate update
    uint256 public lastUpdateTimestamp;

    mapping(bytes32 => bool) public pendingRequests;
    RateSnapshot[] public rateHistory;
    mapping(uint256 => uint256) public timestampToIndex;

    ////////////////////////////////////////////////////////////////
    ///                         STRUCTS                            ///
    ////////////////////////////////////////////////////////////////

    struct RateSnapshot {
        uint16 lidoBasisPoints;
        uint16 usdyBasisPoints;
        uint256 timestamp;
    }

    ////////////////////////////////////////////////////////////////
    ///                         EVENTS                             ///
    ////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new rate update request is initiated
    /// @param requestId The ID of the Chainlink Functions request
    event RateUpdateRequested(bytes32 indexed requestId);

    /// @notice Emitted when new rates are successfully received and stored
    /// @param requestId The ID of the fulfilled request
    /// @param lidoRate The new Lido rate in basis points
    /// @param usdyRate The new USDY rate in basis points
    /// @param timestamp When the rates were updated
    /// @param historyIndex Index in the rate history array
    event RateUpdateFulfilled(
        bytes32 indexed requestId,
        uint16 lidoRate,
        uint16 usdyRate,
        uint256 timestamp,
        uint256 historyIndex
    );

    /// @notice Emitted when a request fails with an error
    /// @param requestId The ID of the failed request
    /// @param error The error message or bytes
    event RequestFailed(bytes32 indexed requestId, bytes error);

    /// @notice Emitted when the subscription ID is updated
    /// @param oldSubId The previous subscription ID
    /// @param newSubId The new subscription ID
    event SubscriptionIdUpdated(uint64 oldSubId, uint64 newSubId);

    /// @notice Emitted when historical data is cleaned up
    /// @param fromLength The length of the history before cleanup
    /// @param toLength The length of the history after cleanup
    event HistoryCleaned(uint256 fromLength, uint256 toLength);

    /// @notice Emitted when the source code is updated 
    /// @param newSource The new source code 
    event SourceCodeUpdated(string newSource);

    ///////////////////////////////////////////////////////////////
    ///                     CONSTRUCTOR                           ///
    ////////////////////////////////////////////////////////////////

    /// @notice Initializes the Hurdle Rate Oracle with required Chainlink Functions parameters
    /// @param router The address of the Chainlink Functions router contract
    /// @param _subscriptionId The subscription ID for billing Chainlink Functions requests
    /// @dev Inherits from FunctionsClient and ConfirmedOwner to handle Chainlink Functions and ownership
    constructor(
        address router,
        uint64 _subscriptionId,
        string memory _source
    ) FunctionsClient(router) ConfirmedOwner(msg.sender) {
        subscriptionId = _subscriptionId;
        source = _source;
    }

    ////////////////////////////////////////////////////////////////
    ///                    PUBLIC FUNCTIONS                        ///
    ////////////////////////////////////////////////////////////////

    /// @notice Requests an update for the hurdle rates from the oracle
    /// @dev Initiates a Chainlink Functions request to fetch current APY rates
    function requestRateUpdate() external {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            CALLBACK_GAS_LIMIT,
            donId
        );

        pendingRequests[requestId] = true;
        s_lastRequestId = requestId;
        emit RateUpdateRequested(requestId);
    }

    ////////////////////////////////////////////////////////////////
    ///                   INTERNAL FUNCTIONS                      ///
    ////////////////////////////////////////////////////////////////

    /// @notice Processes the response from Chainlink Functions
    /// @dev Called by the Chainlink network when the request is fulfilled
    /// @param requestId The ID of the request being fulfilled
    /// @param response The response from the API containing packed rates
    /// @param err Error message if the request failed
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (!pendingRequests[requestId]) revert RequestNotFound();
        delete pendingRequests[requestId];

        s_lastResponse = response;
        s_lastError = err;

        if (err.length > 0) {
            emit RequestFailed(requestId, err);
            return;
        }

        uint256 packedValue = abi.decode(response, (uint256));

        // Unpack values
        uint16 newLidoRate = uint16(packedValue >> 16);
        uint16 newUsdyRate = uint16(packedValue & 0xFFFF);

        // Update current rates
        currentLidoRate = newLidoRate;
        currentUsdyRate = newUsdyRate;
        lastUpdateTimestamp = block.timestamp;

        // Store historical snapshot
        uint256 newIndex = rateHistory.length;
        rateHistory.push(
            RateSnapshot(newLidoRate, newUsdyRate, block.timestamp)
        );
        timestampToIndex[block.timestamp] = newIndex;

        emit RateUpdateFulfilled(
            requestId,
            newLidoRate,
            newUsdyRate,
            block.timestamp,
            newIndex
        );
    }

    ////////////////////////////////////////////////////////////////
    ///                     VIEW FUNCTIONS                        ///
    ////////////////////////////////////////////////////////////////

    /// @notice Gets both current rates and their timestamp in one call
    /// @return lidoRate Current Lido rate in basis points
    /// @return usdyRate Current USDY rate in basis points
    /// @return timestamp Last update timestamp
    function getCurrentRates()
        external
        view
        returns (uint16 lidoRate, uint16 usdyRate, uint256 timestamp)
    {
        return (currentLidoRate, currentUsdyRate, lastUpdateTimestamp);
    }

    /// @notice Gets the current Lido staking APY rate
    /// @return rate The current Lido rate in basis points
    /// @return timestamp The timestamp when the rate was last updated
    function getLidoRate()
        external
        view
        returns (uint16 rate, uint256 timestamp)
    {
        return (currentLidoRate, lastUpdateTimestamp);
    }

    /// @notice Gets the current USDY APY rate
    /// @return rate The current USDY rate in basis points
    /// @return timestamp The timestamp when the rate was last updated
    function getUsdyRate()
        external
        view
        returns (uint16 rate, uint256 timestamp)
    {
        return (currentUsdyRate, lastUpdateTimestamp);
    }

    /// @notice Gets the total number of historical rate snapshots
    /// @return The length of the rate history array
    function getRateHistoryLength() external view returns (uint256) {
        return rateHistory.length;
    }

    /// @notice Retrieves a historical rate snapshot by its index
    /// @param index The index of the snapshot to retrieve
    /// @return The rate snapshot containing both APYs and timestamp
    function getRateAtIndex(
        uint256 index
    ) external view returns (RateSnapshot memory) {
        if (index > rateHistory.length) revert IndexOutOfBounds();
        return rateHistory[index];
    }

    /// @notice Retrieves all rate snapshots within a time range
    /// @param startTime The start timestamp of the range
    /// @param endTime The end timestamp of the range
    /// @return Array of rate snapshots within the specified time range
    function getRatesByTimeRange(
        uint256 startTime,
        uint256 endTime
    ) external view returns (RateSnapshot[] memory) {
        if (startTime >= endTime) revert InvalidTimeRange();

        uint256 count = 0;
        for (uint256 i = 0; i < rateHistory.length; i++) {
            if (
                rateHistory[i].timestamp >= startTime &&
                rateHistory[i].timestamp <= endTime
            ) {
                count++;
            }
        }

        RateSnapshot[] memory results = new RateSnapshot[](count);
        uint256 resultIndex = 0;

        for (
            uint256 i = 0;
            i < rateHistory.length && resultIndex < count;
            i++
        ) {
            if (
                rateHistory[i].timestamp >= startTime &&
                rateHistory[i].timestamp <= endTime
            ) {
                results[resultIndex] = rateHistory[i];
                resultIndex++;
            }
        }

        return results;
    }

    /// @notice Check if a request is currently pending
    /// @param requestId The request ID to check
    /// @return True if request is pending, false otherwise
    function isRequestPending(bytes32 requestId) external view returns (bool) {
        return pendingRequests[requestId];
    }

    ////////////////////////////////////////////////////////////////
    ///                     OWNER FUNCTIONS                        ///
    ////////////////////////////////////////////////////////////////
    
    /// @notice Sets the source code for the Chainlink Functions request 
    /// @param _source The new source code to set
    /// @dev Only callable by contract owner
    function setSource(string memory _source) external onlyOwner {
        source = _source;
        emit SourceCodeUpdated(_source);
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

    /// @notice Removes historical data older than specified age
    /// @param maxAge Maximum age of data to keep (in seconds)
    function cleanupOldHistory(uint256 maxAge) external onlyOwner {
        uint256 cutoffTime = block.timestamp - maxAge;
        uint256 i = 0;
        while (i < rateHistory.length) {
            if (rateHistory[i].timestamp < cutoffTime) {
                rateHistory[i] = rateHistory[rateHistory.length - 1];
                rateHistory.pop();
            } else {
                i++;
            }
        }

        emit HistoryCleaned(rateHistory.length + 1, rateHistory.length);
    }
}
