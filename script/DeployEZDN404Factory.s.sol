// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EZDN404FactoryImpl} from "../src/example/EZDN404FactoryImpl.sol";
import {TokenFactory} from "../src/example/TokenFactory.sol";
import "forge-std/Script.sol";

contract EZN404FactoryScript is Script {
    EZDN404FactoryImpl implementation;
    TokenFactory tokenFactory;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // Arbitrum Sepolia 
        address _weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
        address _nonfungiblePositionManager = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
        address platformWallet = 0x0000000000000000000000000000000000000000;
        address feeCollector = 0x0000000000000000000000000000000000000000;
        address ezswapFactory = 0x3149B149068F76e4438aD1C446E3903a351E105b;
        address bondingCurve = 0x657fE4Fcb432658887BCBfACEa9A308151EC982c;

        implementation = new EZDN404FactoryImpl();

        TokenFactory.FactoryConfig memory config = TokenFactory.FactoryConfig({
            weth: _weth,
            nonfungiblePositionManager: _nonfungiblePositionManager,
            platformWallet: platformWallet,
            feeCollector: feeCollector,
            ezswapFactory: ezswapFactory,
            bondingCurve: bondingCurve
        });

        tokenFactory = new TokenFactory(config, deployer);

        vm.stopBroadcast();
    }
} 