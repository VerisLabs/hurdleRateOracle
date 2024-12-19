// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
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
    error InvalidGasLimit();
    error InvalidDonId();
    error InvalidSubscriptionId();

    ////////////////////////////////////////////////////////////////
    ///                        CONSTANTS                           ///
    ////////////////////////////////////////////////////////////////

    // Source code for the Chainlink Functions request
    string private constant SOURCE_CODE =
        "if(!secrets.signature) {"
        "throw Error('No signature');"
        "}"
        "const apiResponse = await Functions.makeHttpRequest({"
        "url: `https://api.maxapy.io/hurdle-rate`,"
        "headers: {"
        '"Content-Type": "application/json",'
        '"signature": secrets.signature'
        "}"
        "});"
        "if (apiResponse.error) {"
        "throw Error('API Request Error');"
        "}"
        "const { data } = apiResponse;"
        "const packedValue = (BigInt(data.lidoApyBasisPoints) << 16n) | BigInt(data.usdyApyBasisPoints);"
        "return Functions.encodeUint256(packedValue);";

    ////////////////////////////////////////////////////////////////
    ///                      STATE VARIABLES                       ///
    ////////////////////////////////////////////////////////////////

    /// @notice Chainlink Functions DON ID
    bytes32 public donId;
    /// @notice Chainlink Functions subscription ID for billing
    uint64 public subscriptionId;
    /// @notice Gas limit for callback fulfillment
    uint32 private gasLimit;

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

    /// @notice Emitted when the DON ID is updated
    /// @param oldDonId The previous DON ID
    /// @param newDonId The new DON ID
    event DonIdUpdated(bytes32 oldDonId, bytes32 newDonId);

    /// @notice Emitted when the subscription ID is updated
    /// @param oldSubId The previous subscription ID
    /// @param newSubId The new subscription ID
    event SubscriptionIdUpdated(uint64 oldSubId, uint64 newSubId);

    /// @notice Emitted when the gas limit is updated
    /// @param oldLimit The previous gas limit
    /// @param newLimit The new gas limit
    event GasLimitUpdated(uint32 oldLimit, uint32 newLimit);

    /// @notice Emitted when historical data is cleaned up
    /// @param fromLength The length of the history before cleanup
    /// @param toLength The length of the history after cleanup
    event HistoryCleaned(uint256 fromLength, uint256 toLength);

    ///////////////////////////////////////////////////////////////
    ///                     CONSTRUCTOR                           ///
    ////////////////////////////////////////////////////////////////

    /// @notice Initializes the Hurdle Rate Oracle with required Chainlink Functions parameters
    /// @param router The address of the Chainlink Functions router contract
    /// @param _donId The DON ID for the Chainlink Functions network
    /// @param _subscriptionId The subscription ID for billing Chainlink Functions requests
    /// @param _gasLimit The gas limit for callback fulfillment
    /// @dev Inherits from FunctionsClient and ConfirmedOwner to handle Chainlink Functions and ownership
    constructor(
        address router,
        bytes32 _donId,
        uint64 _subscriptionId,
        uint32 _gasLimit
    ) FunctionsClient(router) ConfirmedOwner(msg.sender) {
        donId = _donId;
        subscriptionId = _subscriptionId;
        gasLimit = _gasLimit;
    }

    ////////////////////////////////////////////////////////////////
    ///                    PUBLIC FUNCTIONS                        ///
    ////////////////////////////////////////////////////////////////

    /// @notice Requests an update for the hurdle rates from the oracle
    /// @dev Initiates a Chainlink Functions request to fetch current APY rates
    function requestRateUpdate(
        uint8 donHostedSecretsSlotID,
        uint64 donHostedSecretsVersion
    ) external {
        FunctionsRequest.Request memory req;
        req.initializeRequest(
            FunctionsRequest.Location.Inline,
            FunctionsRequest.CodeLanguage.JavaScript,
            SOURCE_CODE
        );

        if (donHostedSecretsVersion > 0) {
            req.addDONHostedSecrets(
                donHostedSecretsSlotID,
                donHostedSecretsVersion
            );
        }

        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donId
        );

        pendingRequests[requestId] = true;
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
    function _fulfillRequest(
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

    /// @notice Sets the Chainlink Functions DON ID
    /// @param newDonId The new DON ID to set
    /// @dev Only callable by contract owner
    function setDonId(bytes32 newDonId) external onlyOwner {
        if (newDonId == 0 || newDonId == donId) revert InvalidDonId();
        donId = newDonId;

        emit DonIdUpdated(donId, newDonId);
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

    /// @notice Sets the gas limit for Chainlink Functions callbacks
    /// @param newGasLimit The new gas limit to set
    /// @dev Only callable by contract owner
    function setGasLimit(uint32 newGasLimit) external onlyOwner {
        if (newGasLimit == 0) revert InvalidGasLimit();
        gasLimit = newGasLimit;

        emit GasLimitUpdated(gasLimit, newGasLimit);
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
