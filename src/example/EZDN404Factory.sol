// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./EZDN404.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract EZDN404Factory is Ownable {
    
    mapping(address => bool) public isTokenCreated;
    mapping(address => address) public creatorToToken;
    
  
    address public immutable weth;
    address public immutable nonfungiblePositionManager;
    address public immutable platformWallet;
    address public immutable feeCollector;
    address public immutable ezswapFactory;
    address public immutable bondingCurve;

    event TokenCreated(
        address indexed creator,
        address indexed tokenAddress,
        string name,
        string symbol
    );

    constructor(
        address _weth,
        address _nonfungiblePositionManager,
        address _platformWallet,
        address _feeCollector,
        address _ezswapFactory,
        address _bondingCurve
    ) {
        _initializeOwner(msg.sender);
        
        weth = _weth;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        platformWallet = _platformWallet;
        feeCollector = _feeCollector;
        ezswapFactory = _ezswapFactory;
        bondingCurve = _bondingCurve;
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        uint96 initialSupply
    ) external returns (address) {
        require(!isTokenCreated[msg.sender], "Already created a token");
        
        EZDN404 newToken = new EZDN404{salt: keccak256(abi.encodePacked(msg.sender, name, symbol))}(
            name,
            symbol,
            initialSupply,
            msg.sender,
            payable(weth),
            nonfungiblePositionManager,
            platformWallet,
            feeCollector,
            ezswapFactory,
            bondingCurve
        );

        isTokenCreated[msg.sender] = true;
        creatorToToken[msg.sender] = address(newToken);

        newToken.transferOwnership(msg.sender);

        emit TokenCreated(msg.sender, address(newToken), name, symbol);
        
        return address(newToken);
    }

} 