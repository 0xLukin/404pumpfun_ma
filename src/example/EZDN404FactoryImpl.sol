// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./EZDN404Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract EZDN404FactoryImpl is UUPSUpgradeable, Ownable {
    event ProxyDeployed(address indexed proxy, address indexed implementation);

    constructor() {}

    function deployProxy(
        address implementation,
        bytes memory data
    ) external returns (address) {
        address proxy = address(new EZDN404Proxy(implementation, data));
        emit ProxyDeployed(proxy, implementation);
        return proxy;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
} 