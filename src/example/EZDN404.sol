// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../DN404.sol";
import "../DN404Mirror.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/base/LiquidityManagement.sol";

import {console2} from "forge-std2/console2.sol";

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

// Add EZSwap interface at the beginning of the contract
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

    WETH public weth;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 60;

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

    // Internal trading related state
    bool public isPreTrading = true; // Whether in pre-trading phase
    uint256 public constant PRE_TRADING_MAX_ETH = 0.002 ether; // Max ETH limit for pre-trading
    uint256 public constant PLATFORM_FEE = 0.00003 ether; // Platform fee
    uint256 public constant TRADING_FEE = 100; // 1% = 100/10000

    uint256 public virtualETHReserve; // Virtual pool ETH reserve
    uint256 public virtualTokenReserve; // Virtual pool token reserve
    
    address public platformWallet; // Platform wallet
    address public feeCollector; // Fee collector address

    // User trading restrictions
    mapping(address => bool) public hasTraded; // Records if a user has participated in pre-trading

    error PreTradingEnded();
    error InsufficientLiquidity();
    error NotParticipatedInPreTrading();
    error TradingRestricted();

    bool private locked;
    modifier nonReentrant() {
        require(!locked, "ReentrancyGuard: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    // Need to add emergency pause functionality
    bool public paused;
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    bool public isInitialized;

    // Add in the state variable area
    ILSSVMPairFactory public immutable ezswapFactory;
    ICurve public immutable bondingCurve;
    LSSVMPairETH public ezswapPair;

    constructor(
        string memory name_,
        string memory symbol_,
        uint96 initialTokenSupply,
        address initialSupplyOwner,
        address payable _weth,
        // uniswap v3
        address _nonfungiblePositionManager,
        address _platformWallet,
        address _feeCollector,
        address _ezswapFactory,
        address _bondingCurve
    ) {
        _initializeOwner(msg.sender);

        _name = name_;
        _symbol = symbol_;

        address mirror = address(new DN404Mirror(msg.sender)); // erc721
        _initializeDN404(initialTokenSupply, initialSupplyOwner, mirror);

        weth = WETH(_weth);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);

        platformWallet = _platformWallet;
        feeCollector = _feeCollector;
        
        // Initialize virtual pool
        virtualETHReserve = 0.001 ether;
        virtualTokenReserve = 100 * _unit(); // Assume initial price is 0.01 ETH

        ezswapFactory = ILSSVMPairFactory(_ezswapFactory);
        bondingCurve = ICurve(_bondingCurve);


    }

    function _unit() internal view virtual override returns (uint256) {
        return 10 * 10 ** 18;
    }

    function setBaseURI(string calldata baseURI_) public onlyOwner {
        _baseURI = baseURI_;
    }

    // function withdraw() public onlyOwner {
    //     SafeTransferLib.safeTransferAllETH(msg.sender);
    // }

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
        return IERC721Receiver.onERC721Received.selector;
    }

    // function _createDeposit(address owner, uint256 tokenId) internal {
    //     (,, address token0, address token1,,,, uint128 liquidity,,,,) =
    //         nonfungiblePositionManager.positions(tokenId);
    //     // set the owner and data for position
    //     // operator is msg.sender
    //     deposits[tokenId] =
    //         Deposit({owner: owner, liquidity: liquidity, token0: token0, token1: token1});

    //     ownLPs[owner].push(tokenId);
    // }


    // Internal trading - Buy tokens
    function preTradingBuy() external payable nonReentrant whenNotPaused {
        if (!isPreTrading) revert PreTradingEnded();
        if (virtualETHReserve >= PRE_TRADING_MAX_ETH + 0.1 ether) revert PreTradingEnded();
        
        // Check if this transaction will exceed the threshold
        if (virtualETHReserve + msg.value > PRE_TRADING_MAX_ETH + 0.1 ether) revert PreTradingEnded();

        uint256 ethAmount = msg.value;
        uint256 tokenAmount = getTokenAmount(ethAmount);
        
        // Collect fee
        uint256 fee = (ethAmount * TRADING_FEE) / 10000;
        uint256 ethAfterFee = ethAmount - fee;
        
        // Update virtual pool
        virtualETHReserve += ethAfterFee;
        virtualTokenReserve -= tokenAmount;
        
        // Transfer fee
        SafeTransferLib.safeTransferETH(feeCollector, fee);
        
        // Mint tokens
        _mint(msg.sender, tokenAmount);
        _setSkipNFT(address(this), false); // Set to false to receive NFTs
        _mint(address(this), tokenAmount);
        _setSkipNFT(address(this), true); // Set to true to skip NFTs
        hasTraded[msg.sender] = true;
    
    }

    // Internal trading - Sell tokens
    // function preTradingSell(uint256 tokenAmount) external nonReentrant whenNotPaused {
    //     if (!isPreTrading) revert PreTradingEnded();
    //     if (!hasTraded[msg.sender]) revert NotParticipatedInPreTrading();
    //     if (virtualETHReserve >= PRE_TRADING_MAX_ETH) revert PreTradingEnded();

    //     uint256 ethAmount = getETHAmount(tokenAmount);
        
    //     // Collect fee
    //     uint256 fee = (ethAmount * TRADING_FEE) / 10000;
    //     uint256 ethAfterFee = ethAmount - fee;
        
    //     // Update virtual pool
    //     virtualETHReserve -= ethAfterFee;
    //     virtualTokenReserve += tokenAmount;
        
    //     // Burn tokens
    //     _burn(msg.sender, tokenAmount);
        
    //     // Transfer ETH
    //     SafeTransferLib.safeTransferETH(msg.sender, ethAfterFee);
    //     SafeTransferLib.safeTransferETH(feeCollector, fee);
    // }

    // Calculate the amount of tokens to buy
    function getTokenAmount(uint256 ethAmount) public view returns (uint256) {
        if (virtualTokenReserve == 0 || virtualETHReserve == 0) revert InsufficientLiquidity();
        
        uint256 ethAfterFee = ethAmount - ((ethAmount * TRADING_FEE) / 10000);
        
        // Use safe math library
        uint256 k = virtualETHReserve * virtualTokenReserve;
        if (k == 0) revert InsufficientLiquidity();
        
        uint256 newETHReserve = virtualETHReserve + ethAfterFee;
        if (newETHReserve <= virtualETHReserve) revert("Overflow");
        
        uint256 newTokenReserve = k / newETHReserve;
        uint256 tokenAmount = virtualTokenReserve - newTokenReserve;
        
        return tokenAmount;
    }

    // Calculate the amount of ETH received from selling tokens
    function getETHAmount(uint256 tokenAmount) public view returns (uint256) {
        if (virtualETHReserve == 0) revert InsufficientLiquidity();
        
        uint256 k = virtualETHReserve * virtualTokenReserve;
        uint256 newTokenReserve = virtualTokenReserve + tokenAmount;
        uint256 newETHReserve = k / newTokenReserve;
        uint256 ethAmount = virtualETHReserve - newETHReserve;
        
        if (ethAmount > virtualETHReserve) revert InsufficientLiquidity();
        return ethAmount;
    }

    // Public function to initialize external trading
    function initializeExternalTrading_uniswap() external nonReentrant whenNotPaused {
        require(!isInitialized, "Already initialized");
        require(virtualETHReserve >= PRE_TRADING_MAX_ETH, "Threshold not reached");
        
        // isInitialized = true;
        isPreTrading = false;
        // _initializeExternalTrading_uniswap();
        _addUniswapLiquidity(0.001 ether);
    }

    function initializeExternalTrading_ezswap() external nonReentrant whenNotPaused {
        require(!isInitialized, "Already initialized");
        require(virtualETHReserve >= PRE_TRADING_MAX_ETH, "Threshold not reached");
        
        // isInitialized = true;
        isPreTrading = false;
        _setSkipNFT(address(this), false); 
        _addEZSwapLiquidity(0.001 ether);
        _setSkipNFT(address(this), true); 
    }

     // Initialize external trading
    // function _initializeExternalTrading_ezswap() internal {
    //     isPreTrading = false;
        
    //     // Transfer platform fee
    //     SafeTransferLib.safeTransferETH(platformWallet, PLATFORM_FEE);
        
    //     // Calculate liquidity allocation for Uniswap and EZSwap
    //     // uint256 uniswapETH = (virtualETHReserve - PLATFORM_FEE) * 2 / 3;
    //     // uint256 uniswapETH = 0.001 ether;
    //     // uint256 ezswapETH = (virtualETHReserve - PLATFORM_FEE) - uniswapETH;
    //     uint256 ezswapETH = 0.001 ether;
        
    //     // Add Uniswap liquidity
    //     // _addUniswapLiquidity(uniswapETH);
        
    //     // Reserve EZSwap liquidity addition interface
    //     _addEZSwapLiquidity(ezswapETH);
    // }

    // Add Uniswap liquidity
    function _addUniswapLiquidity(uint256 ethAmount) internal {
        // Convert ETH to WETH
        weth.deposit{value: ethAmount}();
        
        // Calculate token amount (assume initial price is 1:100)
        uint256 tokenAmount = ethAmount * 100;
        _mint(address(this), tokenAmount);

        // Determine the correct order of token0 and token1
        address token0 = address(weth);
        address token1 = address(this);
        uint256 amount0Desired = ethAmount;
        uint256 amount1Desired = tokenAmount;
        
        // Swap order if needed
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (amount0Desired, amount1Desired) = (amount1Desired, amount0Desired);
        }

        // Check if the pool already exists
        address factory = nonfungiblePositionManager.factory();
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, poolFee);
        
        // If the pool does not exist, create and initialize it
        if (pool == address(0)) {
            pool = IUniswapV3Factory(factory).createPool(token0, token1, poolFee);
            
            // Calculate initial price square root
            // If WETH is token0, price is 1:100
            // If WETH is token1, price is 100:1
            uint160 sqrtPriceX96 = token0 == address(weth) 
                ? uint160(79228162514264337593543950336) // 1:100 price
                : uint160(792281625142643375935439503);  // 100:1 price
                
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        // Approve
        TransferHelper.safeApprove(token0, address(nonfungiblePositionManager), amount0Desired);
        TransferHelper.safeApprove(token1, address(nonfungiblePositionManager), amount1Desired);

        // Create liquidity parameters
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: poolFee,
            tickLower: -27660,
            tickUpper: 27660,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,  // Can be set to 0 when adding liquidity for the first time
            amount1Min: 0,  // Can be set to 0 when adding liquidity for the first time
            recipient: address(this),
            deadline: block.timestamp
        });

         nonfungiblePositionManager.mint(params);
    }

    // Reserve EZSwap liquidity interface
    function _addEZSwapLiquidity(uint256 ethAmount) internal {
        // Calculate token amount
        uint256 tokenAmount = 10 ether;
        _mint(address(this), tokenAmount);
        
        // Get the number of NFTs currently owned by the contract
        uint256 nftBalance = DN404Mirror(payable(mirrorERC721())).balanceOf(address(this));
        require(nftBalance > 0, "No NFTs available");

        // Prepare an array of actual NFT IDs owned
        uint256[] memory initialNFTIDs = new uint256[](nftBalance);
        uint256 counter = 0;
        
        // Iterate and collect NFT IDs owned by the contract
        for(uint256 i = 1; counter < nftBalance; i++) {
            if (DN404Mirror(payable(mirrorERC721())).ownerOf(i) == address(this)) {
                initialNFTIDs[counter] = i;
                counter++;
            }
        }
        
        // Create EZSwap pool parameters
        ILSSVMPairFactory.CreatePairETHParams memory params = ILSSVMPairFactory.CreatePairETHParams({
            nft: IERC721(mirrorERC721()),
            bondingCurve: bondingCurve,
            assetRecipient: payable(address(this)),
            poolType: LSSVMPair.PoolType.NFT,
            delta: 10000000000000000,
            fee: 0,
            spotPrice: 1000000000, 
            initialNFTIDs: initialNFTIDs
        });

        // Approve NFT to EZSwap factory
        DN404Mirror(payable(mirrorERC721())).setApprovalForAll(address(ezswapFactory), true);
        
        // Create pair and add liquidity
        ezswapPair = ezswapFactory.createPairETH{value: ethAmount}(params);
    }

    // Override transfer functions to implement trading restrictions
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // if (isPreTrading && from != address(0) && to != address(0)) {
        //     require(hasTraded[from], "Trading restricted during pre-trading phase");
        // }
        super._transfer(from, to, amount);
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    // // Function to update critical addresses
    // function updateFeeCollector(address _newFeeCollector) external onlyOwner {
    //     require(_newFeeCollector != address(0), "Zero address");
    //     feeCollector = _newFeeCollector;
    // }

   
}