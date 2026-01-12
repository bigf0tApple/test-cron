// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./Interfaces.sol";

/**
 * @title MainToken (V2 Compatible)
 * @notice ERC20 token with 1.618% tax on buys/sells via Uniswap V2
 * @dev Tax is split: 14.60% to WWMM wallet, 85.40% to RewardsContract
 */
contract MainToken is ERC20, Ownable, ReentrancyGuard {
    using Math for uint256;

    // ============ TAX CONFIGURATION ============
    // 5-decimal basis points for precise 1.618% tax
    uint256 public constant TAX_BPS = 1618;           // 1.618%
    uint256 public constant BPS_DIVISOR = 100_000;    // 5-decimal precision
    uint256 public constant WWMM_BPS = 14600;         // 14.60% of tax to WWMM
    uint256 public constant REWARDS_BPS = 85400;      // 85.40% of tax to Rewards

    // ============ ADDRESSES ============
    address payable public wwmmWallet;
    ITokenTracker public tokenTracker;
    IRewards public rewardsContract;
    address public tokenLocker;

    IUniswapV2Router02 public uniswapRouter;
    uint256 public taxAccumulated;

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

    constructor(
        address _wwmmWallet,
        uint256 initialSupply
    ) ERC20("66Mtest", "66MT") Ownable(msg.sender) {
        require(_wwmmWallet != address(0), "Invalid WWMM wallet");
        wwmmWallet = payable(_wwmmWallet);

        uint256 total = initialSupply;
        
        // Allocation: 33.62% presale/airdrop, 28.18% LP, 38.20% team
        uint256 presaleAirdrop = Math.mulDiv(total, 3362, 10000);  // 336.2M
        uint256 lp = Math.mulDiv(total, 2818, 10000);              // 281.8M
        uint256 team = Math.mulDiv(total, 3820, 10000);            // 382.0M

        // Mint presale and LP tokens directly to deployer
        _mint(msg.sender, presaleAirdrop + lp);
        // Mint team tokens to contract for later transfer to locker
        _mint(address(this), team);

        // Exclude deployer and contract from tax
        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
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
        wwmmWallet = _wallet;
    }

    function setTokenTracker(address _tracker) external onlyOwner {
        require(_tracker != address(0), "Invalid tracker");
        tokenTracker = ITokenTracker(_tracker);
        isExcludedFromTax[_tracker] = true;
    }

    function setRewardsContract(address _rewards) external onlyOwner {
        require(_rewards != address(0), "Invalid rewards");
        rewardsContract = IRewards(_rewards);
        isExcludedFromTax[_rewards] = true;
    }

    function setTokenLocker(address _locker) external onlyOwner {
        require(tokenLocker == address(0), "Locker already set");
        require(_locker != address(0), "Invalid locker");
        tokenLocker = _locker;
        isExcludedFromTax[_locker] = true;
        
        // Transfer team tokens to locker
        uint256 teamAmount = (totalSupply() * 3820) / 10000;
        _transfer(address(this), _locker, teamAmount);
        emit TokenLockerSet(_locker, teamAmount);
    }

    function setUniswapRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        uniswapRouter = IUniswapV2Router02(_router);
        isExcludedFromTax[_router] = true;
    }

    function setIsUniswapPair(address _pair, bool _isPair) external onlyOwner {
        require(_pair != address(0), "Invalid pair");
        isUniswapPair[_pair] = _isPair;
        emit PairUpdated(_pair, _isPair);
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
        gasPriceLimit = _gwei * 1 gwei;
    }

    function removeLimits() external onlyOwner {
        limitsInEffect = false;
    }

    // ============ TAX DISTRIBUTION ============

    function distributeTax() external onlyOwner {
        _distributeTax();
    }

    function _distributeTax() private {
        require(address(uniswapRouter) != address(0), "Router not set");
        require(taxAccumulated > 0, "No tax to distribute");

        // First, swap any SOL to ETH (if received from SOL/TOKEN pair)
        uint256 solBalance = IERC20(sol).balanceOf(address(this));
        if (solBalance > 0) {
            _swapSolToEth(solBalance);
        }

        uint256 taxToDistribute = taxAccumulated;
        taxAccumulated = 0;

        // Approve router to spend tax tokens
        _approve(address(this), address(uniswapRouter), taxToDistribute);

        // Swap tokens for ETH
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        uint256 initialEthBalance = address(this).balance;
        
        // Note: Using 0 for minAmountOut because:
        // 1. V2 swaps are atomic (no MEV sandwich risk)
        // 2. getAmountsOut doesn't account for supportingFeeOnTransfer deductions
        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            taxToDistribute,
            0, // Accept any amount - V2 atomic swap
            path,
            address(this),
            block.timestamp
        ) {
            uint256 ethReceived = address(this).balance - initialEthBalance;

            // Split ETH: 14.60% to WWMM, 85.40% to Rewards
            uint256 wwmmEth = Math.mulDiv(ethReceived, WWMM_BPS, BPS_DIVISOR);
            uint256 rewardsEth = ethReceived - wwmmEth;

            if (wwmmEth > 0) {
                (bool wwmmSuccess, ) = wwmmWallet.call{value: wwmmEth}("");
                require(wwmmSuccess, "WWMM transfer failed");
                totalWwmmSent += wwmmEth;
            }

            if (rewardsEth > 0 && address(rewardsContract) != address(0)) {
                (bool rewardsSuccess, ) = payable(address(rewardsContract)).call{value: rewardsEth}("");
                require(rewardsSuccess, "Rewards transfer failed");
                totalRewardsSent += rewardsEth;
            }
        } catch {
            // If swap fails, add back to accumulated
            taxAccumulated = taxToDistribute;
        }
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

        // Transfer after-tax amount
        super._update(from, to, amountAfterTax);

        // Handle tax
        if (taxAmount > 0) {
            super._update(from, address(this), taxAmount);
            
            taxAccumulated += taxAmount;
            totalTaxCollected += taxAmount;

            // Calculate split for stats
            uint256 wwmmShare = Math.mulDiv(taxAmount, WWMM_BPS, BPS_DIVISOR);
            uint256 rewardsShare = taxAmount - wwmmShare;

            emit TaxCollected(taxAmount, wwmmShare, rewardsShare, isBuy);
        }

        // PIGGYBACK #1: Distribute accumulated tax on BUYS
        // (Sells accumulate tax, buys trigger distribution)
        if (isBuy && taxAccumulated > 0) {
            _distributeTax();
        }

        // PIGGYBACK #2: Trigger auto-distribution on SELLS
        if (isSell && address(rewardsContract) != address(0)) {
            try rewardsContract.distributeAuto() {} catch {}
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
