// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {EZDN404} from "../../src/example/EZDN404.sol";
import {WETH} from "solady/tokens/WETH.sol";

contract EZDN404Test is Test {
    EZDN404 public token;
    WETH public weth;
    
    address public owner;
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public platformWallet = address(0x3);
    address public feeCollector = address(0x4);
    
    // Mock addresses for EZSwap components
    address public mockEZSwapFactory = address(0x5);
    address public mockBondingCurve = address(0x6);
    
    uint256 constant INITIAL_BALANCE = 100 ether;

    function setUp() public {
        // First deploy WETH
        weth = new WETH();
        
        owner = address(this);
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        
        // Try deploying with more verbose error handling
        vm.expectRevert();  // Remove this after debugging
        token = new EZDN404(
            "Test Token",
            "TEST",
            0,  // Initial supply - might need to be non-zero
            owner,
            payable(address(weth)),
            payable(address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88)),  // Uniswap Position Manager
            payable(platformWallet),
            feeCollector,
            mockEZSwapFactory,
            mockBondingCurve
        );
        
        // token.toggleLive();
    }


  

    /// @notice 测试内盘交易买入功能
    /// @dev 验证预交易阶段的买入功能
    function test_PreTradingBuy() public {
        vm.startPrank(alice);
   
        
        uint256 buyAmount = 0.1 ether;
        uint256 expectedTokens = token.getTokenAmount(buyAmount);
        
        uint256 balanceBefore = token.balanceOf(alice);
        token.preTradingBuy{value: buyAmount}();
        uint256 balanceAfter = token.balanceOf(alice);
        
        assertTrue(token.hasTraded(alice));
        assertEq(balanceAfter - balanceBefore, expectedTokens);
        vm.stopPrank();
    }

    /// @notice 测试内盘交易卖出功能
    /// @dev 验证预交易阶段的卖出功能
    function test_PreTradingSell() public {
        vm.startPrank(alice);
     
        token.preTradingBuy{value: 0.1 ether}();
        
        uint256 sellAmount = 1000 * 10**18;
        uint256 expectedEth = token.getETHAmount(sellAmount);
        
        uint256 ethBalanceBefore = address(alice).balance;
        // token.preTradingSell(sellAmount);
        uint256 ethBalanceAfter = address(alice).balance;
        
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedEth);
        vm.stopPrank();
    }

    /// @notice 测试外盘交易初始化
    /// @dev 验证从内盘到外盘的转换过程
    function test_InitializeExternalTrading() public {
        vm.deal(address(this), token.PRE_TRADING_MAX_ETH());
        token.preTradingBuy{value: token.PRE_TRADING_MAX_ETH()}();
        
        token.initializeExternalTrading_uniswap();
        
        assertFalse(token.isPreTrading());
        assertTrue(token.isInitialized());
    }

    /// @notice 测试紧急暂停功能
    /// @dev 验证合约暂停和恢复功能
    function test_EmergencyPause() public {
        token.pause();
        assertTrue(token.paused());
        
        vm.startPrank(alice);
        vm.expectRevert("Paused");

        vm.stopPrank();
        
        token.unpause();
        assertFalse(token.paused());
    }

    receive() external payable {}
}