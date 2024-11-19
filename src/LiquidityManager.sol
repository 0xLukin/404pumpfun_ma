// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {WETH} from "solady/tokens/WETH.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

abstract contract LiquidityManager {
    WETH public immutable weth;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    uint24 public constant poolFee = 3000;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 60;

    struct Deposit {
        address owner;
        uint128 liquidity;
        address token0;
        address token1;
    }

    mapping(uint256 => Deposit) public deposits;
    mapping(address => uint256[]) public ownLPs;

    event LiquidityAdded(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    constructor(address _weth, address _nonfungiblePositionManager) {
        weth = WETH(payable(_weth));
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
    }

    function _createDeposit(address owner, uint256 tokenId) internal {
        (,, address token0, address token1,,,, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(tokenId);
        deposits[tokenId] = Deposit({
            owner: owner,
            liquidity: liquidity,
            token0: token0,
            token1: token1
        });
        ownLPs[owner].push(tokenId);
    }

    function _addUniswapLiquidity(
        uint256 ethAmount,
        uint256 tokenAmount
    ) internal virtual returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        weth.deposit{value: ethAmount}();
        
        address token0 = address(weth);
        address token1 = address(this);
        uint256 amount0Desired = ethAmount;
        uint256 amount1Desired = tokenAmount;
        
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (amount0Desired, amount1Desired) = (amount1Desired, amount0Desired);
        }

        address factory = nonfungiblePositionManager.factory();
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, poolFee);
        
        if (pool == address(0)) {
            pool = IUniswapV3Factory(factory).createPool(token0, token1, poolFee);
            uint160 sqrtPriceX96 = token0 == address(weth) 
                ? uint160(79228162514264337593543950336)
                : uint160(792281625142643375935439503);
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        int24 minTick = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (MAX_TICK / tickSpacing) * tickSpacing;

        TransferHelper.safeApprove(token0, address(nonfungiblePositionManager), amount0Desired);
        TransferHelper.safeApprove(token1, address(nonfungiblePositionManager), amount1Desired);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: poolFee,
            tickLower: minTick,
            tickUpper: maxTick,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 20 minutes
        });

        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);
        
        _createDeposit(address(this), tokenId);

        // Handle remaining tokens
        if (amount0 < amount0Desired) {
            if (token0 == address(weth)) {
                weth.withdraw(amount0Desired - amount0);
                SafeTransferLib.safeTransferETH(msg.sender, amount0Desired - amount0);
            } else {
                _handleRemainingTokens(amount0Desired - amount0);
            }
        }
        if (amount1 < amount1Desired) {
            if (token1 == address(weth)) {
                weth.withdraw(amount1Desired - amount1);
                SafeTransferLib.safeTransferETH(msg.sender, amount1Desired - amount1);
            } else {
                _handleRemainingTokens(amount1Desired - amount1);
            }
        }

        emit LiquidityAdded(tokenId, liquidity, amount0, amount1);
    }

    function collectLPFee(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager
            .CollectParams({
            tokenId: tokenId,
            recipient: deposits[tokenId].owner,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (amount0, amount1) = nonfungiblePositionManager.collect(params);
    }

    function _handleRemainingTokens(uint256 amount) internal virtual;

    function _transfer(address from, address to, uint256 amount) internal virtual;
} 