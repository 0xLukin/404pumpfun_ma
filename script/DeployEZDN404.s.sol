// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EZDN404} from "../src/example/EZDN404.sol";
import "forge-std/Script.sol";

contract EZN404Script is Script {
    EZDN404 dn;
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory name = "ez404test";
        string memory symbol = "ez404test";
        uint96 initialSupply = 0;
        address owner = 0x21C8e614CD5c37765411066D2ec09912020c846F;
        address _weth = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        address _nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

        dn = new EZDN404(name, symbol, initialSupply, owner, payable(_weth), _nonfungiblePositionManager);
        dn.toggleLive();
        vm.stopBroadcast();
    }
}
