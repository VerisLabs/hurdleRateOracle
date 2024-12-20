// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HurdleRateOracle} from "../src/HurdleRateOracle.sol";

contract DeployHurdleRateOracle is Script {
    // Chainlink Functions Router address for Base Mainnet
    address constant ROUTER = 0xf9B8fc078197181C841c296C876945aaa425B278;
    
    // Default source code for the oracle
    string constant DEFAULT_SOURCE = 
        "const apiResponse = await Functions.makeHttpRequest({"
        "url: `https://api.maxapy.io/hurdle-rate`,"
        "headers: {"
        "'Content-Type': 'application/json'"
        "}"
        "});"
        "if (apiResponse.error) {"
        "throw Error('API Request Error');"
        "}"
        "const { data } = apiResponse;"
        "const packedValue = (BigInt(data.lidoApyBasisPoints) << 16n) | BigInt(data.usdyApyBasisPoints);"
        "return Functions.encodeUint256(packedValue);";

    function run() external returns (HurdleRateOracle) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Configuration
        uint64 subscriptionId = 36; // Your subscription ID

        vm.startBroadcast(deployerPrivateKey);
        
        HurdleRateOracle oracle = new HurdleRateOracle(
            ROUTER,
            subscriptionId,
            DEFAULT_SOURCE
        );

        vm.stopBroadcast();
        
        return oracle;
    }
}
