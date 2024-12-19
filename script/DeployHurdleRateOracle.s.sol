// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HurdleRateOracle} from "../src/HurdleRateOracle.sol";

contract DeployHurdleRateOracle is Script {
    
    // Chainlink Functions Router addresses per network
    address constant ROUTER_AMOY = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De; // Polygon AMOY

    // Example DON ID for Sepolia (you'll need to replace this)
    bytes32 constant DON_ID = bytes32("fun-polygon-amoy-1");

    function run() external returns (HurdleRateOracle) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Configuration
        address router = ROUTER_AMOY; 
        bytes32 donId = DON_ID;
        uint64 subscriptionId = 401; 
        uint32 gasLimit = 300000;

        vm.startBroadcast(deployerPrivateKey);

        HurdleRateOracle oracle = new HurdleRateOracle(
            router,
            donId,
            subscriptionId,
            gasLimit
        );

        vm.stopBroadcast();

        return oracle;
    }
}
