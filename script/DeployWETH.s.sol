// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {WETH9} from "../src/WETH9.sol";
import "forge-std/Script.sol";

contract DeployWETHScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        new WETH9();
     

        vm.stopBroadcast();
    }
} 