// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EZDN404} from "../../src/example/EZDN404.sol";
import ".././utils/SoladyTest.sol";

import {console2} from "forge-std2/console2.sol";

import {WETH} from "solady/tokens/WETH.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

contract EZDN404Test is SoladyTest {
    uint256 internal constant _WAD = 10 ** 18;

    EZDN404 dn;

    address alice = 0x21C8e614CD5c37765411066D2ec09912020c846F;
    address bob = address(222);

    uint96 pbPrice = 0.001 ether;
    uint96 wlPrice = 0.0001 ether;

    WETH public weth = WETH(payable(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270)); // wmatic: 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270

    ISwapRouter public swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    uint24 public constant poolFee = 3000;

    function setUp() public {
        string memory name = "ez404test";
        string memory symbol = "ez404test";
        uint96 initialSupply = 0;
        address owner = alice;
        address _weth = address(weth);
        address _nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

        dn = new EZDN404(
            name, symbol, initialSupply, owner, payable(_weth), _nonfungiblePositionManager
        );

        dn.toggleLive();
        // payable(bob).transfer(10 ether);
        payable(alice).transfer(10 ether);
    }

    function testMint() public {
        vm.startPrank(alice);

        console2.log(address(dn).balance);

        dn.publicMint{value: 2 * pbPrice}(2);

        dn.whitelistMint{value: 1 * wlPrice}(1);

        uint afterwethbalance = swapExactInputSingle(dn.balanceOf(alice));
        console2.log('swap after weth balance', afterwethbalance);

        dn.publicMint{value: 2 * pbPrice}(2);

        (uint256 amount0, uint256 amount1) = dn.queryLPFee(alice);

        console2.log("amount0", amount0);
        console2.log("amount1", amount1);

        // console2.log(dn.getOwnLPs(alice, 0));

        // console2.log('404 balance', dn.balanceOf(alice));
        
        // console2.log(dn.getOwnLPs(alice, 0));

        // console2.log(alice);
        // console2.log(alice.balance);

        // uint balancebefore = weth.balanceOf(alice);
        // console2.log(balancebefore);

        // weth.deposit{value: 1 ether}();
        // uint balanceafter = weth.balanceOf(alice);
        // console2.log(balanceafter);

        // vm.expectRevert(NFTMintDN404.InvalidPrice.selector);
        // dn.whitelistMint{value: 1 ether}(1);

        // dn.mint{value: 3 * publicPrice}(3);
        // assertEq(dn.totalSupply(), 1003 * _WAD);
        // assertEq(dn.balanceOf(bob), 3 * _WAD);

        // dn.mint{value: 2 * publicPrice}(2);
        // assertEq(dn.totalSupply(), 1005 * _WAD);
        // assertEq(dn.balanceOf(bob), 5 * _WAD);

        // vm.expectRevert(NFTMintDN404.InvalidMint.selector);
        // dn.mint{value: publicPrice}(1);

        // vm.stopPrank();
    }

    function swapExactInputSingle(uint256 amountIn) public returns (uint256 amountOut) {

        // Approve the router to spend DAI.
        TransferHelper.safeApprove(address(dn), address(swapRouter), amountIn);

        // Naively set amountOutMinimum to 0. In production, use an oracle or other data source to choose a safer value for amountOutMinimum.
        // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(dn),
                tokenOut: address(weth),
                fee: poolFee,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        // The call to `exactInputSingle` executes the swap.
        amountOut = swapRouter.exactInputSingle(params);
    }

    // function testTotalSupplyReached() internal {
    //     // Mint out whole supply
    //     for (uint160 i; i < 5000; ++i) {
    //         address a = address(i + 1000);
    //         payable(a).transfer(1 ether);
    //         vm.prank(a);
    //         dn.mint{value: publicPrice}(1);
    //     }

    //     vm.prank(alice);
    //     vm.expectRevert(NFTMintDN404.TotalSupplyReached.selector);
    //     dn.mint{value: publicPrice}(1);
    // }

    // function testAllowlistMint() internal {
    //     vm.prank(bob);

    //     bytes32[] memory proof; // Height one tree, so empty proof.
    //     vm.expectRevert(NFTMintDN404.InvalidProof.selector);
    //     dn.allowlistMint{value: 5 * allowlistPrice}(5, proof);

    //     vm.startPrank(alice);

    //     vm.expectRevert(NFTMintDN404.InvalidPrice.selector);
    //     dn.allowlistMint{value: 1 ether}(1, proof);

    //     dn.allowlistMint{value: 5 * allowlistPrice}(5, proof);
    //     assertEq(dn.totalSupply(), 1005 * _WAD);
    //     assertEq(dn.balanceOf(alice), 5 * _WAD);

    //     vm.expectRevert(NFTMintDN404.InvalidMint.selector);
    //     dn.allowlistMint{value: allowlistPrice}(1, proof);

    //     vm.stopPrank();
    // }
}
