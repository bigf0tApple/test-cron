// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title WWMMContractV3 - Whitelisted Market Maker Engine
 * @notice Receives tax tokens and uses ARBContract for tax-exempt arbitrage
 * @dev IMPORTANT: WWMM is NOT tax-exempt! It routes trades through ARBContract
 * 
 * Flow:
 * 1. MainToken sends tax tokens → onTaxReceived()
 * 2. WWMM checks for price gap between pools
 * 3. If gap > threshold, WWMM calls ARB.tradePistol()
 * 4. ARB executes swap (ARB is tax-exempt)
 * 5. Profit returned to WWMM → Burned to DEAD wallet
 */

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface IARBContractV2 {
    function tradePistol(uint256 _amount, address[] calldata _path) external;
    function checkArbOpportunity() external view returns (bool available, uint256 profitBps, bool poolAExpensive);
    function getArbInfo() external view returns (bool available, bool wethPoolExpensive, uint256 optimalAmount);
    function rescueTokensFor(address token, address to, uint256 amount) external;
}

contract WWMMContractV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ ADDRESSES ============
    address public immutable mainToken;
    address public arbContract;             // ARBContractV2 for tax-exempt trades
    address public poolA;                   // TOKEN/WETH pool
    address public poolB;                   // TOKEN/SOL pool
    address public weth;
    address public sol;

    address public constant DEAD_WALLET = 0x000000000000000000000000000000000000dEaD;

    // ============ CONFIGURATION ============
    uint256 public maxTradePercent = 5;         // Max % of pool reserves to trade (default 5%)
    uint256 public wwmmGapBps = 210;            // 2.1% minimum gap to trigger (leave < 2% for community)
    uint256 public minTradeThreshold = 100 * 10**18;  // 100 tokens minimum to consider trading
    bool public paused;

    // ============ KEEPER MANAGEMENT ============
    // Authorized off-chain keepers may trigger arb checks when allowed
    mapping(address => bool) public keepers;


    // ============ STATS ============
    uint256 public totalBurnt;
    uint256 public totalArbsExecuted;
    uint256 public lastBurnt;
    uint256 public lastArbBlock;

    // ============ EVENTS ============
    event MaxTradePercentUpdated(uint256 percent);
    event TaxReceived(uint256 amount);
    event RebalanceExecuted(uint256 amountIn, uint256 amountOut, uint256 profit, bool poolAExpensive);
    event ProfitBurned(uint256 amount, uint256 totalBurnt);
    event ForceSyncExecuted(address indexed caller, uint256 amount);
    event PoolsSet(address poolA, address poolB);
    event ARBContractSet(address oldArb, address newArb);
    event Paused(bool status);
    event KeeperUpdated(address indexed keeper, bool enabled);

    // ============ CONSTRUCTOR ============
    constructor(
        address _mainToken,
        address _arbContract,
        address _poolA,
        address _poolB,
        address _weth,
        address _sol
    ) Ownable(msg.sender) {
        mainToken = _mainToken;
        arbContract = _arbContract;
        poolA = _poolA;
        poolB = _poolB;
        weth = _weth;
        sol = _sol;
        
        // Approve ARB to pull tokens from WWMM (for tradePistol)
        IERC20(_mainToken).approve(_arbContract, type(uint256).max);
    }

    // ============ RECEIVE TOKENS ============

    /**
     * @notice Called when MainToken sends tax tokens (piggyback trigger)
     */
    function onTaxReceived(uint256 amount) external {
        require(msg.sender == mainToken, "Only main token");
        emit TaxReceived(amount);
        
        // Try to arb with our current balance
        _tryArb();
    }
    
    /**
     * @notice Called by MainToken on every sell to check for arb opportunity
     * @dev Separate from tax distribution - arb can happen regardless of tax threshold
     */
    function checkArb() external {
        require(msg.sender == mainToken, "Only main token");
        _tryArb();
    }

    /**
     * @notice Keeper-triggerable arb check
     * @dev Allows authorized off-chain keepers to trigger an arb check when
     *      automatic on-sell piggyback is not available. Keepers are managed
     *      by the contract owner via `setKeeper`.
     */
    function keeperTrigger() external {
        require(keepers[msg.sender], "Not an authorized keeper");
        _tryArb();
    }
    
    /**
     * @notice Internal: Check for arb and execute if profitable
     */
    function _tryArb() internal {
        uint256 balance = IERC20(mainToken).balanceOf(address(this));
        if (balance < minTradeThreshold) {
            return; // Not enough tokens yet
        }
        
        _checkAndRebalance();
    }

    receive() external payable {}

    // ============ CORE LOGIC ============

    /**
     * @notice Check for arb opportunity and execute if profitable
     * @dev Gets optimal amount from ARB contract - sends only what's needed to close gap
     */
    function _checkAndRebalance() internal {
        if (paused) return;
        if (poolA == address(0) || poolB == address(0) || arbContract == address(0)) return;

        // Get arb info from ARB contract (includes optimal amount)
        (bool available, bool poolAExpensive, uint256 optimalAmount) = IARBContractV2(arbContract).getArbInfo();
        
        // Only execute if arb available and gap >= our threshold
        if (!available) {
            return;
        }
        
        // Cap at what we have available
        uint256 balance = IERC20(mainToken).balanceOf(address(this));
        uint256 amountToTrade = optimalAmount > balance ? balance : optimalAmount;
        
        if (amountToTrade == 0) return;
        
        // Execute through ARB contract (tax-exempt!)
        uint256 balanceBefore = IERC20(mainToken).balanceOf(address(this));
        _executeRebalanceThroughARB(amountToTrade, poolAExpensive);
        uint256 balanceAfter = IERC20(mainToken).balanceOf(address(this));
        
        // Burn profit to DEAD wallet
        if (balanceAfter > balanceBefore) {
            uint256 profit = balanceAfter - balanceBefore;
            
            IERC20(mainToken).safeTransfer(DEAD_WALLET, profit);
            
            lastBurnt = profit;
            totalBurnt += profit;
            totalArbsExecuted++;
            lastArbBlock = block.number;
            
            emit ProfitBurned(profit, totalBurnt);
            emit RebalanceExecuted(amountToTrade, balanceAfter, profit, poolAExpensive);
        }
    }

    /**
     * @notice Execute trade THROUGH ARB_CONTRACT for tax exemption
     * @dev WWMM is whitelisted in ARB_CONTRACT, so no cap/cooldown applies
     * 
     * ARBITRAGE LOGIC:
     * - If Pool A (WETH) is expensive: Sell TONE TO WETH pool (get expensive WETH), 
     *   swap WETH→SOL via V3, buy TONE FROM SOL pool (cheap)
     * - If Pool B (SOL) is expensive: Sell TONE TO SOL pool (get expensive SOL),
     *   swap SOL→WETH via V3, buy TONE FROM WETH pool (cheap)
     */
    function _executeRebalanceThroughARB(uint256 amount, bool poolAExpensive) internal {
        // Build 4-hop path for cross-pool arb
        address[] memory path = new address[](4);
        path[0] = mainToken;
        path[3] = mainToken;
        
        if (poolAExpensive) {
            // Pool A (WETH) expensive → SELL to WETH pool first (get expensive WETH)
            // Path: TOKEN → WETH → SOL → TOKEN
            path[1] = weth;  // FIXED: Sell to expensive pool
            path[2] = sol;
        } else {
            // Pool B (SOL) expensive → SELL to SOL pool first (get expensive SOL)
            // Path: TOKEN → SOL → WETH → TOKEN
            path[1] = sol;   // FIXED: Sell to expensive pool
            path[2] = weth;
        }
        
        // Transfer tokens to ARB first
        IERC20(mainToken).safeTransfer(arbContract, amount);
        
        // Call ARB_CONTRACT.tradePistol - WWMM is whitelisted, ARB is tax-exempt!
        try IARBContractV2(arbContract).tradePistol(amount, path) {
            // Success - tokens come back with profit
        } catch {
            // Trade failed - attempt to recover tokens from ARB
            try IARBContractV2(arbContract).rescueTokensFor(mainToken, address(this), amount) {
                emit RebalanceRecovered(amount);
            } catch {
                // Recovery also failed - tokens may be stuck, log for manual intervention
                emit RebalanceRecoveryFailed(amount);
            }
        }
    }
    
    event RebalanceRecovered(uint256 amount);
    event RebalanceRecoveryFailed(uint256 amount);

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Check current arb opportunity (uses ARB contract)
     */
    function checkArbOpportunity() external returns (
        bool available,
        uint256 gapBps,
        bool poolAExpensive
    ) {
        if (arbContract == address(0)) {
            return (false, 0, false);
        }
        return IARBContractV2(arbContract).checkArbOpportunity();
    }

    function getStats() external view returns (
        uint256 _totalBurnt,
        uint256 _totalArbs,
        uint256 _lastBurnt,
        uint256 _lastBlock,
        uint256 _balance
    ) {
        _totalBurnt = totalBurnt;
        _totalArbs = totalArbsExecuted;
        _lastBurnt = lastBurnt;
        _lastBlock = lastArbBlock;
        _balance = IERC20(mainToken).balanceOf(address(this));
    }

    // ============ OWNER FUNCTIONS ============

    function forceSync() external onlyOwner nonReentrant {
        uint256 balance = IERC20(mainToken).balanceOf(address(this));
        require(balance >= minTradeThreshold, "Not enough tokens");
        _checkAndRebalance();
        emit ForceSyncExecuted(msg.sender, balance);
    }

    function setARBContract(address _arbContract) external onlyOwner {
        require(_arbContract != address(0), "Invalid address");
        
        address oldArb = arbContract;
        arbContract = _arbContract;
        
        // Revoke old approval, set new
        if (oldArb != address(0)) {
            IERC20(mainToken).approve(oldArb, 0);
        }
        IERC20(mainToken).approve(_arbContract, type(uint256).max);
        
        emit ARBContractSet(oldArb, _arbContract);
    }

    function setPools(address _poolA, address _poolB) external onlyOwner {
        require(_poolA != address(0) && _poolB != address(0), "Invalid pool");
        poolA = _poolA;
        poolB = _poolB;
        emit PoolsSet(_poolA, _poolB);
    }

    function setGapThreshold(uint256 _bps) external onlyOwner {
        require(_bps >= 100 && _bps <= 1000, "Must be 1-10%");
        wwmmGapBps = _bps;
    }

    function setMinTradeThreshold(uint256 _min) external onlyOwner {
        minTradeThreshold = _min;
    }

    function setMaxTradePercent(uint256 _percent) external onlyOwner {
        require(_percent > 0 && _percent <= 100, "Invalid percent");
        maxTradePercent = _percent;
        emit MaxTradePercentUpdated(_percent);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Add or remove an authorized keeper
     */
    function setKeeper(address _keeper, bool _enabled) external onlyOwner {
        keepers[_keeper] = _enabled;
        emit KeeperUpdated(_keeper, _enabled);
    }

    function withdrawToken(address to, uint256 amount) external onlyOwner {
        IERC20(mainToken).safeTransfer(to, amount);
    }

    function emergencyWithdraw(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);
    }
}
