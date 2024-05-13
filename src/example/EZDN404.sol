// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../DN404.sol";
import "../DN404Mirror.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {WETH} from "solady/tokens/WETH.sol";

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/base/LiquidityManagement.sol";

/**
 * @title NFTMintDN404
 * @notice Sample DN404 contract that demonstrates the owner selling NFTs rather than the fungible token.
 * The underlying call still mints ERC20 tokens, but to the end user it'll appear as a standard NFT mint.
 * Each address is limited to MAX_PER_WALLET total mints.
 */
contract EZDN404 is DN404, Ownable, IERC721Receiver {
    string private _name;
    string private _symbol;
    string private _baseURI;

    uint32 public totalMinted; // DN404 only supports up to `2**32 - 2` tokens.
    bool public live;

    uint256 public pbMintPrice = 0.001 ether;
    uint256 public wlMintPrice = 0.0001 ether;

    uint32 public constant MAX_PER_WALLET = 5;
    uint32 public constant MAX_SUPPLY = 5000;

    WETH public weth;

    // uniswapv3
    uint24 public constant poolFee = 3000;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    struct Deposit {
        address owner;
        uint128 liquidity;
        address token0;
        address token1;
    }

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public deposits;
    mapping(address => uint256[]) public ownLPs;

    error InvalidMint();
    error InvalidPrice();
    error TotalSupplyReached();
    error NotLive();

    constructor(
        string memory name_,
        string memory symbol_,
        uint96 initialTokenSupply,
        address initialSupplyOwner,
        address payable _weth,
        // uniswap v3
        address _nonfungiblePositionManager
    ) {
        _initializeOwner(msg.sender);

        _name = name_;
        _symbol = symbol_;

        address mirror = address(new DN404Mirror(msg.sender)); // erc721
        _initializeDN404(initialTokenSupply, initialSupplyOwner, mirror);

        weth = WETH(_weth);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
    }

    function _unit() internal view virtual override returns (uint256) {
        return 10 ** 18;
    }

    modifier onlyLive() {
        if (!live) {
            revert NotLive();
        }
        _;
    }

    modifier checkPrice(uint256 price, uint256 nftAmount) {
        if (price * nftAmount != msg.value) {
            revert InvalidPrice();
        }
        _;
    }

    modifier checkAndUpdateTotalMinted(uint256 nftAmount) {
        uint256 newTotalMinted = uint256(totalMinted) + nftAmount;
        if (newTotalMinted > MAX_SUPPLY) {
            revert TotalSupplyReached();
        }
        totalMinted = uint32(newTotalMinted);
        _;
    }

    modifier checkAndUpdateBuyerMintCount(uint256 nftAmount) {
        uint256 currentMintCount = _getAux(msg.sender);
        uint256 newMintCount = currentMintCount + nftAmount;
        if (newMintCount > MAX_PER_WALLET) {
            revert InvalidMint();
        }
        _setAux(msg.sender, uint88(newMintCount));
        _;
    }

    function publicMint(uint256 nftAmount)
        public
        payable
        onlyLive
        checkPrice(pbMintPrice, nftAmount)
        checkAndUpdateBuyerMintCount(nftAmount)
        checkAndUpdateTotalMinted(nftAmount)
    {
        _mint(msg.sender, nftAmount * _unit());
        mintNewPosition();
    }

    // bytes32 signature
    function whitelistMint(uint256 nftAmount)
        public
        payable
        onlyLive
        checkPrice(wlMintPrice, nftAmount)
        checkAndUpdateBuyerMintCount(nftAmount)
        checkAndUpdateTotalMinted(nftAmount)
    {
        // check signature
        _mint(msg.sender, nftAmount * _unit());
    }

    ////////////////
    function setBaseURI(string calldata baseURI_) public onlyOwner {
        _baseURI = baseURI_;
    }

    function toggleLive() public onlyOwner {
        live = !live;
    }

    function withdraw() public onlyOwner {
        SafeTransferLib.safeTransferAllETH(msg.sender);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function _tokenURI(uint256 tokenId) internal view override returns (string memory result) {
        if (bytes(_baseURI).length != 0) {
            result = string(abi.encodePacked(_baseURI, LibString.toString(tokenId)));
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function _createDeposit(address owner, uint256 tokenId) internal {
        (,, address token0, address token1,,,, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(tokenId);

        // set the owner and data for position
        // operator is msg.sender
        deposits[tokenId] =
            Deposit({owner: owner, liquidity: liquidity, token0: token0, token1: token1});

        ownLPs[owner].push(tokenId);
    }

    /// @notice Calls the mint function defined in periphery, mints the same amount of each token.
    /// @return tokenId The id of the newly minted ERC721
    /// @return liquidity The amount of liquidity for the position
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function mintNewPosition()
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // For this example, we will provide equal amounts of liquidity in both assets.
        // Providing liquidity in both assets means liquidity will be earning fees and is considered in-range.
        weth.deposit{value: address(this).balance}();
        uint256 wethBalance = weth.balanceOf(address(this));

        uint256 amount0ToMint = wethBalance;
        uint256 amount1ToMint = 0;

        // Approve the position manager
        TransferHelper.safeApprove(
            address(weth), address(nonfungiblePositionManager), amount0ToMint
        );
        // TransferHelper.safeApprove(address(this), address(nonfungiblePositionManager), amount1ToMint);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams({
            token0: address(weth),
            token1: address(this),
            fee: poolFee,
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            amount0Desired: amount0ToMint,
            amount1Desired: amount1ToMint,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Note that the pool defined by DAI/USDC and fee tier 0.3% must already be created and initialized in order to mint
        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

        // Create a deposit
        _createDeposit(msg.sender, tokenId);
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

        // address owner = deposits[tokenId].owner;
        // TransferHelper.safeTransfer(deposits[tokenId].token0, owner, amount0);
        // TransferHelper.safeTransfer(deposits[tokenId].token1, owner, amount1);
    }

    function claimLPFee(address owner) external {
        require(ownLPs[owner].length != 0, "own 0 LP");
        for (uint256 i = 0; i < ownLPs[owner].length; i++) {
            uint256 id = ownLPs[owner][i];
            collectLPFee(id);
        }
    }

    function queryLPFee(address owner) external view returns (uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < ownLPs[owner].length; i++) {
            uint256 id = ownLPs[owner][i];
            (,,,,,,,, uint256 tem0, uint256 tem1,,) = nonfungiblePositionManager.positions(id);
            amount0 += tem0;
            amount1 += tem1;
        }
    }
}
