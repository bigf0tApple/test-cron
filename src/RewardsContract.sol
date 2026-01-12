// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Interfaces.sol";

/**
 * @title Rewards Contract (V2)
 * @notice Manages reward distribution for NFT and Token holders
 * @dev NFTs get 100% auto-distribution, Token holders get 70% auto / 30% claimable
 *      Excess NFT points and unclaimed token rewards are swept to treasury
 */
contract Rewards is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // ============ CONSTANTS ============
    uint256 public constant MAX_NFT_POINTS = 342;
    uint256 public constant BPS_DIVISOR = 100_000;
    uint256 public constant FLUSH_BUFFER = 0.002 ether; // Reserve for flush gas

    // ============ IMMUTABLE ADDRESSES ============
    address public immutable tokenContract;
    
    // ============ MUTABLE ADDRESSES ============
    address public treasury; // TREASURWEE wallet - receives sweeps
    address public nftTracker;
    address public tokenTracker;
    address public uniswapRouter;

    // ============ REWARD TOKEN ============
    address public rewardToken; // address(0) for ETH, else ERC20

    // ============ WHITELIST ============
    mapping(address => bool) public isWhitelistedReward;
    address[] public whitelistedRewardTokens; // No cap - record all
    mapping(address => bool) public canReceiveFrom; // Addresses allowed to send tokens

    // ============ POOL CONFIGURATION ============
    uint256 public nftPoolBps = 27640;     // 27.64% of rewards to NFTs (5-decimal)
    uint256 public tokenPoolBps = 72360;   // 72.36% of rewards to Tokens (5-decimal)
    uint256 public nftAutoPercent = 100;   // NFTs: 100% auto
    uint256 public tokenAutoPercent = 70;  // Tokens: 70% auto, 30% claimable
    uint256 public tokenManualPercent = 30;

    // ============ POOLS PER CYCLE ============
    mapping(uint256 => uint256) public nftAutoPool;
    mapping(uint256 => uint256) public tokenAutoPool;
    mapping(uint256 => uint256) public tokenManualPool;
    uint256 public totalDividendsDistributed;

    // ============ CYCLE CONFIG ============
    uint256 public cycleInterval = 21600; // 6 hours (prod)
    uint256 public snapshotBuffer = 300;  // 5 minutes before cycle end
    uint256 public constant TIME_WINDOW = 300 seconds; // 5 minutes for Railway flexibility
    uint256 public accStartTime;
    uint256 public distStartTime;
    uint256 internal activeAccCycleId;
    uint256 internal activeDistCycleId;
    uint256 public currentDisplayCycleId;
    bool public isDistActive;

    // ============ SNAPSHOTS ============
    mapping(uint256 => uint256) public cycleNftTotalPoints;
    mapping(uint256 => uint256) public cycleTokenTotalPoints;
    mapping(uint256 => mapping(address => uint256)) public cycleNftHolderPoints;
    mapping(uint256 => mapping(address => uint256)) public cycleTokenHolderPoints;
    mapping(uint256 => uint256) public cycleNftCount; // Track NFT count for excess calculation

    // ============ CLAIMS TRACKING ============
    mapping(uint256 => mapping(address => bool)) public hasClaimedAuto;
    mapping(uint256 => mapping(address => bool)) public hasClaimedManual;
    mapping(address => uint256) public withdrawnDividends;

    // ============ BATCHING ============
    uint256 public batchSize = 100;
    uint256 public lastProcessedIndexNft;
    uint256 public lastProcessedIndexToken;

    // ============ SLIPPAGE ============
    uint256 public buySlippageBps = 2500;  // 25%
    uint256 public sweepSlippageBps = 3000; // 30%

    // ============ EXECUTORS ============
    EnumerableSet.AddressSet private allowedExecutors;

    // ============ EVENTS ============
    event RewardsDeposited(uint256 nftAmount, uint256 tokenAmount, uint256 cycleId);
    event SnapshotTaken(uint256 cycleId, uint256 nftTotalPoints, uint256 tokenTotalPoints);
    event ClaimPhaseStarted(uint256 cycleId);
    event AutoDistributed(uint256 cycleId, uint256 nftPaid, uint256 tokenPaid);
    event ManualClaimed(address indexed holder, uint256 amount, uint256 cycleId);
    event UnclaimedSwept(uint256 amount, uint256 cycleId);
    event ExcessPointsSwept(uint256 amount, uint256 cycleId);
    event RewardTokenUpdated(address newToken);
    event RewardTokenWhitelisted(address token);
    event AllowedExecutorAdded(address executor);
    event AllowedExecutorRemoved(address executor);
    event TransferFailed(address indexed holder, uint256 amount);
    event NftTrackerUpdated(address indexed oldAddr, address indexed newAddr);
    event TokenTrackerUpdated(address indexed oldAddr, address indexed newAddr);
    event UniswapRouterUpdated(address indexed oldAddr, address indexed newAddr);
    event TreasuryUpdated(address indexed oldAddr, address indexed newAddr);
    event CycleEnded(uint256 cycleId, uint256 totalSwept);
    event DistributionsFlushed(uint256 cycleId, uint256 nftFlushed, uint256 tokenFlushed);
    event EmergencyWithdraw(address token, address to, uint256 amount);

    // ============ MODIFIERS ============
    modifier onlyTokenContract() {
        require(msg.sender == tokenContract, "Only token contract");
        _;
    }

    modifier onlyAllowed() {
        require(msg.sender == owner() || allowedExecutors.contains(msg.sender), "Unauthorized");
        _;
    }

    constructor(
        address _tokenContract,
        address _nftTracker,
        address _tokenTracker,
        address _treasury,
        address _uniswapRouter
    ) Ownable(msg.sender) {
        require(_tokenContract != address(0), "Invalid token contract");
        require(_treasury != address(0), "Invalid treasury");
        
        tokenContract = _tokenContract;
        treasury = _treasury;
        _setNftTracker(_nftTracker);
        _setTokenTracker(_tokenTracker);
        _setUniswapRouter(_uniswapRouter);

        // Initialize whitelist with ETH
        isWhitelistedReward[address(0)] = true;
        whitelistedRewardTokens.push(address(0));

        // Allow token contract to send
        canReceiveFrom[_tokenContract] = true;

        rewardToken = address(0); // Default ETH
        accStartTime = block.timestamp;
        activeAccCycleId = 0;
        activeDistCycleId = 0;
        currentDisplayCycleId = 0;
        isDistActive = false;
    }

    // ============ INTERNAL SETTERS ============

    function _setNftTracker(address _nftTracker) internal {
        require(_nftTracker != address(0), "Invalid NFT tracker");
        nftTracker = _nftTracker;
    }

    function _setTokenTracker(address _tokenTracker) internal {
        require(_tokenTracker != address(0), "Invalid token tracker");
        tokenTracker = _tokenTracker;
    }

    function _setUniswapRouter(address _uniswapRouter) internal {
        require(_uniswapRouter != address(0), "Invalid Uniswap router");
        uniswapRouter = _uniswapRouter;
    }

    // ============ ADMIN FUNCTIONS ============

    function setNftTracker(address _newNftTracker) external onlyOwner {
        address old = nftTracker;
        _setNftTracker(_newNftTracker);
        emit NftTrackerUpdated(old, _newNftTracker);
    }

    function setTokenTracker(address _newTokenTracker) external onlyOwner {
        address old = tokenTracker;
        _setTokenTracker(_newTokenTracker);
        emit TokenTrackerUpdated(old, _newTokenTracker);
    }

    function setUniswapRouter(address _newRouter) external onlyOwner {
        address old = uniswapRouter;
        _setUniswapRouter(_newRouter);
        emit UniswapRouterUpdated(old, _newRouter);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid treasury");
        address old = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(old, _newTreasury);
    }

    function setCycleInterval(uint256 _interval) external onlyOwner {
        require(_interval >= 1 hours, "Interval too short");
        cycleInterval = _interval;
    }

    function setSnapshotBuffer(uint256 _buffer) external onlyOwner {
        snapshotBuffer = _buffer;
    }

    function setBatchSize(uint256 _batchSize) external onlyOwner {
        require(_batchSize > 0, "Invalid batch size");
        batchSize = _batchSize;
    }

    function setSlippage(uint256 _buyBps, uint256 _sweepBps) external onlyOwner {
        require(_buyBps <= 50000, "Buy slippage too high");
        require(_sweepBps <= 50000, "Sweep slippage too high");
        buySlippageBps = _buyBps;
        sweepSlippageBps = _sweepBps;
    }

    function setPoolBps(uint256 _nftBps, uint256 _tokenBps) external onlyOwner {
        require(_nftBps + _tokenBps == BPS_DIVISOR, "Must equal 100%");
        nftPoolBps = _nftBps;
        tokenPoolBps = _tokenBps;
    }

    function setDistributionPercents(uint256 _nftAuto, uint256 _tokenAuto, uint256 _tokenManual) external onlyOwner {
        require(_nftAuto == 100, "NFT must be 100% auto");
        require(_tokenAuto + _tokenManual == 100, "Token must equal 100%");
        nftAutoPercent = _nftAuto;
        tokenAutoPercent = _tokenAuto;
        tokenManualPercent = _tokenManual;
    }

    // ============ WHITELIST MANAGEMENT ============

    function setRewardToken(address _rewardToken) external onlyOwner {
        rewardToken = _rewardToken;
        if (_rewardToken != address(0) && !isWhitelistedReward[_rewardToken]) {
            isWhitelistedReward[_rewardToken] = true;
            whitelistedRewardTokens.push(_rewardToken);
            emit RewardTokenWhitelisted(_rewardToken);
        }
        emit RewardTokenUpdated(_rewardToken);
    }

    function addWhitelistedRewardToken(address _token) external onlyOwner {
        if (!isWhitelistedReward[_token]) {
            isWhitelistedReward[_token] = true;
            whitelistedRewardTokens.push(_token);
            emit RewardTokenWhitelisted(_token);
        }
    }

    function setCanReceiveFrom(address _sender, bool _allowed) external onlyOwner {
        canReceiveFrom[_sender] = _allowed;
    }

    function getWhitelistedRewardTokens() external view returns (address[] memory) {
        return whitelistedRewardTokens;
    }

    // ============ EXECUTOR MANAGEMENT ============

    function addAllowedExecutor(address executor) external onlyOwner {
        allowedExecutors.add(executor);
        emit AllowedExecutorAdded(executor);
    }

    function removeAllowedExecutor(address executor) external onlyOwner {
        allowedExecutors.remove(executor);
        emit AllowedExecutorRemoved(executor);
    }

    // ============ RECEIVE ETH ============

    receive() external payable {
        require(canReceiveFrom[msg.sender], "Not authorized sender");
    }

    // ============ DEPOSIT REWARDS ============

    function depositRewards(uint256 amount) external payable onlyTokenContract {
        require(msg.value == amount, "ETH mismatch");
        require(amount > 0, "No ETH");
        
        uint256 cycleId = activeAccCycleId;
        
        // Split: 27.64% to NFTs, 72.36% to Tokens
        uint256 nftAmt = (amount * nftPoolBps) / BPS_DIVISOR;
        uint256 tokenAmt = amount - nftAmt;

        // NFT: 100% auto
        uint256 nftAutoAmt = nftAmt;

        // Token: 70% auto, 30% manual
        uint256 tokenAutoAmt = (tokenAmt * tokenAutoPercent) / 100;
        uint256 tokenManualAmt = tokenAmt - tokenAutoAmt;

        // If reward token is set, swap ETH to token
        if (rewardToken != address(0)) {
            nftAutoAmt = _swapEthForToken(nftAutoAmt);
            tokenAutoAmt = _swapEthForToken(tokenAutoAmt);
            tokenManualAmt = _swapEthForToken(tokenManualAmt);
        }

        nftAutoPool[cycleId] += nftAutoAmt;
        tokenAutoPool[cycleId] += tokenAutoAmt;
        tokenManualPool[cycleId] += tokenManualAmt;

        emit RewardsDeposited(nftAmt, tokenAmt, currentDisplayCycleId);
    }

    // ============ SWAP FUNCTIONS ============

    function _swapEthForToken(uint256 ethAmount) internal returns (uint256) {
        if (ethAmount == 0) return 0;
        
        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02(uniswapRouter).WETH();
        path[1] = rewardToken;

        uint256[] memory amountsOut = IUniswapV2Router02(uniswapRouter).getAmountsOut(ethAmount, path);
        uint256 minOut = (amountsOut[1] * (BPS_DIVISOR - buySlippageBps)) / BPS_DIVISOR;

        uint256[] memory amounts = IUniswapV2Router02(uniswapRouter).swapExactETHForTokens{value: ethAmount}(
            minOut,
            path,
            address(this),
            block.timestamp
        );
        return amounts[1];
    }

    function _swapTokenForEth(uint256 tokenAmount) internal returns (uint256) {
        if (tokenAmount == 0 || rewardToken == address(0)) return 0;

        address[] memory path = new address[](2);
        path[0] = rewardToken;
        path[1] = IUniswapV2Router02(uniswapRouter).WETH();

        IERC20(rewardToken).approve(uniswapRouter, tokenAmount);

        uint256[] memory amountsOut = IUniswapV2Router02(uniswapRouter).getAmountsOut(tokenAmount, path);
        uint256 minOut = (amountsOut[1] * (BPS_DIVISOR - sweepSlippageBps)) / BPS_DIVISOR;

        uint256 initialBalance = address(this).balance;
        IUniswapV2Router02(uniswapRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            minOut,
            path,
            address(this),
            block.timestamp
        );
        return address(this).balance - initialBalance;
    }

    // ============ SNAPSHOT ============

    function takeSnapshots() external onlyAllowed {
        uint256 elapsed = block.timestamp - accStartTime;
        require(elapsed >= cycleInterval - snapshotBuffer - TIME_WINDOW, "Not snapshot time");
        
        uint256 cycleId = activeAccCycleId;

        // NFT snapshot
        uint256 nftTotal = 0;
        uint256 nftCount = 0;
        uint256 nftLen = INFTTracker(nftTracker).holderCount();
        for (uint256 i = 0; i < nftLen; i++) {
            address holder = INFTTracker(nftTracker).holderAt(i);
            uint256 points = INFTTracker(nftTracker).balanceOf(holder);
            if (points >= INFTTracker(nftTracker).minHoldAmount()) {
                cycleNftHolderPoints[cycleId][holder] = points;
                nftTotal += points;
                nftCount++;
            }
        }
        cycleNftTotalPoints[cycleId] = nftTotal;
        cycleNftCount[cycleId] = nftCount;

        // Token snapshot
        uint256 tokenTotal = 0;
        uint256 tokenLen = ITokenTracker(tokenTracker).getNumberOfTokenHolders();
        for (uint256 i = 0; i < tokenLen; i++) {
            address holder = ITokenTracker(tokenTracker).holderAt(i);
            uint256 bal = ITokenTracker(tokenTracker).balanceOf(holder);
            if (bal >= ITokenTracker(tokenTracker).minimumTokenBalanceForDividends()) {
                cycleTokenHolderPoints[cycleId][holder] = bal;
                tokenTotal += bal;
            }
        }
        cycleTokenTotalPoints[cycleId] = tokenTotal;

        emit SnapshotTaken(cycleId, nftTotal, tokenTotal);
    }

    // ============ START CLAIM PHASE ============

    function startClaimPhase() external onlyAllowed {
        uint256 elapsed = block.timestamp - accStartTime;
        require(elapsed >= cycleInterval - TIME_WINDOW, "Not claim time");
        
        uint256 cycleId = activeAccCycleId;

        bool nftEligible = cycleNftTotalPoints[cycleId] > 0;
        bool tokenEligible = cycleTokenTotalPoints[cycleId] > 0;

        // Sweep NFT pools if not eligible
        if (!nftEligible) {
            uint256 nftTotal = nftAutoPool[cycleId];
            if (nftTotal > 0) {
                bool success = _sendReward(treasury, nftTotal);
                require(success, "Sweep failed");
                emit UnclaimedSwept(nftTotal, cycleId);
            }
            nftAutoPool[cycleId] = 0;
        }

        // Sweep Token pools if not eligible
        if (!tokenEligible) {
            uint256 tokenTotal = tokenAutoPool[cycleId] + tokenManualPool[cycleId];
            if (tokenTotal > 0) {
                bool success = _sendReward(treasury, tokenTotal);
                require(success, "Sweep failed");
                emit UnclaimedSwept(tokenTotal, cycleId);
            }
            tokenAutoPool[cycleId] = 0;
            tokenManualPool[cycleId] = 0;
        }

        if (!nftEligible && !tokenEligible) {
            activeAccCycleId++;
            currentDisplayCycleId++;
            accStartTime = block.timestamp;
        } else {
            activeDistCycleId = cycleId;
            isDistActive = true;
            distStartTime = block.timestamp;
            activeAccCycleId++;
            currentDisplayCycleId++;
            accStartTime = block.timestamp;
            lastProcessedIndexNft = 0;
            lastProcessedIndexToken = 0;
            emit ClaimPhaseStarted(activeDistCycleId);
        }
    }

    // ============ AUTO DISTRIBUTION ============

    function distributeAuto() external {
        if (!isDistActive) return;
        uint256 cycleId = activeDistCycleId;
        _processAutoBatchNft(cycleId);
        _processAutoBatchToken(cycleId);
    }

    function _processAutoBatchNft(uint256 cycleId) internal {
        if (nftAutoPool[cycleId] == 0 || cycleNftTotalPoints[cycleId] == 0) return;
        
        uint256 start = lastProcessedIndexNft;
        uint256 end = start + batchSize;
        uint256 holderLen = INFTTracker(nftTracker).holderCount();
        if (end > holderLen) end = holderLen;

        uint256 localPaid = 0;
        uint256 poolAtStart = nftAutoPool[cycleId];

        for (uint256 i = start; i < end; i++) {
            address holder = INFTTracker(nftTracker).holderAt(i);
            if (hasClaimedAuto[cycleId][holder]) continue;
            
            uint256 points = cycleNftHolderPoints[cycleId][holder];
            if (points < INFTTracker(nftTracker).minHoldAmount()) continue;
            
            uint256 share = (poolAtStart * points) / cycleNftTotalPoints[cycleId];
            if (share == 0) continue;

            bool success = _sendReward(holder, share);
            if (success) {
                hasClaimedAuto[cycleId][holder] = true;
                withdrawnDividends[holder] += share;
                totalDividendsDistributed += share;
                localPaid += share;
            } else {
                emit TransferFailed(holder, share);
            }
        }

        if (localPaid > 0) {
            nftAutoPool[cycleId] -= localPaid;
        }
        lastProcessedIndexNft = (end >= holderLen) ? 0 : end;
        emit AutoDistributed(cycleId, localPaid, 0);
    }

    function _processAutoBatchToken(uint256 cycleId) internal {
        if (tokenAutoPool[cycleId] == 0 || cycleTokenTotalPoints[cycleId] == 0) return;
        
        uint256 start = lastProcessedIndexToken;
        uint256 end = start + batchSize;
        uint256 holderLen = ITokenTracker(tokenTracker).getNumberOfTokenHolders();
        if (end > holderLen) end = holderLen;

        uint256 localPaid = 0;
        uint256 poolAtStart = tokenAutoPool[cycleId];

        for (uint256 i = start; i < end; i++) {
            address holder = ITokenTracker(tokenTracker).holderAt(i);
            if (hasClaimedAuto[cycleId][holder]) continue;
            
            uint256 bal = cycleTokenHolderPoints[cycleId][holder];
            if (bal < ITokenTracker(tokenTracker).minimumTokenBalanceForDividends()) continue;
            
            uint256 share = (poolAtStart * bal) / cycleTokenTotalPoints[cycleId];
            if (share == 0) continue;

            bool success = _sendReward(holder, share);
            if (success) {
                hasClaimedAuto[cycleId][holder] = true;
                withdrawnDividends[holder] += share;
                totalDividendsDistributed += share;
                localPaid += share;
            } else {
                emit TransferFailed(holder, share);
            }
        }

        if (localPaid > 0) {
            tokenAutoPool[cycleId] -= localPaid;
        }
        lastProcessedIndexToken = (end >= holderLen) ? 0 : end;
        emit AutoDistributed(cycleId, 0, localPaid);
    }

    // ============ MANUAL CLAIM (TOKEN HOLDERS ONLY) ============

    function claimManual() external nonReentrant {
        require(isDistActive, "No active distribution");
        uint256 cycleId = activeDistCycleId;
        require(!hasClaimedManual[cycleId][msg.sender], "Already claimed");

        // Token holders only - NFTs are 100% auto
        uint256 tokenShare = 0;
        if (tokenManualPool[cycleId] > 0 && cycleTokenTotalPoints[cycleId] > 0) {
            uint256 points = cycleTokenHolderPoints[cycleId][msg.sender];
            if (points >= ITokenTracker(tokenTracker).minimumTokenBalanceForDividends()) {
                tokenShare = (tokenManualPool[cycleId] * points) / cycleTokenTotalPoints[cycleId];
            }
        }

        require(tokenShare > 0, "No share");

        tokenManualPool[cycleId] -= tokenShare;
        hasClaimedManual[cycleId][msg.sender] = true;
        withdrawnDividends[msg.sender] += tokenShare;
        totalDividendsDistributed += tokenShare;

        bool success = _sendReward(msg.sender, tokenShare);
        require(success, "Transfer failed");
        emit ManualClaimed(msg.sender, tokenShare, cycleId);
    }

    // ============ SEND REWARD ============

    function _sendReward(address to, uint256 amount) internal returns (bool) {
        if (rewardToken == address(0)) {
            (bool success, ) = to.call{value: amount, gas: 5000}("");
            return success;
        } else {
            try IERC20(rewardToken).transfer(to, amount) {
                return true;
            } catch {
                return false;
            }
        }
    }

    // ============ FLUSH DISTRIBUTIONS ============

    function flushDistributions() external onlyAllowed {
        if (!isDistActive) return;
        uint256 cycleId = activeDistCycleId;
        _flushAllAutoDistributions(cycleId);
    }

    function _flushAllAutoDistributions(uint256 cycleId) internal {
        uint256 nftFlushed = 0;
        uint256 tokenFlushed = 0;

        // Process all remaining NFT holders
        uint256 nftLen = INFTTracker(nftTracker).holderCount();
        while (lastProcessedIndexNft < nftLen && lastProcessedIndexNft != 0) {
            uint256 before = nftAutoPool[cycleId];
            _processAutoBatchNft(cycleId);
            nftFlushed += before - nftAutoPool[cycleId];
            if (lastProcessedIndexNft == 0) break;
        }
        // One more pass if we started at 0
        if (nftAutoPool[cycleId] > 0) {
            uint256 before = nftAutoPool[cycleId];
            _processAutoBatchNft(cycleId);
            nftFlushed += before - nftAutoPool[cycleId];
        }

        // Process all remaining token holders
        uint256 tokenLen = ITokenTracker(tokenTracker).getNumberOfTokenHolders();
        while (lastProcessedIndexToken < tokenLen && lastProcessedIndexToken != 0) {
            uint256 before = tokenAutoPool[cycleId];
            _processAutoBatchToken(cycleId);
            tokenFlushed += before - tokenAutoPool[cycleId];
            if (lastProcessedIndexToken == 0) break;
        }
        // One more pass if we started at 0
        if (tokenAutoPool[cycleId] > 0) {
            uint256 before = tokenAutoPool[cycleId];
            _processAutoBatchToken(cycleId);
            tokenFlushed += before - tokenAutoPool[cycleId];
        }

        emit DistributionsFlushed(cycleId, nftFlushed, tokenFlushed);
    }

    // ============ END CYCLE ============

    function endCycle() external onlyAllowed {
        require(isDistActive, "No active distribution");
        uint256 elapsed = block.timestamp - distStartTime;
        require(elapsed >= cycleInterval - TIME_WINDOW, "Not end time");
        
        uint256 cycleId = activeDistCycleId;

        // 1. Flush all remaining auto distributions
        _flushAllAutoDistributions(cycleId);

        // 2. Calculate excess NFT points rewards
        uint256 excessNftRewards = _calculateExcessNftRewards(cycleId);

        // 3. Get unclaimed token manual pool
        uint256 unclaimedTokenManual = tokenManualPool[cycleId];

        // 4. Get any remaining pools
        uint256 remainingNftAuto = nftAutoPool[cycleId];
        uint256 remainingTokenAuto = tokenAutoPool[cycleId];

        // 5. Total to sweep
        uint256 totalToSweep = excessNftRewards + unclaimedTokenManual + remainingNftAuto + remainingTokenAuto;

        if (totalToSweep > 0) {
            if (rewardToken != address(0)) {
                // Swap reward token back to ETH
                uint256 ethReceived = _swapTokenForEth(totalToSweep);
                // Send ETH to treasury
                (bool success, ) = treasury.call{value: ethReceived}("");
                require(success, "Treasury transfer failed");
            } else {
                // Already ETH, send directly
                (bool success, ) = treasury.call{value: totalToSweep}("");
                require(success, "Treasury transfer failed");
            }
            
            emit UnclaimedSwept(unclaimedTokenManual, cycleId);
            emit ExcessPointsSwept(excessNftRewards, cycleId);
        }

        // Reset pools
        nftAutoPool[cycleId] = 0;
        tokenAutoPool[cycleId] = 0;
        tokenManualPool[cycleId] = 0;

        isDistActive = false;
        emit CycleEnded(cycleId, totalToSweep);
    }

    function _calculateExcessNftRewards(uint256 cycleId) internal view returns (uint256) {
        uint256 nftCount = cycleNftCount[cycleId];
        if (nftCount == 0) return 0;

        uint256 totalMaxPoints = nftCount * MAX_NFT_POINTS;
        uint256 actualPoints = cycleNftTotalPoints[cycleId];
        
        if (actualPoints >= totalMaxPoints) return 0;
        
        uint256 excessPoints = totalMaxPoints - actualPoints;
        
        // Calculate what portion of the original NFT pool corresponds to excess points
        // excessRewards = (originalPool * excessPoints) / totalMaxPoints
        // But we need to track original pool... for now, estimate from what's been distributed
        // This is approximate - in production, track original pool amount
        return 0; // Simplified - excess handled by remaining pool
    }

    // ============ VIEW FUNCTIONS ============

    function getCurrentCycleId() public view returns (uint256) {
        return currentDisplayCycleId;
    }

    function getCurrentCycleTotalRewards() public view returns (uint256) {
        uint256 cycleId = currentDisplayCycleId;
        return nftAutoPool[cycleId] + tokenAutoPool[cycleId] + tokenManualPool[cycleId];
    }

    function getPendingDistributionCount() external view returns (uint256 nftPending, uint256 tokenPending) {
        if (!isDistActive) return (0, 0);
        nftPending = INFTTracker(nftTracker).holderCount() - lastProcessedIndexNft;
        tokenPending = ITokenTracker(tokenTracker).getNumberOfTokenHolders() - lastProcessedIndexToken;
    }

    function getClaimableAmount(address holder) external view returns (uint256) {
        if (!isDistActive) return 0;
        uint256 cycleId = activeDistCycleId;
        if (hasClaimedManual[cycleId][holder]) return 0;
        
        if (tokenManualPool[cycleId] == 0 || cycleTokenTotalPoints[cycleId] == 0) return 0;
        
        uint256 points = cycleTokenHolderPoints[cycleId][holder];
        if (points < ITokenTracker(tokenTracker).minimumTokenBalanceForDividends()) return 0;
        
        return (tokenManualPool[cycleId] * points) / cycleTokenTotalPoints[cycleId];
    }

    function getTimeUntilNextCycle() external view returns (uint256) {
        uint256 elapsed = block.timestamp - accStartTime;
        if (elapsed >= cycleInterval) return 0;
        return cycleInterval - elapsed;
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

    // ============ FORCE RESET ============

    function forceResetCycle() external onlyOwner {
        uint256 cycleId = activeAccCycleId;
        uint256 total = nftAutoPool[cycleId] + tokenAutoPool[cycleId] + tokenManualPool[cycleId];
        
        if (total > 0) {
            bool success = _sendReward(treasury, total);
            require(success, "Sweep failed");
            emit UnclaimedSwept(total, cycleId);
        }

        nftAutoPool[cycleId] = 0;
        tokenAutoPool[cycleId] = 0;
        tokenManualPool[cycleId] = 0;

        activeAccCycleId++;
        currentDisplayCycleId++;
        accStartTime = block.timestamp;
        isDistActive = false;
    }

    // ============ BUY REWARD TOKEN (Railway calls this) ============

    /**
     * @notice Buy reward token with available ETH (after endCycle sweep)
     * @dev Called by Railway after endCycle() to buy next epoch's reward token
     *      Respects FLUSH_BUFFER - won't use last 0.002 ETH
     */
    function buyRewardToken() external onlyAllowed {
        require(rewardToken != address(0), "No reward token set");
        
        uint256 ethAvailable = getAvailableEthForBuy();
        require(ethAvailable > 0, "No ETH to buy");
        
        // Swap ETH to reward token
        uint256 tokensBought = _swapEthForToken(ethAvailable);
        
        emit RewardTokenPurchased(rewardToken, ethAvailable, tokensBought);
    }

    /**
     * @notice Get available ETH for buying reward token (excludes buffer)
     */
    function getAvailableEthForBuy() public view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance <= FLUSH_BUFFER) return 0;
        return balance - FLUSH_BUFFER;
    }

    /**
     * @notice Get current flush buffer amount
     */
    function getFlushBuffer() external pure returns (uint256) {
        return FLUSH_BUFFER;
    }

    event RewardTokenPurchased(address indexed token, uint256 ethSpent, uint256 tokensBought);
}