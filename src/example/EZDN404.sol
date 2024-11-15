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

// 在合约开头添加 EZSwap 接口
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

    uint32 public totalMinted; // DN404 only supports up to `2**32 - 2` tokens.
    bool public live;

    uint256 public pbMintPrice = 0.001 ether;
    uint256 public wlMintPrice = 0.0001 ether;

    uint32 public constant MAX_PER_WALLET = 5;
    uint32 public constant MAX_SUPPLY = 5000;

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

    error InvalidMint();
    error InvalidPrice();
    error TotalSupplyReached();
    error NotLive();

    // 内盘交易相关状态
    bool public isPreTrading = true; // 是否在内盘交易阶段
    uint256 public constant PRE_TRADING_MAX_ETH = 20 ether; // 内盘最大ETH额度
    uint256 public constant PLATFORM_FEE = 0.3 ether; // 平台费用
    uint256 public constant TRADING_FEE = 100; // 1% = 100/10000
    uint256 public constant INITIAL_PRICE = 0.01 ether; // 初始价格
    
    uint256 public virtualETHReserve; // 虚拟池 ETH 储备
    uint256 public virtualTokenReserve; // 虚拟池代币储备
    
    address public platformWallet; // 平台钱包
    address public feeCollector; // 手续费收集地址

    // 用户交易限制
    mapping(address => bool) public hasTraded; // 记录用户是否参与过内盘交易

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

    // 需要添加紧急暂停功能
    bool public paused;
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    bool public isInitialized;

    // 在状态变量区域添加
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

        // nonfungiblePositionManager.createAndInitializePoolIfNecessary(
        //     address(this), address(weth), poolFee, 79228162514264337593543950336
        // );

        nonfungiblePositionManager.createAndInitializePoolIfNecessary(
            address(weth), address(this),  poolFee, 79228162514264337593543950336
        );

        platformWallet = _platformWallet;
        feeCollector = _feeCollector;
        
        // 初始化虚拟池
        virtualETHReserve = 1 ether;
        virtualTokenReserve = 100 * _unit(); // 假设初始价为0.01 ETH

        ezswapFactory = ILSSVMPairFactory(_ezswapFactory);
        bondingCurve = ICurve(_bondingCurve);
    }

    function _unit() internal view virtual override returns (uint256) {
        return 10000 * 10 ** 18;
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
        weth.deposit{value: msg.value}();
        uint256 wethBalance = weth.balanceOf(address(this));

        uint256 amount0ToMint = wethBalance;
        _mint(address(this), wethBalance);
        uint256 amount1ToMint = wethBalance;

        // Approve the position manager
        TransferHelper.safeApprove(
            address(this), address(nonfungiblePositionManager), amount0ToMint
        );
        TransferHelper.safeApprove(
            address(weth), address(nonfungiblePositionManager), amount1ToMint
        );

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams({
            token0: address(weth),
            token1: address(this),
            fee: poolFee,
            tickLower: (MIN_TICK / TICK_SPACING) * TICK_SPACING,
            tickUpper: (MAX_TICK / TICK_SPACING) * TICK_SPACING,
            amount0Desired: amount0ToMint,
            amount1Desired: amount1ToMint,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Note that the pool defined by DAI/USDC and fee tier 0.3% must already be created and initialized in order to mint
        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

        console2.log("=====");
        console2.log(weth.balanceOf(address(this)));
        console2.log(balanceOf(address(this)));
        console2.log("=====");

        // // Create a deposit
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

    function getOwnLPs(address owner, uint256 index) external view returns (uint256 id) {
        return ownLPs[owner][index];
    }

    // 内盘交易 - 购买代币
    function preTradingBuy() external payable nonReentrant whenNotPaused {
        if (!isPreTrading) revert PreTradingEnded();
        if (virtualETHReserve >= PRE_TRADING_MAX_ETH) revert PreTradingEnded();
        
        // 检查添加这笔交易后是否会超过阈值
        if (virtualETHReserve + msg.value > PRE_TRADING_MAX_ETH) revert PreTradingEnded();

        uint256 ethAmount = msg.value;
        uint256 tokenAmount = getTokenAmount(ethAmount);
        
        // 收取手续费
        uint256 fee = (ethAmount * TRADING_FEE) / 10000;
        uint256 ethAfterFee = ethAmount - fee;
        
        // 更新虚拟池
        virtualETHReserve += ethAfterFee;
        virtualTokenReserve -= tokenAmount;
        
        // 转移手续费
        SafeTransferLib.safeTransferETH(feeCollector, fee);
        
        // 铸造代币
        _mint(msg.sender, tokenAmount);
        hasTraded[msg.sender] = true;

    
    }

    // 内盘交易 - 卖出代币
    function preTradingSell(uint256 tokenAmount) external nonReentrant whenNotPaused {
        if (!isPreTrading) revert PreTradingEnded();
        if (!hasTraded[msg.sender]) revert NotParticipatedInPreTrading();
        if (virtualETHReserve >= PRE_TRADING_MAX_ETH) revert PreTradingEnded();

        uint256 ethAmount = getETHAmount(tokenAmount);
        
        // 收取手续费
        uint256 fee = (ethAmount * TRADING_FEE) / 10000;
        uint256 ethAfterFee = ethAmount - fee;
        
        // 更新虚拟池
        virtualETHReserve -= ethAfterFee;
        virtualTokenReserve += tokenAmount;
        
        // 销毁代币
        _burn(msg.sender, tokenAmount);
        
        // 转移ETH
        SafeTransferLib.safeTransferETH(msg.sender, ethAfterFee);
        SafeTransferLib.safeTransferETH(feeCollector, fee);
    }

    // 计算购买代币数量
    function getTokenAmount(uint256 ethAmount) public view returns (uint256) {
        if (virtualTokenReserve == 0 || virtualETHReserve == 0) revert InsufficientLiquidity();
        
        uint256 ethAfterFee = ethAmount - ((ethAmount * TRADING_FEE) / 10000);
        
        // 使用安全数学库
        uint256 k = virtualETHReserve * virtualTokenReserve;
        if (k == 0) revert InsufficientLiquidity();
        
        uint256 newETHReserve = virtualETHReserve + ethAfterFee;
        if (newETHReserve <= virtualETHReserve) revert("Overflow");
        
        uint256 newTokenReserve = k / newETHReserve;
        uint256 tokenAmount = virtualTokenReserve - newTokenReserve;
        
        return tokenAmount;
    }

    // 计算卖出获得的ETH数量
    function getETHAmount(uint256 tokenAmount) public view returns (uint256) {
        if (virtualETHReserve == 0) revert InsufficientLiquidity();
        
        uint256 k = virtualETHReserve * virtualTokenReserve;
        uint256 newTokenReserve = virtualTokenReserve + tokenAmount;
        uint256 newETHReserve = k / newTokenReserve;
        uint256 ethAmount = virtualETHReserve - newETHReserve;
        
        if (ethAmount > virtualETHReserve) revert InsufficientLiquidity();
        return ethAmount;
    }

    // 公开的初始化外盘交易函数
    function initializeExternalTrading() external nonReentrant whenNotPaused {
        require(!isInitialized, "Already initialized");
        require(virtualETHReserve >= PRE_TRADING_MAX_ETH, "Threshold not reached");
        
        isInitialized = true;
        isPreTrading = false;
        _initializeExternalTrading();
    }

    // 初始化外盘交易
    function _initializeExternalTrading() internal {
        isPreTrading = false;
        
        // 转移平台费用
        SafeTransferLib.safeTransferETH(platformWallet, PLATFORM_FEE);
        
        // 计算分配给 Uniswap 和 EZSwap 的流动性
        uint256 uniswapETH = (virtualETHReserve - PLATFORM_FEE) * 2 / 3;
        uint256 ezswapETH = (virtualETHReserve - PLATFORM_FEE) - uniswapETH;
        
        // 添加 Uniswap 流动性
        _addUniswapLiquidity(uniswapETH);
        
        // 预留 EZSwap 流动性添加接口
        _addEZSwapLiquidity(ezswapETH);
    }

    // 添加 Uniswap 流动性
    function _addUniswapLiquidity(uint256 ethAmount) internal {
        // 将ETH转换为WETH
        weth.deposit{value: ethAmount}();
        
        // 计算代币数量 (1:1 比例)
        uint256 tokenAmount = ethAmount;
        _mint(address(this), tokenAmount);

        // 授权 position manager 使用代币
        TransferHelper.safeApprove(
            address(this), 
            address(nonfungiblePositionManager), 
            tokenAmount
        );
        TransferHelper.safeApprove(
            address(weth), 
            address(nonfungiblePositionManager), 
            ethAmount
        );

        // 创建流动性参数
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams({
                token0: address(weth),
                token1: address(this),
                fee: poolFee,
                tickLower: (MIN_TICK / TICK_SPACING) * TICK_SPACING,
                tickUpper: (MAX_TICK / TICK_SPACING) * TICK_SPACING,
                amount0Desired: ethAmount,
                amount1Desired: tokenAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });

        // 添加流动性
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = 
            nonfungiblePositionManager.mint(params);

        // 记录LP信息
        _createDeposit(owner(), tokenId);

        // 处理剩余代币
        if (amount0 < ethAmount) {
            weth.withdraw(ethAmount - amount0);
            SafeTransferLib.safeTransferETH(owner(), ethAmount - amount0);
        }
        if (amount1 < tokenAmount) {
            _transfer(address(this), owner(), tokenAmount - amount1);
        }
    }

    // 预留 EZSwap 流动性接口
    function _addEZSwapLiquidity(uint256 ethAmount) internal {
        // 计算代币数量
        uint256 tokenAmount = ethAmount;
        _mint(address(this), tokenAmount);
        
        // 准备 NFT ID 数组
        uint256[] memory initialNFTIDs = new uint256[](tokenAmount / _unit());
        for(uint256 i = 0; i < initialNFTIDs.length; i++) {
            initialNFTIDs[i] = i + 1;
        }
        
        // 创建 EZSwap 池子参数
        ILSSVMPairFactory.CreatePairETHParams memory params = ILSSVMPairFactory.CreatePairETHParams({
            nft: IERC721(mirrorERC721()),
            bondingCurve: bondingCurve,
            assetRecipient: payable(address(this)),
            poolType: LSSVMPair.PoolType.TRADE,
            delta: 0, // 根据需要设置
            fee: 0,   // 根据需要设置
            spotPrice: uint128(ethAmount / initialNFTIDs.length), // 平均价格
            initialNFTIDs: initialNFTIDs
        });

        // 授权 NFT 给 EZSwap 工厂
        DN404Mirror(payable(mirrorERC721())).setApprovalForAll(address(ezswapFactory), true);
        
        // 创建交易对并添加流动性
        ezswapPair = ezswapFactory.createPairETH{value: ethAmount}(params);
    }

    // Override transfer functions to implement trading restrictions
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        if (isPreTrading && from != address(0) && to != address(0)) {
            require(hasTraded[from], "Trading restricted during pre-trading phase");
        }
        super._transfer(from, to, amount);
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    // 更新关键地址的功能
    function updateFeeCollector(address _newFeeCollector) external onlyOwner {
        require(_newFeeCollector != address(0), "Zero address");
        feeCollector = _newFeeCollector;
    }
}
