// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./pyth/IPyth.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IRandomizer {
    function getNextIdAndPoints() external returns (uint256 id, uint256 points);
}

interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function WETH() external pure returns (address);
}

interface INFTTracker {
    function updateBalance(address from, address to, uint256 tokenId, uint256 points) external;
}

/**
 * @title NFT Contract (V2 Compatible)
 * @notice ERC721 NFT with presale and post-presale minting
 * @dev Presale: $100 in ETH/SOL/USDC. Post-presale: 0.01% of market cap in TOKEN
 */
contract NFTContract is ERC721Royalty, Ownable, ReentrancyGuard {
    using Strings for uint256;

    // ============ CONSTANTS ============
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MAX_PER_MINT = 5;
    uint256 public constant PRESALE_MAX = 250;
    uint256 public constant PRESALE_PRICE_USD = 100e18; // $100
    uint256 public constant ETH_SURCHARGE_PCT = 5;
    uint256 public constant PRICE_LOCK_DURATION = 60; // 1 minute
    uint96 public constant ROYALTY_BPS = 162; // 1.62% ≈ 1.618% (ERC2981 uses 10000 divisor)

    // ============ ADJUSTABLE ============
    uint256 public maxWallet = 5;

    // ============ PRESALE STATE ============
    bool public presaleActive = true;
    bool public postPresaleActive = false;
    
    // ============ PYTH ORACLE (Primary) ============
    IPyth public pyth;
    bytes32 public constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 public constant PYTH_SOL_USD = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    uint256 public pythMaxAge = 60; // Price must be < 60 seconds old
    
    // ============ UNISWAP POOLS (Fallback for USD prices) ============
    address public wethUsdcPair;  // WETH/USDC pair for ETH/USD price fallback
    address public solUsdcPair;   // SOL/USDC pair for SOL/USD price fallback
    
    // ============ UNISWAP ROUTER (for presale swaps) ============
    IUniswapV2Router public uniswapRouter; // V2 Router for ETH/SOL → USDC swaps
    // USDC on Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (6 decimals)

    // ============ ADDRESSES ============
    address public erc20Token; // Main TOKEN
    address public immutable weth;
    address public sol; // Wrapped SOL on Base
    address public usdc; // USDC on Base
    address public nftTracker;
    address public randomizer;
    address public nftMintFund; // Where presale funds go
    
    // ============ V2 PAIRS FOR TOKEN ============
    address public uniswapV2PairTokenWeth; // TOKEN/WETH pair
    address public uniswapV2PairTokenSol;  // TOKEN/SOL pair (optional)
    
    // ============ CIRCULATING SUPPLY EXCLUSIONS ============
    address public tokenLocker; // Team vesting contract
    address public constant DEAD_WALLET = 0x000000000000000000000000000000000000dEaD;

    // ============ STATE ============
    uint256 public mintedCount;
    string public baseURI;
    bool public paused = false;

    mapping(uint256 => uint256) public pointsMintedCount;
    mapping(uint256 => uint256) public tokenIdToPoints;
    mapping(uint256 => bool) private _minted;
    mapping(address => uint256) public walletMintedCount;

    // ============ PRICE LOCK ============
    mapping(address => uint256) public mintPriceLockExpiry;
    mapping(address => uint256) public mintPriceLocked;

    // ============ INTERFACES ============
    IRandomizer private _randomizerContract;
    IERC20 private _erc20Contract;

    // ============ EVENTS ============
    event Minted(address indexed to, uint256 indexed tokenId, uint256 points);
    event OwnerMinted(address indexed to, uint256 quantity);
    event MintingPaused();
    event MintingResumed();
    event EthWithdrawn(address indexed to, uint256 amount);
    event Erc20Withdrawn(address indexed to, uint256 amount);
    event RandomizerUpdated(address indexed oldRandomizer, address indexed newRandomizer);
    event NftTrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event MaxWalletUpdated(uint256 newMax);
    event PresaleEnded();
    event PostPresaleStarted();
    event PriceInUSDUpdated(uint256 newETHPrice);
    event PriceLocked(address indexed user, uint256 price, uint256 expiry);

    constructor(
        string memory _initialBaseURI,
        address _erc20Token,
        address _randomizer,
        address _nftTracker,
        address _weth,
        address _sol,
        address _usdc,
        address _nftMintFund,
        address _pyth // PYTH oracle on Base: 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
    ) ERC721("66Mtest", "66MTNFT") Ownable(msg.sender) {
        require(_randomizer != address(0), "Invalid randomizer");
        require(_weth != address(0), "Invalid WETH");
        require(_nftMintFund != address(0), "Invalid mint fund");

        baseURI = _initialBaseURI;
        erc20Token = _erc20Token;
        weth = _weth;
        sol = _sol;
        usdc = _usdc;
        nftTracker = _nftTracker;
        nftMintFund = _nftMintFund;
        
        if (_erc20Token != address(0)) {
            _erc20Contract = IERC20(_erc20Token);
        }
        _setRandomizer(_randomizer);
        
        // Set 1.618% royalty to NFT_MINT_FUND
        _setDefaultRoyalty(_nftMintFund, ROYALTY_BPS);
        
        // Set PYTH oracle
        if (_pyth != address(0)) {
            pyth = IPyth(_pyth);
        }
    }

    // ============ OWNER FUNCTIONS ============

    function setErc20Token(address _newErc20) external onlyOwner {
        require(_newErc20 != address(0), "Invalid ERC20");
        erc20Token = _newErc20;
        _erc20Contract = IERC20(_newErc20);
    }

    function setUniswapV2PairTokenWeth(address _pair) external onlyOwner {
        require(_pair != address(0), "Invalid pair");
        uniswapV2PairTokenWeth = _pair;
    }

    function setUniswapV2PairTokenSol(address _pair) external onlyOwner {
        uniswapV2PairTokenSol = _pair;
    }

    function setTokenLocker(address _locker) external onlyOwner {
        tokenLocker = _locker;
    }

    function setSolToken(address _sol) external onlyOwner {
        sol = _sol;
    }

    function setUsdcToken(address _usdc) external onlyOwner {
        usdc = _usdc;
    }

    function setNftMintFund(address _fund) external onlyOwner {
        require(_fund != address(0), "Invalid fund");
        nftMintFund = _fund;
    }

    function ownerMint(address to, uint256 quantity) external onlyOwner nonReentrant {
        require(quantity > 0, "Quantity > 0");
        require(mintedCount + quantity <= MAX_SUPPLY, "Exceeds max supply");
        require(to != address(0), "Invalid address");

        _mintBatch(to, quantity);
        emit OwnerMinted(to, quantity);
    }

    function setMaxWallet(uint256 _newMax) external onlyOwner {
        maxWallet = _newMax;
        emit MaxWalletUpdated(_newMax);
    }

    function setRandomizer(address _newRandomizer) external onlyOwner {
        require(_newRandomizer != address(0), "Invalid randomizer");
        address old = randomizer;
        _setRandomizer(_newRandomizer);
        emit RandomizerUpdated(old, _newRandomizer);
    }

    function _setRandomizer(address _randomizer) private {
        randomizer = _randomizer;
        _randomizerContract = IRandomizer(_randomizer);
    }

    function setNftTracker(address _newTracker) external onlyOwner {
        address old = nftTracker;
        nftTracker = _newTracker;
        emit NftTrackerUpdated(old, _newTracker);
    }

    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    function pause() external onlyOwner {
        paused = true;
        emit MintingPaused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit MintingResumed();
    }

    function withdrawEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH");
        payable(owner()).transfer(balance);
        emit EthWithdrawn(owner(), balance);
    }

    function withdrawErc20(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens");
        require(IERC20(token).transfer(owner(), balance), "Transfer failed");
        emit Erc20Withdrawn(owner(), balance);
    }

    // ============ PYTH PRICE FEEDS ============

    function setPyth(address _pyth) external onlyOwner {
        require(_pyth != address(0), "Invalid PYTH");
        pyth = IPyth(_pyth);
    }

    function setPythMaxAge(uint256 _maxAge) external onlyOwner {
        require(_maxAge > 0, "Invalid max age");
        pythMaxAge = _maxAge;
    }

    function setWethUsdcPair(address _pair) external onlyOwner {
        wethUsdcPair = _pair;
    }

    function setSolUsdcPair(address _pair) external onlyOwner {
        solUsdcPair = _pair;
    }

    function setUniswapRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        uniswapRouter = IUniswapV2Router(_router);
    }

    /**
     * @notice Get current ETH price in USD (18 decimals)
     * @dev Primary: PYTH oracle. Fallback: WETH/USDC Uniswap pool
     */
    function getCurrentEthPrice() public view returns (uint256) {
        // Try PYTH first
        if (address(pyth) != address(0)) {
            try pyth.getPriceNoOlderThan(PYTH_ETH_USD, pythMaxAge) returns (IPyth.Price memory price) {
                if (price.price > 0) {
                    return _convertPythPrice(price);
                }
            } catch {}
        }
        
        // Fallback: Use WETH/USDC pool
        if (wethUsdcPair != address(0)) {
            return _getEthPriceFromPool();
        }
        
        revert("No price source available");
    }

    /**
     * @notice Get current SOL price in USD (18 decimals)
     * @dev Primary: PYTH oracle. Fallback: SOL/USDC Uniswap pool
     */
    function getCurrentSolPrice() public view returns (uint256) {
        // Try PYTH first
        if (address(pyth) != address(0)) {
            try pyth.getPriceNoOlderThan(PYTH_SOL_USD, pythMaxAge) returns (IPyth.Price memory price) {
                if (price.price > 0) {
                    return _convertPythPrice(price);
                }
            } catch {}
        }
        
        // Fallback: Use SOL/USDC pool
        if (solUsdcPair != address(0)) {
            return _getSolPriceFromPool();
        }
        
        revert("No price source available");
    }

    function _convertPythPrice(IPyth.Price memory price) internal pure returns (uint256) {
        int32 expo = price.expo;
        uint256 priceValue = uint256(uint64(price.price));
        
        if (expo < 0) {
            uint256 decimals = uint256(uint32(-expo));
            if (decimals < 18) {
                return priceValue * 10**(18 - decimals);
            } else if (decimals > 18) {
                return priceValue / 10**(decimals - 18);
            }
            return priceValue;
        }
        return priceValue * 10**(18 + uint256(uint32(expo)));
    }

    /**
     * @notice Get ETH price from WETH/USDC pool
     * @dev USDC has 6 decimals, result in 18 decimals
     */
    function _getEthPriceFromPool() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(wethUsdcPair).getReserves();
        address token0 = IUniswapV2Pair(wethUsdcPair).token0();
        
        uint256 wethReserve;
        uint256 usdcReserve;
        
        // USDC on Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        if (token0 == weth) {
            wethReserve = uint256(reserve0);
            usdcReserve = uint256(reserve1);
        } else {
            wethReserve = uint256(reserve1);
            usdcReserve = uint256(reserve0);
        }
        
        require(wethReserve > 0, "No WETH liquidity");
        
        // USDC is 6 decimals, WETH is 18 decimals
        // Price = (usdcReserve / wethReserve) * 10^12 to get 18 decimal result
        return (usdcReserve * 1e30) / wethReserve;
    }

    /**
     * @notice Get SOL price from SOL/USDC pool
     */
    function _getSolPriceFromPool() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(solUsdcPair).getReserves();
        address token0 = IUniswapV2Pair(solUsdcPair).token0();
        
        uint256 solReserve;
        uint256 usdcReserve;
        
        if (token0 == sol) {
            solReserve = uint256(reserve0);
            usdcReserve = uint256(reserve1);
        } else {
            solReserve = uint256(reserve1);
            usdcReserve = uint256(reserve0);
        }
        
        require(solReserve > 0, "No SOL liquidity");
        
        // SOL is 18 decimals on Base, USDC is 6 decimals
        return (usdcReserve * 1e30) / solReserve;
    }

    /**
     * @notice Get presale cost estimate for frontend
     */
    function getPresaleCost(uint256 quantity) external view returns (
        uint256 ethCost,
        uint256 solCost,
        uint256 usdcCost
    ) {
        uint256 ethPrice = getCurrentEthPrice();
        uint256 solPrice = getCurrentSolPrice();
        
        ethCost = ((PRESALE_PRICE_USD * 1e18) / ethPrice) * quantity;
        solCost = ((PRESALE_PRICE_USD * 1e18) / solPrice) * quantity;
        usdcCost = (100 * 1e6) * quantity; // $100 USDC per NFT
    }

    // ============ PRESALE MINTING ============

    /**
     * @notice Mint NFT during presale with ETH at $100 USD
     * @dev Swaps ETH → USDC, sends USDC to nftMintFund
     */
    function mintPresaleETH(address to, uint256 quantity) external payable nonReentrant {
        require(!paused, "Minting paused");
        require(presaleActive, "Presale not active");
        require(address(uniswapRouter) != address(0), "Router not set");
        require(usdc != address(0), "USDC not set");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= PRESALE_MAX, "Exceeds presale max");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");

        uint256 currentEthPrice = getCurrentEthPrice();
        uint256 ethCostPerNFT = (PRESALE_PRICE_USD * 1e18) / currentEthPrice;
        uint256 totalETHCost = ethCostPerNFT * quantity;
        require(msg.value >= totalETHCost, "Insufficient ETH");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;

        // Swap ETH → USDC and send to nftMintFund
        uint256 expectedUsdc = 100 * 1e6 * quantity; // $100 USDC per NFT
        uint256 minUsdcOut = (expectedUsdc * 95) / 100; // 5% slippage tolerance
        
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = usdc;
        
        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: totalETHCost}(
            minUsdcOut,
            path,
            nftMintFund,
            block.timestamp
        );

        // Refund excess ETH
        if (msg.value > totalETHCost) {
            payable(msg.sender).transfer(msg.value - totalETHCost);
        }
    }

    /**
     * @notice Mint NFT during presale with SOL at $100 USD
     * @dev Swaps SOL → USDC, sends USDC to nftMintFund
     */
    function mintPresaleSOL(address to, uint256 quantity) external nonReentrant {
        require(!paused, "Minting paused");
        require(presaleActive, "Presale not active");
        require(address(uniswapRouter) != address(0), "Router not set");
        require(sol != address(0), "SOL not set");
        require(usdc != address(0), "USDC not set");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= PRESALE_MAX, "Exceeds presale max");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");

        uint256 currentSolPrice = getCurrentSolPrice();
        uint256 solCostPerNFT = (PRESALE_PRICE_USD * 1e18) / currentSolPrice;
        uint256 totalSOLCost = solCostPerNFT * quantity;

        // Transfer SOL from user to contract
        require(IERC20(sol).transferFrom(msg.sender, address(this), totalSOLCost), "SOL transfer failed");
        
        // Approve router to spend SOL
        IERC20(sol).approve(address(uniswapRouter), totalSOLCost);
        
        // Swap SOL → USDC and send to nftMintFund
        uint256 expectedUsdc = 100 * 1e6 * quantity;
        uint256 minUsdcOut = (expectedUsdc * 95) / 100; // 5% slippage tolerance
        
        address[] memory path = new address[](2);
        path[0] = sol;
        path[1] = usdc;
        
        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            totalSOLCost,
            minUsdcOut,
            path,
            nftMintFund,
            block.timestamp
        );

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;
    }

    /**
     * @notice Mint NFT during presale with USDC at $100
     */
    function mintPresaleUSDC(address to, uint256 quantity) external nonReentrant {
        require(!paused, "Minting paused");
        require(presaleActive, "Presale not active");
        require(usdc != address(0), "USDC not set");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= PRESALE_MAX, "Exceeds presale max");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");

        // USDC has 6 decimals
        uint256 usdcCostPerNFT = 100 * 1e6; // $100
        uint256 totalUSDCCost = usdcCostPerNFT * quantity;

        require(IERC20(usdc).transferFrom(msg.sender, nftMintFund, totalUSDCCost), "USDC transfer failed");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;
    }

    // ============ POST-PRESALE FUNCTIONS ============

    function endPresale() external onlyOwner {
        require(presaleActive, "Presale already ended");
        presaleActive = false;
        postPresaleActive = true;
        emit PresaleEnded();
        emit PostPresaleStarted();
    }

    /**
     * @notice Lock in the current mint price for 1 minute
     * @dev Allows users to swap for TOKEN knowing exact cost
     */
    function lockMintPrice() external {
        require(postPresaleActive, "Post-presale not active");
        uint256 price = getPostPresaleMintPrice();
        mintPriceLocked[msg.sender] = price;
        mintPriceLockExpiry[msg.sender] = block.timestamp + PRICE_LOCK_DURATION;
        emit PriceLocked(msg.sender, price, mintPriceLockExpiry[msg.sender]);
    }

    /**
     * @notice Get post-presale mint price in TOKEN
     * @return tokenAmount Amount of TOKEN needed per NFT = Circulating Supply / 10,000
     */
    function getMintPriceInToken() public view returns (uint256) {
        require(erc20Token != address(0), "Token not set");
        
        // Get circulating supply (total - dead - locked team tokens)
        uint256 totalSupply = IERC20(erc20Token).totalSupply();
        uint256 deadBalance = IERC20(erc20Token).balanceOf(DEAD_WALLET);
        uint256 lockerBalance = tokenLocker != address(0) 
            ? IERC20(erc20Token).balanceOf(tokenLocker) 
            : 0;
        
        uint256 circulatingSupply = totalSupply - deadBalance - lockerBalance;
        
        // Price = Circulating Supply / 10,000 (0.01% of circulating)
        return circulatingSupply / 10000;
    }

    /**
     * @notice Get ETH quote for minting (includes 1.618% tax buffer)
     * @dev User needs this much ETH to swap for TOKEN and then mint
     */
    function getMintPriceInETH() public view returns (uint256) {
        require(uniswapV2PairTokenWeth != address(0), "Pair not set");
        
        uint256 tokenAmount = getMintPriceInToken();
        uint256 ethAmount = _getEthAmountForToken(tokenAmount);
        
        // Add 1.618% tax buffer (they'll lose this when swapping)
        // ETH needed = ethAmount / (1 - 0.01618) = ethAmount * 100000 / 98382
        return (ethAmount * 100000) / 98382;
    }

    /**
     * @notice Get SOL quote for minting (includes 1.618% tax buffer)
     */
    function getMintPriceInSOL() public view returns (uint256) {
        require(uniswapV2PairTokenSol != address(0), "SOL pair not set");
        
        uint256 tokenAmount = getMintPriceInToken();
        uint256 solAmount = _getSolAmountForToken(tokenAmount);
        
        // Add 1.618% tax buffer
        return (solAmount * 100000) / 98382;
    }

    // Keep old name for compatibility, now returns TOKEN amount
    function getPostPresaleMintPrice() public view returns (uint256) {
        return getMintPriceInToken();
    }

    function _getEthAmountForToken(uint256 tokenAmount) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(uniswapV2PairTokenWeth).getReserves();
        address token0 = IUniswapV2Pair(uniswapV2PairTokenWeth).token0();
        
        uint256 tokenReserve;
        uint256 wethReserve;
        
        if (token0 == erc20Token) {
            tokenReserve = uint256(reserve0);
            wethReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            wethReserve = uint256(reserve0);
        }
        
        require(tokenReserve > 0, "No liquidity");
        
        // ETH = tokenAmount * wethReserve / tokenReserve
        return (tokenAmount * wethReserve) / tokenReserve;
    }

    function _getSolAmountForToken(uint256 tokenAmount) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(uniswapV2PairTokenSol).getReserves();
        address token0 = IUniswapV2Pair(uniswapV2PairTokenSol).token0();
        
        uint256 tokenReserve;
        uint256 solReserve;
        
        if (token0 == erc20Token) {
            tokenReserve = uint256(reserve0);
            solReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            solReserve = uint256(reserve0);
        }
        
        require(tokenReserve > 0, "No liquidity");
        
        // SOL = tokenAmount * solReserve / tokenReserve
        return (tokenAmount * solReserve) / tokenReserve;
    }

    /**
     * @notice Mint NFT post-presale with ETH
     * @dev Price includes 1.618% tax buffer since user would need to swap ETH → TOKEN
     *      User can pay ETH directly, we receive it (no actual swap happens)
     */
    function mintPostPresaleETH(address to, uint256 quantity) external payable nonReentrant {
        require(!paused, "Minting paused");
        require(postPresaleActive, "Post-presale not active");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= MAX_SUPPLY, "Exceeds max supply");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");

        uint256 pricePerNFT;
        if (block.timestamp <= mintPriceLockExpiry[msg.sender]) {
            pricePerNFT = mintPriceLocked[msg.sender];
        } else {
            pricePerNFT = getMintPriceInETH(); // Includes 1.618% tax buffer
        }

        uint256 totalETHCost = pricePerNFT * quantity;
        require(msg.value >= totalETHCost, "Insufficient ETH");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;

        // Clear price lock
        delete mintPriceLocked[msg.sender];
        delete mintPriceLockExpiry[msg.sender];

        // Refund excess
        if (msg.value > totalETHCost) {
            payable(msg.sender).transfer(msg.value - totalETHCost);
        }
    }

    /**
     * @notice Mint NFT post-presale with SOL
     * @dev Price includes 1.618% tax buffer since user would need to swap SOL → TOKEN
     */
    function mintPostPresaleSOL(address to, uint256 quantity) external nonReentrant {
        require(!paused, "Minting paused");
        require(postPresaleActive, "Post-presale not active");
        require(sol != address(0), "SOL not set");
        require(uniswapV2PairTokenSol != address(0), "SOL pair not set");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= MAX_SUPPLY, "Exceeds max supply");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");

        // Get SOL price (includes 1.618% tax buffer)
        uint256 pricePerNFT = getMintPriceInSOL();
        uint256 totalSOLCost = pricePerNFT * quantity;

        require(IERC20(sol).transferFrom(msg.sender, address(this), totalSOLCost), "SOL transfer failed");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;
    }

    /**
     * @notice Mint NFT post-presale with TOKEN (simplest - no swap needed)
     */
    function mintWithToken(address to, uint256 quantity) external nonReentrant {
        require(!paused, "Minting paused");
        require(postPresaleActive, "Post-presale not active");
        require(quantity > 0 && quantity <= MAX_PER_MINT, "Invalid quantity");
        require(mintedCount + quantity <= MAX_SUPPLY, "Exceeds max supply");
        require(walletMintedCount[to] + quantity <= maxWallet, "Exceeds max per wallet");
        require(address(_erc20Contract) != address(0), "Token not set");

        // Price in TOKEN = Circulating Supply / 10,000
        uint256 tokenPricePerNFT = getMintPriceInToken();
        uint256 totalTokenCost = tokenPricePerNFT * quantity;

        require(_erc20Contract.allowance(msg.sender, address(this)) >= totalTokenCost, "Insufficient allowance");
        require(_erc20Contract.balanceOf(msg.sender) >= totalTokenCost, "Insufficient balance");
        require(_erc20Contract.transferFrom(msg.sender, address(this), totalTokenCost), "Transfer failed");

        _mintBatch(to, quantity);
        walletMintedCount[to] += quantity;
    }

    /**
     * @notice Get post-presale cost estimates for frontend
     */
    function getPostPresaleCost(uint256 quantity) external view returns (
        uint256 tokenCost,
        uint256 ethCost,
        uint256 solCost
    ) {
        tokenCost = getMintPriceInToken() * quantity;
        ethCost = getMintPriceInETH() * quantity;
        
        // SOL cost only if pair is set
        if (uniswapV2PairTokenSol != address(0)) {
            solCost = getMintPriceInSOL() * quantity;
        }
    }

    // ============ INTERNAL MINT LOGIC ============

    function _mintBatch(address to, uint256 quantity) private {
        for (uint256 i = 0; i < quantity; i++) {
            (uint256 randomId, uint256 points) = _randomizerContract.getNextIdAndPoints();
            require(!_minted[randomId], "Token already minted");
            
            _minted[randomId] = true;
            tokenIdToPoints[randomId] = points;
            pointsMintedCount[points]++;
            mintedCount++;

            _safeMint(to, randomId);

            if (nftTracker != address(0)) {
                INFTTracker(nftTracker).updateBalance(address(0), to, randomId, points);
            }
            emit Minted(to, randomId, points);
        }

        // Auto-pause presale at PRESALE_MAX
        if (presaleActive && mintedCount >= PRESALE_MAX) {
            presaleActive = false;
            postPresaleActive = true;
            emit PresaleEnded();
            emit PostPresaleStarted();
        }
    }

    // ============ TRANSFER HOOK ============

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        address previousOwner = super._update(to, tokenId, auth);

        // Update tracker on transfer/burn (skip on mint - handled in _mintBatch)
        if (from != address(0) && nftTracker != address(0)) {
            uint256 points = tokenIdToPoints[tokenId];
            INFTTracker(nftTracker).updateBalance(from, to, tokenId, points);
        }

        return previousOwner;
    }

    // ============ METADATA ============

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");
        return string(abi.encodePacked(_baseURI(), tokenId.toString(), ".json"));
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Royalty) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}
