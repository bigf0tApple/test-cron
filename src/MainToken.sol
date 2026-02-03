// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./Interfaces.sol";

/// @notice Interface for WWMM Contract piggyback trigger
interface IWWMM {
    function onTaxReceived(uint256 amount) external;
}

/// @notice Interface for Uniswap V2 Pair (for reading reserves)
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title MainToken (V2 Compatible)
 * @notice ERC20 token with 1.618% tax on buys/sells via Uniswap V2
 * @dev Tax is split: 14.60% TOKEN to WWMM contract (triggers arb), 85.40% swapped to ETH for Rewards
 */
contract MainToken is ERC20, Ownable, ReentrancyGuard {
    using Math for uint256;

    // ============ TAX CONFIGURATION ============
    // 5-decimal basis points for precise 1.618% tax
    uint256 public constant TAX_BPS = 1618;           // 1.618%
    uint256 public constant BPS_DIVISOR = 100_000;    // 5-decimal precision
    uint256 public constant WWMM_BPS = 14600;         // 14.60% of tax to WWMM (in TOKENS)
    uint256 public constant REWARDS_BPS = 85400;      // 85.40% of tax to Rewards (swapped to ETH)
    
    // Minimum tax to accumulate before triggering swap/distribute (prevents gas griefing)
    // LOCKED: Contract will be renounced, this value cannot be changed
    uint256 public constant MIN_TAX_FOR_DISTRIBUTE = 1000 * 10**18;  // 1000 tokens minimum
    
    // Maximum swap per distribution: 10% of pool reserves to prevent massive slippage
    uint256 public constant MAX_SWAP_PERCENT = 10;  // 10% of pool

    // ============ ADDRESSES ============
    address payable public wwmmWallet;
    ITokenTracker public tokenTracker;
    IRewards public rewardsContract;
    address public tokenLocker;
    address public wethPair;  // WETH pool for distribution cap calculation

    IUniswapV2Router02 public uniswapRouter;
    uint256 public taxAccumulated;
    bool private _distributing;  // Re-entrancy guard for _distributeTax

    // ============ SOL TOKEN ============
    address public sol = 0x311935Cd80B76769bF2ecC9D8Ab7635b2139cf82;

    // ============ PAIR TRACKING ============
    mapping(address => bool) public isUniswapPair;
    

    // ============ TAX EXCLUSIONS ============
    mapping(address => bool) public isExcludedFromTax;

    // ============ ANTI-BOT ============
    bool public limitsInEffect = true;
    uint256 public gasPriceLimit = 7 gwei;
    mapping(address => uint256) private _holderLastTransferBlock;
    uint256 public launchBlock;

    // ============ EMERGENCY ============
    bool public paused = false;

    // ============ STATS ============
    uint256 public totalTaxCollected;
    uint256 public totalRewardsSent;
    uint256 public totalWwmmSent;

    // ============ EVENTS ============
    event TradingEnabled(uint256 blockNumber);
    event TaxCollected(uint256 taxAmount, uint256 wwmmAmount, uint256 rewardsAmount, bool isBuy);
    event TokenLockerSet(address tokenLocker, uint256 amount);
    event PairUpdated(address pair, bool isPair);
    event TaxExclusionUpdated(address account, bool excluded);
    event EmergencyWithdraw(address token, address to, uint256 amount);
    // L-1: Added missing config events
    event WwmmWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event TokenTrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event RewardsContractUpdated(address indexed oldRewards, address indexed newRewards);
    event UniswapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event WethPairUpdated(address indexed oldPair, address indexed newPair);
    event GasPriceLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event LimitsRemoved();


    constructor(
        address _router
    ) ERC20("773me", "773ME") Ownable(msg.sender) {
        require(_router != address(0), "Invalid router");

        uniswapRouter = IUniswapV2Router02(_router);
        // Fixed total supply: 1 billion tokens (18 decimals)
        // !!! IMPORTANT: Change "TODO_TOKEN_NAME" and "TODO_TICKER" above before deployment !!!
        uint256 total = 1_000_000_000 * 10**18;
        
        // New 4-Wallet Allocation (38.2% total vested)
        // Dev: 13.47%, Core: 11.52%, Spillage: 5.72%, Free Wee: 7.49%
        address DEV = 0x77b1fBe87487eBB0e47Da8198dACf41c32827fC6;
        address CORE = 0x00aD851AbDe59d20DB72c7B2556e342CFca452E0;
        address SPILLAGE = 0x009A4d69A28F4e8f0B10D09FBD1c4Cf084aCe5B8;
        address FREE_WEE = 0xaeE5f3144A24177937Ba525C606f5899043923E4;
        
        uint256 devAmt = Math.mulDiv(total, 1347, 10000);      // 13.47% = 134.7M
        uint256 coreAmt = Math.mulDiv(total, 1152, 10000);     // 11.52% = 115.2M
        uint256 spillageAmt = Math.mulDiv(total, 572, 10000);  // 5.72% = 57.2M
        uint256 freeWeeAmt = Math.mulDiv(total, 749, 10000);   // 7.49% = 74.9M
        uint256 teamTotal = devAmt + coreAmt + spillageAmt + freeWeeAmt; // 382M
        uint256 deployerAmt = total - teamTotal;               // 61.8% = 618M for Presale + LP

        // Mint deployer tokens (Presale + LP) directly to deployer
        _mint(msg.sender, deployerAmt);
        // Mint team tokens to contract for later transfer to locker
        _mint(address(this), teamTotal);

        // ONLY MainToken(this) is tax exempt for internal swaps during _distributeTax
        // Deployer temporarily exempt for initial LP setup (can remove after enableTrading)
        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        
        // NOTE: ARB contract will be set as exempt via setArbContract()
        // ALL other addresses (WWMM, DEV, CORE, etc.) are NOT tax exempt by design
    }

    receive() external payable {}

    // ============ ADMIN FUNCTIONS ============

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function setWwmmWallet(address payable _wallet) external onlyOwner {
        require(_wallet != address(0), "Invalid wallet");
        address oldWallet = wwmmWallet;
        wwmmWallet = _wallet;
        emit WwmmWalletUpdated(oldWallet, _wallet);
    }

    /// @notice Set WWMM Contract (receives 14.6% tokens, triggers arb)
    /// @dev WWMM is NOT tax exempt - only ARB contract is exempt
    function setWwmmContract(address _contract) external onlyOwner {
        require(_contract != address(0), "Invalid contract");
        wwmmWallet = payable(_contract);
        // NOTE: WWMM is NOT exempt - it just transfers to ARB for arb execution
    }
    
    /// @notice Set ARB Contract as tax-exempt for community arbitrage
    function setArbContract(address _arbContract) external onlyOwner {
        require(_arbContract != address(0), "Invalid ARB contract");
        isExcludedFromTax[_arbContract] = true;
        emit TaxExclusionUpdated(_arbContract, true);
    }

    function setTokenTracker(address _tracker) external onlyOwner {
        require(_tracker != address(0), "Invalid tracker");
        address oldTracker = address(tokenTracker);
        tokenTracker = ITokenTracker(_tracker);
        // NOTE: TokenTracker is NOT tax exempt
        emit TokenTrackerUpdated(oldTracker, _tracker);
    }

    function setRewardsContract(address _rewards) external onlyOwner {
        require(_rewards != address(0), "Invalid rewards");
        address oldRewards = address(rewardsContract);
        rewardsContract = IRewards(_rewards);
        // NOTE: RewardsContract is NOT tax exempt
        emit RewardsContractUpdated(oldRewards, _rewards);
    }

    function setTokenLocker(address _locker) external onlyOwner {
        require(tokenLocker == address(0), "Locker already set");
        require(_locker != address(0), "Invalid locker");
        tokenLocker = _locker;
        // NOTE: TokenLocker is NOT tax exempt - vesting claims are taxed
        
        // Transfer team tokens to locker
        uint256 teamAmount = (totalSupply() * 3820) / 10000;
        _transfer(address(this), _locker, teamAmount);
        emit TokenLockerSet(_locker, teamAmount);
    }

    function setUniswapRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        address oldRouter = address(uniswapRouter);
        uniswapRouter = IUniswapV2Router02(_router);
        // NOTE: Router is NOT tax exempt
        emit UniswapRouterUpdated(oldRouter, _router);
    }

    function setIsUniswapPair(address _pair, bool _isPair) external onlyOwner {
        require(_pair != address(0), "Invalid pair");
        isUniswapPair[_pair] = _isPair;
        emit PairUpdated(_pair, _isPair);
    }

    function setWethPair(address _pair) external onlyOwner {
        require(_pair != address(0), "Invalid pair");
        address oldPair = wethPair;
        wethPair = _pair;
        emit WethPairUpdated(oldPair, _pair);
    }

    function setExcludedFromTax(address _account, bool _excluded) external onlyOwner {
        isExcludedFromTax[_account] = _excluded;
        emit TaxExclusionUpdated(_account, _excluded);
    }

    function enableTrading() external onlyOwner {
        require(launchBlock == 0, "Already enabled");
        launchBlock = block.number;
        emit TradingEnabled(block.number);
    }

    function setGasPriceLimit(uint256 _gwei) external onlyOwner {
        uint256 oldLimit = gasPriceLimit;
        gasPriceLimit = _gwei * 1 gwei;
        emit GasPriceLimitUpdated(oldLimit, gasPriceLimit);
    }

    function removeLimits() external onlyOwner {
        limitsInEffect = false;
        emit LimitsRemoved();
    }

    // ============ TAX DISTRIBUTION ============

    /// @notice Emergency function to reset taxAccumulated counter
    /// @dev Use after emergencyWithdrawToken to prevent distribution failures (Bug #18 fix)
    function resetTaxAccumulated() external onlyOwner {
        uint256 oldValue = taxAccumulated;
        taxAccumulated = 0;
        emit TaxAccumulatedReset(oldValue);
    }

    /// @notice Emergency function to reset _distributing flag if stuck
    /// @dev Bug #21 fix - flag can get stuck if _distributeTax fails mid-execution
    function resetDistributing() external onlyOwner {
        _distributing = false;
        emit DistributingReset();
    }

    event TaxAccumulatedReset(uint256 previousValue);
    event DistributingReset();

    function distributeTax() external onlyOwner {
        _distributeTax(true); // Force distribute regardless of minimum
    }

    function _distributeTax(bool force) private {
        // Re-entrancy guard - prevent distribution loops
        if (_distributing) return;
        _distributing = true;
        
        require(address(uniswapRouter) != address(0), "Router not set");
        
        // FIX: Use ACTUAL BALANCE instead of taxAccumulated counter
        // This prevents mismatch if tokens are withdrawn via emergency functions
        uint256 contractBalance = balanceOf(address(this));
        
        // Skip if nothing to distribute
        if (contractBalance == 0) {
            _distributing = false;
            return;
        }
        
        // Skip if below minimum threshold (prevents gas griefing)
        // Unless force=true (owner calling distributeTax directly)
        if (!force && contractBalance < MIN_TAX_FOR_DISTRIBUTE) {
            _distributing = false;
            return; // Accumulate more before distributing
        }

        // Cap swap amount to 10% of pool reserves to prevent revert
        uint256 taxToDistribute = contractBalance;
        
        if (wethPair != address(0)) {
            (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(wethPair).getReserves();
            // Determine which reserve is our token (token0 if address < WETH)
            uint256 tokenReserve = address(this) < uniswapRouter.WETH() 
                ? uint256(reserve0) 
                : uint256(reserve1);
            
            // Cap at MAX_SWAP_PERCENT (10%) of pool to prevent massive slippage
            uint256 maxSwap = tokenReserve / MAX_SWAP_PERCENT;
            if (taxToDistribute > maxSwap && maxSwap > 0) {
                taxToDistribute = maxSwap;
            }
        }
        
        // Update stats (taxAccumulated now just for record keeping)
        if (taxAccumulated >= taxToDistribute) {
            taxAccumulated -= taxToDistribute;
        } else {
            taxAccumulated = 0;
        }

        // Split tax: 14.60% to WWMM in TOKENS, 85.40% to Rewards in TOKENS (swap later)
        uint256 wwmmTokens = Math.mulDiv(taxToDistribute, WWMM_BPS, BPS_DIVISOR);
        uint256 rewardsTokens = taxToDistribute - wwmmTokens;

        // 1. Send WWMM share directly in TOKENS (triggers piggyback arbitrage check)
        if (wwmmTokens > 0 && wwmmWallet != address(0)) {
            _transfer(address(this), wwmmWallet, wwmmTokens);
            totalWwmmSent += wwmmTokens;
            
            // Trigger the piggyback check - WWMM will check if arb opportunity exists
            // HYBRID APPROACH: try/catch for resilience + Railway backup catches missed arbs
            // If arb fails, sell still succeeds and Railway will trigger arb within 10 seconds
            try IWWMM(wwmmWallet).onTaxReceived(wwmmTokens) {} catch {}
        }

        // 2. Send Rewards share as TOKENS (not ETH) - swap happens later via cron/manual
        // This avoids the Uniswap accounting issue where swap during transfer breaks user's swap
        if (rewardsTokens > 0 && address(rewardsContract) != address(0)) {
            _transfer(address(this), address(rewardsContract), rewardsTokens);
            totalRewardsSent += rewardsTokens; // Now tracking tokens, not ETH
        }
        
        _distributing = false;  // Reset guard
    }

    // ============ TRANSFER LOGIC ============

    function _update(address from, address to, uint256 amount) internal override {
        require(!paused, "Contract paused");

        // Anti-bot limits
        if (limitsInEffect && launchBlock > 0) {
            if (from != owner() && to != owner() && from != tokenLocker && to != tokenLocker) {
                require(tx.gasprice <= gasPriceLimit, "Gas too high");
                if (block.number <= launchBlock + 30) {
                    require(_holderLastTransferBlock[tx.origin] != block.number, "One tx/block");
                    _holderLastTransferBlock[tx.origin] = block.number;
                }
            }
        }

        // Determine if buy or sell
        bool isBuy = isUniswapPair[from] && !isUniswapPair[to];
        bool isSell = !isUniswapPair[from] && isUniswapPair[to];

        // Calculate tax
        uint256 taxAmount = 0;
        if (launchBlock > 0 && (isBuy || isSell)) {
            // Check exclusions
            if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
                taxAmount = Math.mulDiv(amount, TAX_BPS, BPS_DIVISOR);
            }
        }

        uint256 amountAfterTax = amount - taxAmount;

        // Handle tax FIRST - collect before main transfer
        if (taxAmount > 0) {
            super._update(from, address(this), taxAmount);
            
            taxAccumulated += taxAmount;
            totalTaxCollected += taxAmount;

            // Calculate split for stats
            uint256 wwmmShare = Math.mulDiv(taxAmount, WWMM_BPS, BPS_DIVISOR);
            uint256 rewardsShare = taxAmount - wwmmShare;

            emit TaxCollected(taxAmount, wwmmShare, rewardsShare, isBuy);
        }

        // Transfer after-tax amount
        super._update(from, to, amountAfterTax);

        // PIGGYBACK #1: Trigger auto-distribution on BUYS
        if (isBuy && address(rewardsContract) != address(0)) {
            try rewardsContract.distributeAuto() {} catch {}
        }

        // PIGGYBACK #2: Distribute accumulated tax on SELLS
        // Now just sends tokens (no swap) so it's safe to run during user's sell
        // This also triggers WWMM.onTaxReceived() which checks for arb opportunity
        // Re-entrancy is prevented by _distributing flag in _distributeTax()
        if (isSell && taxAccumulated > 0 && from != address(this)) {
            _distributeTax(false);
        }

        // Update tracker for normal transfers
        if (address(tokenTracker) != address(0) && from != tokenLocker && to != tokenLocker) {
            try tokenTracker.setBalance(from, balanceOf(from)) {} catch {}
            try tokenTracker.setBalance(to, balanceOf(to)) {} catch {}
        }
    }

    // ============ VIEW FUNCTIONS ============

    function getTaxStats() external view returns (
        uint256 totalTax,
        uint256 totalWwmm,
        uint256 totalRewards
    ) {
        totalTax = totalTaxCollected;
        totalWwmm = totalWwmmSent;
        totalRewards = totalRewardsSent;
    }

    function isTradingEnabled() external view returns (bool) {
        return launchBlock > 0;
    }

    function getPendingTax() external view returns (uint256) {
        return taxAccumulated;
    }

    // ============ EMERGENCY FUNCTIONS ============

    function emergencyWithdrawETH(address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH");
        payable(to).transfer(balance);
        emit EmergencyWithdraw(address(0), to, balance);
    }

    function emergencyWithdrawToken(address token, address to) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid address");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens");
        IERC20(token).transfer(to, balance);
        emit EmergencyWithdraw(token, to, balance);
    }

    // ============ EXCLUDE DEFAULT ADDRESSES ============

    function excludeDefaultAddresses(
        address _deadWallet,
        address _deployer,
        address _teamWallet,
        address _spillageWallet
    ) external onlyOwner {
        if (_deadWallet != address(0)) {
            isExcludedFromTax[_deadWallet] = true;
            emit TaxExclusionUpdated(_deadWallet, true);
        }
        if (_deployer != address(0)) {
            isExcludedFromTax[_deployer] = true;
            emit TaxExclusionUpdated(_deployer, true);
        }
        if (_teamWallet != address(0)) {
            isExcludedFromTax[_teamWallet] = true;
            emit TaxExclusionUpdated(_teamWallet, true);
        }
        if (_spillageWallet != address(0)) {
            isExcludedFromTax[_spillageWallet] = true;
            emit TaxExclusionUpdated(_spillageWallet, true);
        }
    }

    // ============ SOL MANAGEMENT ============

    function setSol(address _sol) external onlyOwner {
        require(_sol != address(0), "Invalid SOL");
        sol = _sol;
    }

    function _swapSolToEth(uint256 solAmount) internal {
        if (solAmount == 0 || sol == address(0)) return;
        
        IERC20(sol).approve(address(uniswapRouter), solAmount);
        
        address[] memory path = new address[](2);
        path[0] = sol;
        path[1] = uniswapRouter.WETH();
        
        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            solAmount,
            0, // Accept any amount
            path,
            address(this),
            block.timestamp
        ) {} catch {}
    }
}
