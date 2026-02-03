// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ARBContractV4 - On-Chain Price Arbitrage
 * @notice Compare TONE price between WETH and SOL pools using on-chain prices
 * @dev Uses PancakeSwap V3 SOL/WETH pool for cross-price conversion (no oracle needed!)
 * 
 * LOGIC:
 * 1. Get TONE/WETH ratio from V2 WETH pool
 * 2. Get TONE/SOL ratio from V2 SOL pool
 * 3. Get SOL/WETH price from V3 pool (sqrtPriceX96)
 * 4. Convert SOL pool TONE price to WETH terms
 * 5. Compare and arbitrage if gap > threshold
 */

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint32 feeProtocol,
        bool unlocked
    );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC721 {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice PancakeSwap V3 Router for SOL<->WETH swaps
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract ARBContractV4 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ CORE ADDRESSES ============
    address public immutable mainToken;
    address public immutable v2Router;
    address public v3Router;
    address public poolWETH;              // TOKEN/WETH V2 pool
    address public poolSOL;               // TOKEN/SOL V2 pool
    address public v3PoolSolWeth;         // SOL/WETH V3 pool for price reference
    address public weth;
    address public sol;
    address public wwmmAddress;
    
    // NFT Gate
    address public nftContract;
    mapping(address => uint256) public lastNftCheckBlock;
    
    // V3 Pool config
    uint24 public v3PoolFee = 500;        // 0.05% for SOL/WETH
    
    // ============ CONFIGURATION ============
    uint256 public gapThresholdBps = 210; // 2.1% gap required for arb
    uint256 public cooldownBlocks = 5;
    uint256 public slippageBps = 100;     // 1% slippage tolerance
    
    // NFT Holder Limits ("pistol" restrictions)
    uint256 public maxNftArbAmount = 1_000_000 * 10**18;  // Max tokens per arb (default 1M)
    uint256 public minNftArbAmount = 10_000 * 10**18;     // Min tokens per arb (default 10K)
    uint256 public maxArbsPerPeriod = 1;                   // Max arbs per period per holder
    uint256 public blocksPerPeriod = 21600;                // Default 12H (12 * 60 * 60 / 2)
    uint256 public constant SECONDS_PER_BLOCK = 2;         // Base L2 block time (constant)
    mapping(address => mapping(uint256 => uint256)) public periodArbCount;  // user => period (in blocks) => count
    
    // ============ TRACKING ============
    struct ArberStats {
        uint256 totalBonusEarned;
        uint256 tradeCount;
        uint256 lastArbBlock;
    }
    mapping(address => ArberStats) public arberRegistry;
    
    uint256 public totalArbitrageVolume;
    uint256 public totalArbitrageCount;
    
    // ============ EVENTS ============
    event ArbitrageExecuted(address indexed executor, bool wethPoolExpensive, uint256 amountIn, uint256 profit);
    event PriceGapDetected(uint256 wethPoolPrice, uint256 solPoolPriceInWeth, uint256 gapBps);
    event PoolsUpdated(address indexed poolWETH, address indexed poolSOL);
    event WwmmAddressUpdated(address indexed newWwmm);
    event NftContractUpdated(address indexed newNft);
    event SlippageBpsUpdated(uint256 newSlippage);
    event V3RouterUpdated(address indexed newRouter);
    event V3PoolSolWethUpdated(address indexed newPool);
    event MaxNftArbAmountUpdated(uint256 newAmount);
    event MinNftArbAmountUpdated(uint256 newAmount);
    event MaxArbsPerPeriodUpdated(uint256 newMax);
    event BlocksPerPeriodUpdated(uint256 newBlocks);
    event GapThresholdUpdated(uint256 newThresholdBps);
    event CooldownBlocksUpdated(uint256 newBlocks);

    // ============ MODIFIERS ============
    modifier onlyNFTHolderOrWWMM() {
        if (msg.sender != wwmmAddress) {
            require(nftContract != address(0) && IERC721(nftContract).balanceOf(msg.sender) > 0, "Must hold NFT");
            require(lastNftCheckBlock[msg.sender] > 0 && lastNftCheckBlock[msg.sender] < block.number, "NFT held < 1 block");
            require(block.number >= arberRegistry[msg.sender].lastArbBlock + cooldownBlocks, "Cooldown active");
            // Period limit check for NFT holders (12H periods, using block number)
            uint256 currentPeriod = block.number / blocksPerPeriod;
            require(periodArbCount[msg.sender][currentPeriod] < maxArbsPerPeriod, "Period arb limit reached");
        }
        _;
    }
    
    /// @notice Register NFT ownership for flash loan protection
    function registerNftOwnership() external {
        require(nftContract != address(0) && IERC721(nftContract).balanceOf(msg.sender) > 0, "Must hold NFT");
        lastNftCheckBlock[msg.sender] = block.number;
    }
    
    constructor(
        address _mainToken,
        address _v2Router,
        address _v3Router,
        address _v3PoolSolWeth
    ) Ownable(msg.sender) {
        mainToken = _mainToken;
        v2Router = _v2Router;
        v3Router = _v3Router;
        v3PoolSolWeth = _v3PoolSolWeth;
        
        IERC20(_mainToken).approve(_v2Router, type(uint256).max);
    }
    
    // ============ CORE PRICE FUNCTIONS ============
    
    /**
     * @notice Get TONE price in WETH from the WETH pool
     * @return priceInWeth TONE price in WETH (18 decimals)
     */
    function getTonePriceInWeth() public view returns (uint256 priceInWeth) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(poolWETH).getReserves();
        address token0 = IUniswapV2Pair(poolWETH).token0();
        
        uint256 toneReserve;
        uint256 wethReserve;
        
        if (token0 == mainToken) {
            toneReserve = uint256(reserve0);
            wethReserve = uint256(reserve1);
        } else {
            toneReserve = uint256(reserve1);
            wethReserve = uint256(reserve0);
        }
        
        if (toneReserve == 0) return 0;
        
        // Price in WETH = wethReserve / toneReserve (both 18 decimals)
        priceInWeth = (wethReserve * 1e18) / toneReserve;
    }
    
    /**
     * @notice Get TONE price in SOL from the SOL pool
     * @return priceInSol TONE price in SOL (9 decimals, normalized to 18)
     */
    function getTonePriceInSol() public view returns (uint256 priceInSol) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(poolSOL).getReserves();
        address token0 = IUniswapV2Pair(poolSOL).token0();
        
        uint256 toneReserve;
        uint256 solReserve;
        
        if (token0 == mainToken) {
            toneReserve = uint256(reserve0);
            solReserve = uint256(reserve1);
        } else {
            toneReserve = uint256(reserve1);
            solReserve = uint256(reserve0);
        }
        
        if (toneReserve == 0) return 0;
        
        // SOL is 9 decimals, normalize to 18
        // Price in SOL (normalized) = (solReserve * 1e9 * 1e18) / toneReserve
        priceInSol = (solReserve * 1e9 * 1e18) / toneReserve;
    }
    
    /**
     * @notice Get SOL/WETH price from V3 pool
     * @return solPriceInWeth Price of 1 SOL in WETH (18 decimals)
     * @dev Uses sqrtPriceX96 from slot0, handles token ordering
     * 
     * Math explanation:
     * - sqrtPriceX96 = sqrt(token1/token0) * 2^96
     * - price = (sqrtPriceX96)^2 / 2^192
     * - This gives price in smallest units: (token1_smallest / token0_smallest)
     * - For SOL/WETH where token0=SOL(9dec), token1=WETH(18dec):
     *   price_raw = WETH_wei / SOL_lamport
     * - To get "1 SOL in WETH": (price_raw * 1e9) / 1e18 = price_raw / 1e9
     */
    function getSolWethPrice() public view returns (uint256 solPriceInWeth) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(v3PoolSolWeth).slot0();
        
        address token0 = IUniswapV3Pool(v3PoolSolWeth).token0();
        
        // Use proper fixed-point math to avoid overflow
        // sqrtPriceX96^2 / 2^192 gives us the raw price ratio
        // We need to handle this carefully due to large numbers
        
        // First, divide by 2^96 before squaring to reduce magnitude
        // price = (sqrtPriceX96 / 2^96) * (sqrtPriceX96 / 2^96)
        // But we need precision, so we do: (sqrtPriceX96 * sqrtPriceX96 / 2^64) / 2^128
        
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        
        if (token0 == sol) {
            // token0 = SOL (9 dec), token1 = WETH (18 dec)
            // price_raw = sqrtPrice^2 / 2^192 = WETH_wei per SOL_lamport
            // 1 SOL (1e9 lamports) in WETH_wei = price_raw * 1e9
            // In WETH = price_raw * 1e9 / 1e18 = price_raw / 1e9
            // We want result in 18 decimals, so multiply by 1e18 then divide appropriately
            
            // To avoid overflow: sqrtPrice^2 can be ~10^65 for sqrtPrice ~10^32
            // We'll compute (sqrtPrice^2 >> 128) first, then adjust
            uint256 priceX64 = (sqrtPrice * sqrtPrice) >> 128; // This is price * 2^64
            // Now divide by 2^64 to get raw price
            // price_raw = priceX64 / 2^64
            // sol_in_weth (18 dec) = price_raw * 1e9 / 1e18 * 1e18 = price_raw * 1e9
            // But price_raw = priceX64 / 2^64, so:
            // sol_in_weth = (priceX64 * 1e9) / 2^64
            solPriceInWeth = (priceX64 * 1e9) >> 64;
        } else {
            // token0 = WETH (18 dec), token1 = SOL (9 dec)
            // price_raw = SOL_lamports per WETH_wei
            // We want WETH_wei per SOL_lamport = 1 / price_raw
            uint256 priceX64 = (sqrtPrice * sqrtPrice) >> 128;
            if (priceX64 > 0) {
                // price_raw = priceX64 / 2^64 = SOL_lamports per WETH_wei
                // sol_in_weth = 1 / price_raw * (decimal adjustment)
                // = 2^64 / priceX64 * 1e9 (to account for 9 dec difference)
                solPriceInWeth = (uint256(1) << 64) * 1e9 / priceX64;
            }
        }
    }
    
    /**
     * @notice Get arb info - checks if arb is available and calculates optimal amount
     * @return available True if gap >= threshold
     * @return wethPoolExpensive True if WETH pool has higher TONE price
     * @return optimalAmount Optimal TONE amount to trade
     */
    function getArbInfo() external view returns (
        bool available,
        bool wethPoolExpensive,
        uint256 optimalAmount
    ) {
        uint256 tonePriceWeth = getTonePriceInWeth();      // TONE price in WETH (18 dec)
        uint256 tonePriceSol = getTonePriceInSol();        // TONE price in SOL (normalized to 18)
        uint256 solWethPrice = getSolWethPrice();          // SOL price in WETH (18 dec)
        
        if (tonePriceWeth == 0 || tonePriceSol == 0 || solWethPrice == 0) {
            return (false, false, 0);
        }
        
        // Convert SOL pool TONE price to WETH terms
        // tonePriceSol is in SOL (normalized), multiply by SOL/WETH price
        uint256 tonePriceSolInWeth = (tonePriceSol * solWethPrice) / 1e18;
        
        // Calculate gap in basis points
        uint256 gapBps;
        uint256 avgPrice = (tonePriceWeth + tonePriceSolInWeth) / 2;
        
        if (tonePriceWeth > tonePriceSolInWeth) {
            gapBps = avgPrice > 0 ? ((tonePriceWeth - tonePriceSolInWeth) * 10000) / avgPrice : 0;
            wethPoolExpensive = true;
        } else {
            gapBps = avgPrice > 0 ? ((tonePriceSolInWeth - tonePriceWeth) * 10000) / avgPrice : 0;
            wethPoolExpensive = false;
        }
        
        // Only available if gap >= threshold
        available = gapBps >= gapThresholdBps;
        
        if (available) {
            // Trade into the CHEAP pool
            IUniswapV2Pair targetPool = IUniswapV2Pair(wethPoolExpensive ? poolSOL : poolWETH);
            (uint112 reserve0, uint112 reserve1,) = targetPool.getReserves();
            
            address token0 = targetPool.token0();
            uint256 tokenReserve = token0 == mainToken ? uint256(reserve0) : uint256(reserve1);
            
            // Trade percentage proportional to gap (half the gap to avoid overshooting)
            uint256 tradePercent = gapBps / 200;
            if (tradePercent > 5) tradePercent = 5;  // Cap at 5%
            if (tradePercent < 1) tradePercent = 1;  // Min 1%
            
            optimalAmount = (tokenReserve * tradePercent) / 100;
        }
    }
    
    /**
     * @notice Check arb opportunity (legacy interface)
     */
    function checkArbOpportunity() external view returns (
        bool available,
        uint256 gapBps,
        bool wethPoolExpensive
    ) {
        uint256 tonePriceWeth = getTonePriceInWeth();
        uint256 tonePriceSol = getTonePriceInSol();
        uint256 solWethPrice = getSolWethPrice();
        
        if (tonePriceWeth == 0 || tonePriceSol == 0 || solWethPrice == 0) {
            return (false, 0, false);
        }
        
        uint256 tonePriceSolInWeth = (tonePriceSol * solWethPrice) / 1e18;
        uint256 avgPrice = (tonePriceWeth + tonePriceSolInWeth) / 2;
        
        if (tonePriceWeth > tonePriceSolInWeth) {
            gapBps = avgPrice > 0 ? ((tonePriceWeth - tonePriceSolInWeth) * 10000) / avgPrice : 0;
            wethPoolExpensive = true;
        } else {
            gapBps = avgPrice > 0 ? ((tonePriceSolInWeth - tonePriceWeth) * 10000) / avgPrice : 0;
            wethPoolExpensive = false;
        }
        
        available = gapBps >= gapThresholdBps;
    }
    
    // ============ EXECUTION ============
    
    /**
     * @notice Execute arbitrage path
     * @param amountIn Amount of TONE to trade
     * @param sellWethFirst True = sell TONE to WETH pool first
     */
    function _executeArbPath(uint256 amountIn, bool sellWethFirst) internal {
        address[] memory path1 = new address[](2);
        address[] memory path2 = new address[](2);
        
        if (sellWethFirst) {
            // TONE -> WETH (V2) -> SOL (V3) -> TONE (V2)
            path1[0] = mainToken;
            path1[1] = weth;
            
            uint256[] memory expectedAmounts = IUniswapV2Router02(v2Router).getAmountsOut(amountIn, path1);
            uint256 minWethOut = (expectedAmounts[1] * (10000 - slippageBps)) / 10000;
            
            IUniswapV2Router02(v2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, minWethOut, path1, address(this), block.timestamp + 300
            );
            
            // WETH -> SOL via V3
            uint256 wethBalance = IERC20(weth).balanceOf(address(this));
            IERC20(weth).approve(v3Router, wethBalance);
            
            // Use V3 pool price for expected output
            uint256 solWethPrice = getSolWethPrice();
            uint256 expectedSolOut = solWethPrice > 0 ? (wethBalance * 1e18) / solWethPrice / 1e9 : 0;
            uint256 minSolOut = (expectedSolOut * (10000 - slippageBps)) / 10000;
            
            IPancakeV3Router(v3Router).exactInputSingle(
                IPancakeV3Router.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: sol,
                    fee: v3PoolFee,
                    recipient: address(this),
                    deadline: block.timestamp + 300,
                    amountIn: wethBalance,
                    amountOutMinimum: minSolOut,
                    sqrtPriceLimitX96: 0
                })
            );
            
            // SOL -> TONE via V2
            uint256 solBalance = IERC20(sol).balanceOf(address(this));
            IERC20(sol).approve(v2Router, solBalance);
            
            path2[0] = sol;
            path2[1] = mainToken;
            
            uint256[] memory expectedAmounts2 = IUniswapV2Router02(v2Router).getAmountsOut(solBalance, path2);
            uint256 minTokenOut = (expectedAmounts2[1] * (10000 - slippageBps)) / 10000;
            
            IUniswapV2Router02(v2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                solBalance, minTokenOut, path2, address(this), block.timestamp + 300
            );
        } else {
            // TONE -> SOL (V2) -> WETH (V3) -> TONE (V2)
            path1[0] = mainToken;
            path1[1] = sol;
            
            uint256[] memory expectedAmounts = IUniswapV2Router02(v2Router).getAmountsOut(amountIn, path1);
            uint256 minSolOut = (expectedAmounts[1] * (10000 - slippageBps)) / 10000;
            
            IERC20(sol).approve(v2Router, type(uint256).max);
            
            IUniswapV2Router02(v2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, minSolOut, path1, address(this), block.timestamp + 300
            );
            
            // SOL -> WETH via V3
            uint256 solBalance = IERC20(sol).balanceOf(address(this));
            IERC20(sol).approve(v3Router, solBalance);
            
            uint256 solWethPrice = getSolWethPrice();
            uint256 expectedWethOut = (solBalance * solWethPrice) / 1e18 * 1e9;
            uint256 minWethOut = (expectedWethOut * (10000 - slippageBps)) / 10000;
            
            IPancakeV3Router(v3Router).exactInputSingle(
                IPancakeV3Router.ExactInputSingleParams({
                    tokenIn: sol,
                    tokenOut: weth,
                    fee: v3PoolFee,
                    recipient: address(this),
                    deadline: block.timestamp + 300,
                    amountIn: solBalance,
                    amountOutMinimum: minWethOut,
                    sqrtPriceLimitX96: 0
                })
            );
            
            // WETH -> TONE via V2
            uint256 wethBalance = IERC20(weth).balanceOf(address(this));
            IERC20(weth).approve(v2Router, wethBalance);
            
            path2[0] = weth;
            path2[1] = mainToken;
            
            uint256[] memory expectedAmounts2 = IUniswapV2Router02(v2Router).getAmountsOut(wethBalance, path2);
            uint256 minTokenOut = (expectedAmounts2[1] * (10000 - slippageBps)) / 10000;
            
            IUniswapV2Router02(v2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wethBalance, minTokenOut, path2, address(this), block.timestamp + 300
            );
        }
    }
    
    /**
     * @notice Execute arbitrage - WWMM or NFT holders can call
     */
    function executeArbitrage(bool wethPoolExpensive, uint256 amountIn) external nonReentrant onlyNFTHolderOrWWMM {
        require(amountIn > 0, "Amount must be > 0");
        
        // Enforce min/max amount for NFT holders (WWMM has no limit)
        if (msg.sender != wwmmAddress) {
            require(amountIn >= minNftArbAmount, "Below min arb amount");
            require(amountIn <= maxNftArbAmount, "Exceeds max arb amount");
            periodArbCount[msg.sender][block.number / blocksPerPeriod]++;
        }
        
        IERC20(mainToken).safeTransferFrom(msg.sender, address(this), amountIn);
        
        uint256 balanceBefore = IERC20(mainToken).balanceOf(address(this));
        _executeArbPath(amountIn, wethPoolExpensive);
        uint256 balanceAfter = IERC20(mainToken).balanceOf(address(this));
        
        // Return tokens to caller
        if (balanceAfter > 0) {
            IERC20(mainToken).safeTransfer(msg.sender, balanceAfter);
        }
        
        // Calculate and track profit
        uint256 profit = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        
        // Track stats
        ArberStats storage stats = arberRegistry[msg.sender];
        stats.tradeCount++;
        stats.lastArbBlock = block.number;
        stats.totalBonusEarned += profit;
        
        totalArbitrageVolume += amountIn;
        totalArbitrageCount++;
        
        emit ArbitrageExecuted(msg.sender, wethPoolExpensive, amountIn, profit);
    }
    
    /**
     * @notice tradePistol - WWMM compatibility interface
     */
    function tradePistol(uint256 _amount, address[] calldata _path) external nonReentrant onlyNFTHolderOrWWMM {
        require(_amount > 0, "Amount must be > 0");
        require(_path.length >= 2, "Invalid path");
        
        // Enforce min/max amount for NFT holders (WWMM has no limit)
        if (msg.sender != wwmmAddress) {
            require(_amount >= minNftArbAmount, "Below min arb amount");
            require(_amount <= maxNftArbAmount, "Exceeds max arb amount");
            periodArbCount[msg.sender][block.number / blocksPerPeriod]++;
        }
        
        // Check if tokens already sent
        uint256 currentBalance = IERC20(mainToken).balanceOf(address(this));
        if (currentBalance < _amount) {
            IERC20(mainToken).safeTransferFrom(msg.sender, address(this), _amount);
        }
        
        bool sellWethFirst = (_path[1] == weth);
        
        uint256 balanceBefore = IERC20(mainToken).balanceOf(address(this));
        _executeArbPath(_amount, sellWethFirst);
        uint256 balanceAfter = IERC20(mainToken).balanceOf(address(this));
        
        // Return tokens to caller
        if (balanceAfter > 0) {
            IERC20(mainToken).safeTransfer(msg.sender, balanceAfter);
        }
        
        // Calculate and track profit
        uint256 profit = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        
        // Track stats
        ArberStats storage stats = arberRegistry[msg.sender];
        stats.tradeCount++;
        stats.lastArbBlock = block.number;
        stats.totalBonusEarned += profit;
        
        totalArbitrageVolume += _amount;
        totalArbitrageCount++;
        
        emit ArbitrageExecuted(msg.sender, sellWethFirst, _amount, profit);
    }
    
    // ============ DASHBOARD VIEW FUNCTIONS ============
    
    /**
     * @notice Get cooldown info for a user
     * @param user Address to check
     * @return blocksRemaining Blocks until next arb allowed (0 = ready)
     * @return secondsRemaining Seconds until next arb allowed (0 = ready)
     * @return canArbNow True if cooldown is complete
     */
    function getCooldownInfo(address user) external view returns (
        uint256 blocksRemaining,
        uint256 secondsRemaining,
        bool canArbNow
    ) {
        uint256 lastArb = arberRegistry[user].lastArbBlock;
        uint256 cooldownEnds = lastArb + cooldownBlocks;
        
        if (block.number >= cooldownEnds) {
            return (0, 0, true);
        }
        
        blocksRemaining = cooldownEnds - block.number;
        secondsRemaining = blocksRemaining * SECONDS_PER_BLOCK;
        canArbNow = false;
    }
    
    /**
     * @notice Get period (12H) arb status for a user
     * @param user Address to check
     * @return arbsUsed Number of arbs used this period
     * @return arbsRemaining Number of arbs remaining this period (max 1)
     * @return blocksUntilReset Blocks until period counter resets
     * @return secondsUntilReset Seconds until period counter resets
     */
    function getPeriodArbStatus(address user) external view returns (
        uint256 arbsUsed,
        uint256 arbsRemaining,
        uint256 blocksUntilReset,
        uint256 secondsUntilReset
    ) {
        uint256 currentPeriod = block.number / blocksPerPeriod;
        arbsUsed = periodArbCount[user][currentPeriod];
        arbsRemaining = arbsUsed >= maxArbsPerPeriod ? 0 : maxArbsPerPeriod - arbsUsed;
        
        // Calculate blocks until next period starts
        uint256 nextPeriodStart = (currentPeriod + 1) * blocksPerPeriod;
        blocksUntilReset = nextPeriodStart - block.number;
        secondsUntilReset = blocksUntilReset * SECONDS_PER_BLOCK;
    }
    
    /**
     * @notice Get complete user dashboard info
     * @param user Address to check
     * @return hasNft True if user holds NFT
     * @return isRegistered True if user has registered NFT ownership
     * @return canArbNow True if ACCESS REQUIREMENTS met (NFT + cooldown + period limit)
     *         NOTE: This does NOT check profitability - user decides if opportunity is worth it
     * @return cooldownSecondsRemaining Seconds until cooldown complete
     * @return periodArbsRemaining Arbs remaining this period (0 or 1)
     * @return periodResetSecondsRemaining Seconds until period limit resets
     * @return totalTradesExecuted User's total arb trade count
     * @return totalProfitEarned User's all-time profit from arbs
     * @return minTradeAmount Minimum tokens per trade
     * @return maxTradeAmount Maximum tokens per trade
     */
    function getUserDashboard(address user) external view returns (
        bool hasNft,
        bool isRegistered,
        bool canArbNow,
        uint256 cooldownSecondsRemaining,
        uint256 periodArbsRemaining,
        uint256 periodResetSecondsRemaining,
        uint256 totalTradesExecuted,
        uint256 totalProfitEarned,
        uint256 minTradeAmount,
        uint256 maxTradeAmount
    ) {
        // NFT check
        hasNft = nftContract != address(0) && IERC721(nftContract).balanceOf(user) > 0;
        isRegistered = lastNftCheckBlock[user] > 0 && lastNftCheckBlock[user] < block.number;
        
        // Cooldown check
        ArberStats storage stats = arberRegistry[user];
        uint256 cooldownEnds = stats.lastArbBlock + cooldownBlocks;
        bool cooldownComplete = block.number >= cooldownEnds;
        cooldownSecondsRemaining = cooldownComplete ? 0 : (cooldownEnds - block.number) * SECONDS_PER_BLOCK;
        
        // Period limit check
        uint256 currentPeriod = block.number / blocksPerPeriod;
        uint256 usedThisPeriod = periodArbCount[user][currentPeriod];
        periodArbsRemaining = usedThisPeriod >= maxArbsPerPeriod ? 0 : maxArbsPerPeriod - usedThisPeriod;
        
        uint256 nextPeriodStart = (currentPeriod + 1) * blocksPerPeriod;
        periodResetSecondsRemaining = (nextPeriodStart - block.number) * SECONDS_PER_BLOCK;
        
        // canArbNow = ACCESS REQUIREMENTS ONLY (user decides profitability)
        canArbNow = hasNft && isRegistered && cooldownComplete && periodArbsRemaining > 0;
        
        // Stats
        totalTradesExecuted = stats.tradeCount;
        totalProfitEarned = stats.totalBonusEarned;
        minTradeAmount = minNftArbAmount;
        maxTradeAmount = maxNftArbAmount;
    }
    
    /**
     * @notice Preview profit for a given arb amount
     * @param amountIn Amount of tokens to arb
     * @return available True if arb opportunity exists
     * @return wethPoolExpensive Direction of arb
     * @return estimatedProfit Estimated profit in tokens (before gas)
     * @return profitBps Profit as basis points of input
     * @return gapBps Current gap in basis points
     */
    function previewArb(uint256 amountIn) external view returns (
        bool available,
        bool wethPoolExpensive,
        uint256 estimatedProfit,
        uint256 profitBps,
        uint256 gapBps
    ) {
        uint256 tonePriceWeth = getTonePriceInWeth();
        uint256 tonePriceSol = getTonePriceInSol();
        uint256 solWethPrice = getSolWethPrice();
        
        if (tonePriceWeth == 0 || tonePriceSol == 0 || solWethPrice == 0) {
            return (false, false, 0, 0, 0);
        }
        
        uint256 tonePriceSolInWeth = (tonePriceSol * solWethPrice) / 1e18;
        uint256 avgPrice = (tonePriceWeth + tonePriceSolInWeth) / 2;
        
        if (tonePriceWeth > tonePriceSolInWeth) {
            gapBps = avgPrice > 0 ? ((tonePriceWeth - tonePriceSolInWeth) * 10000) / avgPrice : 0;
            wethPoolExpensive = true;
        } else {
            gapBps = avgPrice > 0 ? ((tonePriceSolInWeth - tonePriceWeth) * 10000) / avgPrice : 0;
            wethPoolExpensive = false;
        }
        
        available = gapBps >= gapThresholdBps;
        
        if (available && amountIn > 0) {
            // Estimate profit as roughly half the gap (conservative estimate accounting for slippage/fees)
            // Actual profit depends on pool depth and trade size
            profitBps = gapBps > slippageBps ? (gapBps - slippageBps) / 2 : 0;
            estimatedProfit = (amountIn * profitBps) / 10000;
        }
    }
    
    /**
     * @notice Get current arb opportunity details
     * @return available True if opportunity exists
     * @return gapBps Gap in basis points
     * @return wethPoolExpensive Direction
     * @return optimalAmount Suggested trade amount
     * @return thresholdBps Minimum gap required
     */
    function getArbOpportunity() external view returns (
        bool available,
        uint256 gapBps,
        bool wethPoolExpensive,
        uint256 optimalAmount,
        uint256 thresholdBps
    ) {
        (available, wethPoolExpensive, optimalAmount) = this.getArbInfo();
        
        // Calculate gap
        uint256 tonePriceWeth = getTonePriceInWeth();
        uint256 tonePriceSol = getTonePriceInSol();
        uint256 solWethPrice = getSolWethPrice();
        
        if (tonePriceWeth > 0 && tonePriceSol > 0 && solWethPrice > 0) {
            uint256 tonePriceSolInWeth = (tonePriceSol * solWethPrice) / 1e18;
            uint256 avgPrice = (tonePriceWeth + tonePriceSolInWeth) / 2;
            
            if (tonePriceWeth > tonePriceSolInWeth) {
                gapBps = avgPrice > 0 ? ((tonePriceWeth - tonePriceSolInWeth) * 10000) / avgPrice : 0;
            } else {
                gapBps = avgPrice > 0 ? ((tonePriceSolInWeth - tonePriceWeth) * 10000) / avgPrice : 0;
            }
        }
        
        thresholdBps = gapThresholdBps;
    }
    
    /**
     * @notice Get user's historical stats
     * @param user Address to check
     * @return tradeCount Total trades executed
     * @return totalBonusEarned Cumulative bonus earned (if tracked)
     * @return lastArbBlock Block of last arb
     * @return lastArbSecondsAgo Seconds since last arb
     */
    function getUserStats(address user) external view returns (
        uint256 tradeCount,
        uint256 totalBonusEarned,
        uint256 lastArbBlock,
        uint256 lastArbSecondsAgo
    ) {
        ArberStats storage stats = arberRegistry[user];
        tradeCount = stats.tradeCount;
        totalBonusEarned = stats.totalBonusEarned;
        lastArbBlock = stats.lastArbBlock;
        lastArbSecondsAgo = stats.lastArbBlock > 0 ? (block.number - stats.lastArbBlock) * SECONDS_PER_BLOCK : 0;
    }
    
    /**
     * @notice Get global arb statistics
     * @return totalVolume Total tokens arbed across all users
     * @return totalTrades Total arb trades executed
     * @return currentGapBps Current gap in basis points
     * @return opportunityAvailable True if arb opportunity exists
     */
    function getGlobalStats() external view returns (
        uint256 totalVolume,
        uint256 totalTrades,
        uint256 currentGapBps,
        bool opportunityAvailable
    ) {
        totalVolume = totalArbitrageVolume;
        totalTrades = totalArbitrageCount;
        
        // Get current gap
        uint256 tonePriceWeth = getTonePriceInWeth();
        uint256 tonePriceSol = getTonePriceInSol();
        uint256 solWethPrice = getSolWethPrice();
        
        if (tonePriceWeth > 0 && tonePriceSol > 0 && solWethPrice > 0) {
            uint256 tonePriceSolInWeth = (tonePriceSol * solWethPrice) / 1e18;
            uint256 avgPrice = (tonePriceWeth + tonePriceSolInWeth) / 2;
            
            if (tonePriceWeth > tonePriceSolInWeth) {
                currentGapBps = avgPrice > 0 ? ((tonePriceWeth - tonePriceSolInWeth) * 10000) / avgPrice : 0;
            } else {
                currentGapBps = avgPrice > 0 ? ((tonePriceSolInWeth - tonePriceWeth) * 10000) / avgPrice : 0;
            }
            
            opportunityAvailable = currentGapBps >= gapThresholdBps;
        }
    }
    
    /**
     * @notice Get all configurable parameters (for dashboard display)
     * @return _gapThresholdBps Min gap for WWMM auto-arb (bps)
     * @return _slippageBps Slippage tolerance (bps)
     * @return _cooldownBlocks Blocks between arbs
     * @return _blocksPerPeriod Blocks per period (e.g. 21600 = 12H)
     * @return _maxArbsPerPeriod Max arbs per period per NFT holder
     * @return _minNftArbAmount Min tokens per arb
     * @return _maxNftArbAmount Max tokens per arb
     * @return _periodSeconds Period length in seconds
     * @return _cooldownSeconds Cooldown length in seconds
     */
    function getConfig() external view returns (
        uint256 _gapThresholdBps,
        uint256 _slippageBps,
        uint256 _cooldownBlocks,
        uint256 _blocksPerPeriod,
        uint256 _maxArbsPerPeriod,
        uint256 _minNftArbAmount,
        uint256 _maxNftArbAmount,
        uint256 _periodSeconds,
        uint256 _cooldownSeconds
    ) {
        _gapThresholdBps = gapThresholdBps;
        _slippageBps = slippageBps;
        _cooldownBlocks = cooldownBlocks;
        _blocksPerPeriod = blocksPerPeriod;
        _maxArbsPerPeriod = maxArbsPerPeriod;
        _minNftArbAmount = minNftArbAmount;
        _maxNftArbAmount = maxNftArbAmount;
        _periodSeconds = blocksPerPeriod * SECONDS_PER_BLOCK;
        _cooldownSeconds = cooldownBlocks * SECONDS_PER_BLOCK;
    }

    // ============ OWNER FUNCTIONS ============
    
    function setWWMM(address _wwmm) external onlyOwner {
        wwmmAddress = _wwmm;
        emit WwmmAddressUpdated(_wwmm);
    }
    
    function setNFTContract(address _nft) external onlyOwner {
        nftContract = _nft;
        emit NftContractUpdated(_nft);
    }
    
    function setSlippageBps(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= 1000, "Max 10% slippage");
        slippageBps = _slippageBps;
        emit SlippageBpsUpdated(_slippageBps);
    }
    
    function setV3Router(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        v3Router = _router;
        IERC20(weth).approve(_router, type(uint256).max);
        IERC20(sol).approve(_router, type(uint256).max);
        emit V3RouterUpdated(_router);
    }
    
    function setV3PoolSolWeth(address _pool) external onlyOwner {
        require(_pool != address(0), "Invalid pool");
        v3PoolSolWeth = _pool;
        emit V3PoolSolWethUpdated(_pool);
    }
    
    function setV3PoolFee(uint24 _fee) external onlyOwner {
        v3PoolFee = _fee;
    }
    
    function setCooldownBlocks(uint256 _blocks) external onlyOwner {
        require(_blocks <= 1000, "Max 1000 blocks");
        cooldownBlocks = _blocks;
        emit CooldownBlocksUpdated(_blocks);
    }
    
    function setMaxNftArbAmount(uint256 _amount) external onlyOwner {
        require(_amount >= minNftArbAmount, "Max must be >= min");
        maxNftArbAmount = _amount;
        emit MaxNftArbAmountUpdated(_amount);
    }
    
    function setMinNftArbAmount(uint256 _amount) external onlyOwner {
        require(_amount <= maxNftArbAmount, "Min must be <= max");
        minNftArbAmount = _amount;
        emit MinNftArbAmountUpdated(_amount);
    }

    function setMaxArbsPerPeriod(uint256 _max) external onlyOwner {
        require(_max >= 1, "Min 1 arb per period");
        maxArbsPerPeriod = _max;
        emit MaxArbsPerPeriodUpdated(_max);
    }
    
    function setBlocksPerPeriod(uint256 _blocks) external onlyOwner {
        require(_blocks >= 1800, "Min 1 hour (1800 blocks)");
        require(_blocks <= 129600, "Max 3 days (129600 blocks)");
        blocksPerPeriod = _blocks;
        emit BlocksPerPeriodUpdated(_blocks);
    }
    
    function setGapThresholdBps(uint256 _gapBps) external onlyOwner {
        require(_gapBps <= 2000, "Max 20%");
        gapThresholdBps = _gapBps;
        emit GapThresholdUpdated(_gapBps);
    }
    
    function setPools(address _poolWETH, address _poolSOL) external onlyOwner {
        require(_poolWETH != address(0) && _poolSOL != address(0), "Invalid pools");
        poolWETH = _poolWETH;
        poolSOL = _poolSOL;
        emit PoolsUpdated(_poolWETH, _poolSOL);
    }
    
    function setTokenAddresses(address _weth, address _sol) external onlyOwner {
        require(_weth != address(0) && _sol != address(0), "Invalid tokens");
        weth = _weth;
        sol = _sol;
        
        IERC20(_weth).approve(v2Router, type(uint256).max);
        IERC20(_sol).approve(v2Router, type(uint256).max);
        IERC20(_weth).approve(v3Router, type(uint256).max);
        IERC20(_sol).approve(v3Router, type(uint256).max);
    }
    
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }
    
    function rescueTokensFor(address token, address to, uint256 amount) external {
        require(msg.sender == wwmmAddress, "Only WWMM");
        IERC20(token).safeTransfer(to, amount);
    }
    
    receive() external payable {}
}
