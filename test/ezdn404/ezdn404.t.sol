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
        
        token.toggleLive();
    }

    /// @notice 测试初始状态设置
    /// @dev 验证合约部署后的基本状态
    function test_InitialState() public {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalMinted(), 0);
        assertTrue(token.live());
        assertTrue(token.isPreTrading());
        assertEq(token.platformWallet(), platformWallet);
        assertEq(token.feeCollector(), feeCollector);
    }

    /// @notice 测试公开铸造功能
    /// @dev 验证正常铸造流程
    function test_PublicMint() public {
        vm.startPrank(alice);
        uint256 mintAmount = 2;
        uint256 cost = token.pbMintPrice() * mintAmount;
        
        token.publicMint{value: cost}(mintAmount);
        
        assertEq(token.balanceOf(alice), mintAmount * (10 ** token.decimals()));
        assertEq(token.totalMinted(), mintAmount);
        vm.stopPrank();
    }

    /// @notice 测试超出铸造限制的情况
    /// @dev 验证超出钱包限制时的铸造失败
    function testFail_MintOverLimit() public {
        vm.startPrank(alice);
        uint256 overLimit = token.MAX_PER_WALLET() + 1;
        uint256 cost = token.pbMintPrice() * overLimit;
        
        vm.expectRevert(EZDN404.InvalidMint.selector);
        token.publicMint{value: cost}(overLimit);
        vm.stopPrank();
    }

    /// @notice 测试内盘交易买入功能
    /// @dev 验证预交易阶段的买入功能
    function test_PreTradingBuy() public {
        vm.startPrank(alice);
        token.publicMint{value: 1 ether}(2);
        
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
        token.publicMint{value: 1 ether}(2);
        token.preTradingBuy{value: 0.1 ether}();
        
        uint256 sellAmount = 1000 * 10**18;
        uint256 expectedEth = token.getETHAmount(sellAmount);
        
        uint256 ethBalanceBefore = address(alice).balance;
        token.preTradingSell(sellAmount);
        uint256 ethBalanceAfter = address(alice).balance;
        
        assertEq(ethBalanceAfter - ethBalanceBefore, expectedEth);
        vm.stopPrank();
    }

    /// @notice 测试外盘交易初始化
    /// @dev 验证从内盘到外盘的转换过程
    function test_InitializeExternalTrading() public {
        vm.deal(address(this), token.PRE_TRADING_MAX_ETH());
        token.preTradingBuy{value: token.PRE_TRADING_MAX_ETH()}();
        
        token.initializeExternalTrading();
        
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
        token.publicMint{value: token.pbMintPrice()}(1);
        vm.stopPrank();
        
        token.unpause();
        assertFalse(token.paused());
    }

    receive() external payable {}
}