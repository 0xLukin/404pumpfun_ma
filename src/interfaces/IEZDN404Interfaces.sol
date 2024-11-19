// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ICurve {
    function validateDelta(uint128 delta) external pure returns (bool);
    function validateSpotPrice(uint128 spotPrice) external pure returns (bool);
    function getBuyInfo(
        uint128 spotPrice,
        uint128 delta,
        uint256 numItems,
        uint256 feeMultiplier,
        uint256 protocolFeeMultiplier
    ) external view returns (uint256 newSpotPrice, uint256 inputValue, uint256 protocolFee);
}

interface LSSVMPair {
    enum PoolType {
        TOKEN,
        NFT,
        TRADE
    }
}

interface ILSSVMPairFactory {
    struct CreatePairETHParams {
        IERC721 nft;
        ICurve bondingCurve;
        address payable assetRecipient;
        LSSVMPair.PoolType poolType; 
        uint128 delta;
        uint96 fee;
        uint128 spotPrice;
        uint256[] initialNFTIDs;
    }
    
    function createPairETH(CreatePairETHParams calldata params) external payable returns (LSSVMPairETH pair);
}

interface LSSVMPairETH is LSSVMPair {
    function withdrawAllETH() external;
    function withdrawETH(uint256 amount) external;
    function withdrawERC20(ERC20 token, uint256 amount) external;
} 