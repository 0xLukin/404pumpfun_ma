// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./EZDN404.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract TokenFactory is Ownable {
    struct FactoryConfig {
        address weth;
        address nonfungiblePositionManager;
        address platformWallet;
        address feeCollector;
        address ezswapFactory;
        address bondingCurve;
    }

    mapping(address => bool) public isTokenCreated;
    mapping(address => address) public creatorToToken;
    FactoryConfig public config;

    event TokenCreated(
        address indexed creator,
        address indexed tokenAddress,
        string name,
        string symbol
    );

    constructor(FactoryConfig memory _config, address initialOwner) {
        _initializeOwner(initialOwner);
        config = _config;
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        uint96 initialSupply
    ) external returns (address) {
        if (isTokenCreated[msg.sender]) revert("Token already created");

        EZDN404 newToken = new EZDN404{salt: keccak256(abi.encodePacked(msg.sender, name, symbol))}(
            name,
            symbol,
            initialSupply,
            msg.sender,
            payable(config.weth),
            config.nonfungiblePositionManager,
            config.platformWallet,
            config.feeCollector,
            config.ezswapFactory,
            config.bondingCurve
        );

        isTokenCreated[msg.sender] = true;
        creatorToToken[msg.sender] = address(newToken);

        newToken.transferOwnership(msg.sender);

        emit TokenCreated(msg.sender, address(newToken), name, symbol);
        return address(newToken);
    }
} 