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
        address _weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
        address _nonfungiblePositionManager = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
        address platformWallet = 0x0000000000000000000000000000000000000000;
        address feeCollector = 0x0000000000000000000000000000000000000000;
        address ezswapFactory = 0x3149B149068F76e4438aD1C446E3903a351E105b;
        address bondingCurve = 0x657fE4Fcb432658887BCBfACEa9A308151EC982c;

        dn = new EZDN404(
            name,
            symbol,
            initialSupply,
            owner,
            payable(_weth),
            payable(_nonfungiblePositionManager),
            payable(platformWallet),
            feeCollector,
            ezswapFactory,
            bondingCurve
        );
  
        vm.stopBroadcast();
    }
}
