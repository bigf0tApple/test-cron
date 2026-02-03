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
contract RewardsContract is Ownable, ReentrancyGuard {
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

    // ============ ETH POOLS (During Accumulation) ============
    // These track ETH amounts during the accumulation phase
    mapping(uint256 => uint256) public nftEthPool;
    mapping(uint256 => uint256) public tokenAutoEthPool;
    mapping(uint256 => uint256) public tokenManualEthPool;
    
    // ============ TOKEN POOLS (During Distribution) ============
    // These track reward token amounts after conversion at epoch end
    mapping(uint256 => uint256) public nftAutoPool;
    mapping(uint256 => uint256) public tokenAutoPool;
    mapping(uint256 => uint256) public tokenManualPool;
    uint256 public totalDividendsDistributed;
    
    // Track which epoch is currently distributing (not accumulating)
    uint256 public activeDistEpoch;

    // ============ CYCLE CONFIG ============
    // TIMING SYNC: Railway runs hourly, epochs start exactly at 6h mark
    // - cycleInterval: MINIMUM wait between epochs (floor, not ceiling)
    // - Railway calls batchStartEpoch() every hour, contract rejects if < 6h elapsed
    // - For best sync: start epochs at 00:00, 06:00, 12:00, 18:00 UTC
    uint256 public cycleInterval = 21600; // 6 hours
    uint256 public snapshotBuffer = 0;    // DEPRECATED: was for early snapshots, now unused
    uint256 public constant TIME_WINDOW = 600 seconds; // 10 minutes flexibility for batching
    uint256 public accStartTime;   // When current accumulation cycle started
    uint256 public distStartTime;  // When current distribution started
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
    mapping(uint256 => uint256) public cycleAccumulatedEth; // Track ETH accumulated per cycle for isolation
    mapping(uint256 => uint256) public cycleSnapshotBlock; // M-16: Track when snapshot was taken

    // ============ CLAIMS TRACKING ============
    mapping(uint256 => mapping(address => bool)) public hasClaimedAuto;
    mapping(uint256 => mapping(address => bool)) public hasClaimedManual;
    mapping(address => uint256) public withdrawnDividends;

    // ============ BATCHING ============
    uint256 public snapshotBatchSize = 4000;  // Holders per snapshot batch
    uint256 public distributeBatchSize = 100; // Holders per distribute batch
    
    // Snapshot progress tracking
    uint256 public snapshotProgressNft;
    uint256 public snapshotProgressToken;
    bool public nftSnapshotDone;
    bool public tokenSnapshotDone;
    // LOCKED holder counts at snapshot start (prevents infinite loop from new holders)
    uint256 public snapshotNftLen;
    uint256 public snapshotTokenLen;
    
    // Distribution progress tracking
    uint256 public lastProcessedIndexNft;
    uint256 public lastProcessedIndexToken;

    // ============ SLIPPAGE ============
    // Base L2 has centralized sequencer - MEV protected
    uint256 public buySlippageBps = 250;   // 2.5% (for buying reward tokens)
    uint256 public sweepSlippageBps = 250; // 2.5% (for swapping VAULT→ETH)
    

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

    function setBatchSize(uint256 _distributeBatchSize) external onlyOwner {
        require(_distributeBatchSize > 0, "Invalid batch size");
        distributeBatchSize = _distributeBatchSize;
    }

    function setSlippage(uint256 _buyBps, uint256 _sweepBps) external onlyOwner {
        require(_buyBps <= 50000, "Buy slippage too high");
        require(_sweepBps <= 50000, "Sweep slippage too high");
        buySlippageBps = _buyBps;
        sweepSlippageBps = _sweepBps;
    }
    
    // Removed: setMinSwapThreshold - MainToken now swaps and sends ETH directly

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

    // ============ SWAP TOKENS TO ETH ============
    
    // REMOVED: swapTokensToETH() and _swapTokensToETHInternal()
    // MainToken V2 now swaps tokens→ETH inline during sells and sends ETH directly
    // to this contract via receive()

    // ============ RECEIVE ETH (from MainToken V2) ============

    receive() external payable {
        // Accept ETH from:
        // - Owner (funding for testing/buffer)
        // - MainToken (tax swap proceeds)
        // - Authorized senders
        require(
            msg.sender == owner() || canReceiveFrom[msg.sender] || msg.sender == tokenContract,
            "Not authorized sender"
        );
        
        // Track ETH per-cycle for isolation (prevents mixing between epochs)
        uint256 amount = msg.value;
        cycleAccumulatedEth[activeAccCycleId] += amount;
        
        // Split into pools: 27.64% to NFTs, 72.36% to Tokens
        uint256 nftAmt = (amount * nftPoolBps) / BPS_DIVISOR;
        uint256 tokenAmt = amount - nftAmt;
        uint256 tokenAutoAmt = (tokenAmt * tokenAutoPercent) / 100;
        uint256 tokenManualAmt = tokenAmt - tokenAutoAmt;
        
        nftEthPool[activeAccCycleId] += nftAmt;
        tokenAutoEthPool[activeAccCycleId] += tokenAutoAmt;
        tokenManualEthPool[activeAccCycleId] += tokenManualAmt;
        
        emit RewardsDeposited(nftAmt, tokenAmt, activeAccCycleId);
    }

    // ============ DEPOSIT REWARDS ============

    /**
     * @notice Receive ETH from MainToken tax and store for later conversion
     * @dev ETH is stored in ETH pools during accumulation phase.
     *      At epoch end, buyRewardToken() converts ALL ETH to tokens.
     */
    function depositRewards(uint256 amount) external payable onlyTokenContract {
        require(msg.value == amount, "ETH mismatch");
        require(amount > 0, "No ETH");
        
        uint256 cycleId = activeAccCycleId;
        
        // Track total ETH per-cycle for isolation
        cycleAccumulatedEth[cycleId] += amount;
        
        // Split: 27.64% to NFTs, 72.36% to Tokens
        uint256 nftAmt = (amount * nftPoolBps) / BPS_DIVISOR;
        uint256 tokenAmt = amount - nftAmt;

        // NFT: 100% auto
        uint256 nftAutoAmt = nftAmt;

        // Token: 70% auto, 30% manual
        uint256 tokenAutoAmt = (tokenAmt * tokenAutoPercent) / 100;
        uint256 tokenManualAmt = tokenAmt - tokenAutoAmt;

        // Store ETH amounts (NO SWAPPING - conversion happens at epoch end)
        nftEthPool[cycleId] += nftAutoAmt;
        tokenAutoEthPool[cycleId] += tokenAutoAmt;
        tokenManualEthPool[cycleId] += tokenManualAmt;

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

    /**
     * @notice DEPRECATED - Use batchStartEpoch() instead
     * @dev This function previously had unbounded loops that could hit gas limit
     */
    function takeSnapshots() external view onlyAllowed {
        revert("Deprecated: Use batchStartEpoch()");
    }

    // ============ START CLAIM PHASE ============

    function startClaimPhase() external onlyAllowed {
        uint256 elapsed = block.timestamp - accStartTime;
        require(elapsed >= cycleInterval, "Cycle not complete");
        
        uint256 cycleId = activeAccCycleId;
        
        // M-16: Require snapshot was taken in same block to prevent manipulation
        require(cycleSnapshotBlock[cycleId] == block.number, "Must snapshot same block");

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

    /**
     * @notice Distribute rewards to holders (called on buys/sells via piggyback)
     * @dev Uses activeDistEpoch to determine which epoch's tokens to distribute
     */
    function distributeAuto() external nonReentrant {
        uint256 cycleId = activeDistEpoch;
        // If no tokens in pools, nothing to distribute
        if (nftAutoPool[cycleId] == 0 && tokenAutoPool[cycleId] == 0) return;
        
        _processAutoBatchNft(cycleId);
        _processAutoBatchToken(cycleId);
    }

    function _processAutoBatchNft(uint256 cycleId) internal {
        if (nftAutoPool[cycleId] == 0 || cycleNftTotalPoints[cycleId] == 0) return;
        
        uint256 start = lastProcessedIndexNft;
        uint256 end = start + distributeBatchSize;
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
            // Safe subtraction - protect against dust underflow
            if (localPaid >= nftAutoPool[cycleId]) {
                nftAutoPool[cycleId] = 0;
            } else {
                nftAutoPool[cycleId] -= localPaid;
            }
        }
        lastProcessedIndexNft = (end >= holderLen) ? 0 : end;
        emit AutoDistributed(cycleId, localPaid, 0);
    }

    function _processAutoBatchToken(uint256 cycleId) internal {
        if (tokenAutoPool[cycleId] == 0 || cycleTokenTotalPoints[cycleId] == 0) return;
        
        uint256 start = lastProcessedIndexToken;
        uint256 end = start + distributeBatchSize;
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
            // Safe subtraction - protect against dust underflow
            if (localPaid >= tokenAutoPool[cycleId]) {
                tokenAutoPool[cycleId] = 0;
            } else {
                tokenAutoPool[cycleId] -= localPaid;
            }
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

        // Safe subtraction - protect against dust underflow
        if (tokenShare >= tokenManualPool[cycleId]) {
            tokenManualPool[cycleId] = 0;
        } else {
            tokenManualPool[cycleId] -= tokenShare;
        }
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
            // H-9: Increased gas from 5000 to 50000 for contract wallets (multisigs, etc.)
            (bool success, ) = to.call{value: amount, gas: 50000}("");
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
        require(elapsed >= cycleInterval, "Cycle not complete");
        
        uint256 cycleId = activeDistCycleId;

        // 1. Flush all remaining auto distributions
        _flushAllAutoDistributions(cycleId);

        // 2. Calculate excess NFT points rewards
        uint256 excessNftRewards = _calculateExcessNftRewards(cycleId);

        // 3. Get unclaimed token manual pool
        uint256 unclaimedTokenManual = tokenManualPool[cycleId];

        // 4. Only sweep excessNftRewards and unclaimedTokenManual to treasury
        //    Auto pools (nftAutoPool, tokenAutoPool) are already flushed above - 
        //    any remaining stays in contract for next cycle or rounding protection
        uint256 totalToSweep = excessNftRewards + unclaimedTokenManual;

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

        // Reset only the manual pool (auto pools were already flushed/distributed)
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
     * @notice Convert accumulated ETH to reward tokens and fill distribution pools
     * @dev Called by Railway at epoch end. Takes ALL ETH from current epoch's
     *      ETH pools, does ONE bulk swap to reward tokens, then fills the token
     *      pools proportionally for distribution.
     *      
     *      Flow:
     *      1. Sum all ETH pools for current cycle
     *      2. Swap ETH to reward tokens (one bulk transaction)
     *      3. Distribute tokens proportionally to nftAutoPool, tokenAutoPool, tokenManualPool
     *      4. Set this epoch as the distributing epoch
     */
    function buyRewardToken() external onlyAllowed {
        require(rewardToken != address(0), "No reward token set");
        
        uint256 cycleId = activeAccCycleId;
        
        // Get ETH amounts from each pool
        uint256 nftEth = nftEthPool[cycleId];
        uint256 tokenAutoEth = tokenAutoEthPool[cycleId];
        uint256 tokenManualEth = tokenManualEthPool[cycleId];
        uint256 totalEth = nftEth + tokenAutoEth + tokenManualEth;
        
        require(totalEth > FLUSH_BUFFER, "No ETH for this cycle");
        
        // Keep FLUSH_BUFFER in the contract, use the rest
        uint256 ethToBuy = totalEth - FLUSH_BUFFER;
        
        // Clear ETH pools
        nftEthPool[cycleId] = 0;
        tokenAutoEthPool[cycleId] = 0;
        tokenManualEthPool[cycleId] = 0;
        
        // Bulk swap ALL accumulated ETH to reward tokens
        uint256 tokensBought = _swapEthForToken(ethToBuy);
        
        // Distribute tokens proportionally based on original ETH splits
        // (accounting for the buffer deduction proportionally)
        uint256 usableEth = totalEth - FLUSH_BUFFER;
        uint256 nftTokens = (tokensBought * nftEth) / totalEth;
        uint256 tokenAutoTokens = (tokensBought * tokenAutoEth) / totalEth;
        uint256 tokenManualTokens = tokensBought - nftTokens - tokenAutoTokens; // Remainder to avoid dust
        
        // Fill token pools for distribution
        nftAutoPool[cycleId] = nftTokens;
        tokenAutoPool[cycleId] = tokenAutoTokens;
        tokenManualPool[cycleId] = tokenManualTokens;
        
        // This epoch is now ready for distribution
        activeDistEpoch = cycleId;
        
        emit RewardTokenPurchased(rewardToken, ethToBuy, tokensBought);
    }

    /**
     * @notice Internal version for batch functions
     * @dev Same logic as buyRewardToken but accepts cycleId parameter
     */
    function _buyRewardTokenInternal(uint256 cycleId) internal {
        // Get ETH amounts from each pool
        uint256 nftEth = nftEthPool[cycleId];
        uint256 tokenAutoEth = tokenAutoEthPool[cycleId];
        uint256 tokenManualEth = tokenManualEthPool[cycleId];
        uint256 totalEth = nftEth + tokenAutoEth + tokenManualEth;
        
        // Skip if not enough ETH
        if (totalEth <= FLUSH_BUFFER) return;
        
        // Keep FLUSH_BUFFER in the contract, use the rest
        uint256 ethToBuy = totalEth - FLUSH_BUFFER;
        
        // Clear ETH pools
        nftEthPool[cycleId] = 0;
        tokenAutoEthPool[cycleId] = 0;
        tokenManualEthPool[cycleId] = 0;
        
        // Bulk swap ALL accumulated ETH to reward tokens
        uint256 tokensBought = _swapEthForToken(ethToBuy);
        
        // H-11 FIX: Use ethToBuy for proportions (what we actually swapped)
        // Proportionally reduce each pool's claim based on buffer deduction
        uint256 nftProportion = (nftEth * ethToBuy) / totalEth;
        uint256 tokenAutoProportion = (tokenAutoEth * ethToBuy) / totalEth;
        
        // Distribute tokens proportionally based on adjusted proportions
        uint256 nftTokens = (tokensBought * nftProportion) / ethToBuy;
        uint256 tokenAutoTokens = (tokensBought * tokenAutoProportion) / ethToBuy;
        uint256 tokenManualTokens = tokensBought - nftTokens - tokenAutoTokens; // Remainder to avoid dust
        
        // Fill token pools for distribution
        nftAutoPool[cycleId] = nftTokens;
        tokenAutoPool[cycleId] = tokenAutoTokens;
        tokenManualPool[cycleId] = tokenManualTokens;
        
        // This epoch is now ready for distribution
        activeDistEpoch = cycleId;
        
        emit RewardTokenPurchased(rewardToken, ethToBuy, tokensBought);
    }

    /**
     * @notice Get available ETH for buying reward token for CURRENT cycle (excludes buffer)
     */
    function getAvailableEthForBuy() public view returns (uint256) {
        uint256 cycleId = activeAccCycleId;
        uint256 totalEth = nftEthPool[cycleId] + tokenAutoEthPool[cycleId] + tokenManualEthPool[cycleId];
        if (totalEth <= FLUSH_BUFFER) return 0;
        return totalEth - FLUSH_BUFFER;
    }

    /**
     * @notice Get current flush buffer amount
     */
    function getFlushBuffer() external pure returns (uint256) {
        return FLUSH_BUFFER;
    }

    /**
     * @notice Get comprehensive epoch info for Telegram bot
     * @return cycleId Current accumulation cycle number
     * @return ethRaised Total ETH raised in current cycle (raw, includes buffer)
     * @return ethForRewards ETH that will be used for rewards (minus buffer)
     * @return timeElapsed Seconds since current cycle started
     * @return timeRemaining Seconds until epoch ends (0 if epoch complete)
     * @return isEpochComplete Whether epoch has passed 6H mark
     * @return isSnapshotActive Whether snapshot is currently in progress
     */
    function getCurrentEpochInfo() external view returns (
        uint256 cycleId,
        uint256 ethRaised,
        uint256 ethForRewards,
        uint256 timeElapsed,
        uint256 timeRemaining,
        bool isEpochComplete,
        bool isSnapshotActive
    ) {
        cycleId = activeAccCycleId;
        ethRaised = nftEthPool[cycleId] + tokenAutoEthPool[cycleId] + tokenManualEthPool[cycleId];
        ethForRewards = ethRaised > FLUSH_BUFFER ? ethRaised - FLUSH_BUFFER : 0;
        timeElapsed = block.timestamp - accStartTime;
        timeRemaining = timeElapsed >= cycleInterval ? 0 : cycleInterval - timeElapsed;
        isEpochComplete = timeElapsed >= cycleInterval;
        isSnapshotActive = (snapshotProgressNft > 0 || snapshotProgressToken > 0) && 
                           !(nftSnapshotDone && tokenSnapshotDone);
    }

    /**
     * @notice Get ETH breakdown for current epoch (for bot display)
     * @return nftEth ETH allocated to NFT holders
     * @return tokenAutoEth ETH allocated to auto token distribution
     * @return tokenManualEth ETH allocated to manual token claims
     */
    function getCurrentEpochEthBreakdown() external view returns (
        uint256 nftEth,
        uint256 tokenAutoEth,
        uint256 tokenManualEth
    ) {
        uint256 cycleId = activeAccCycleId;
        nftEth = nftEthPool[cycleId];
        tokenAutoEth = tokenAutoEthPool[cycleId];
        tokenManualEth = tokenManualEthPool[cycleId];
    }

    event RewardTokenPurchased(address indexed token, uint256 ethSpent, uint256 tokensBought);

    // ============ BATCH EPOCH FUNCTIONS (Gas Optimization + Progressive Batching) ============

    /**
     * @notice Batch start a new epoch with PROGRESSIVE BATCHING
     * @dev Call repeatedly until it returns. Processes snapshotBatchSize holders per call.
     *      Railway calls hourly, accumulates snapshot over multiple calls, then starts epoch.
     *      
     *      TIMING: Railway runs hourly, so:
     *      - Window opens at exactly 6h (cycleInterval)
     *      - Flexible until epoch completes (will just be late, not fail)
     *      
     *      Flow:
     *      - Call 1-N: Build NFT snapshot in batches
     *      - Call N+1-M: Build Token snapshot in batches  
     *      - Final call: buyRewardToken + startClaimPhase
     */
    function batchStartEpoch() external onlyAllowed {
        uint256 elapsed = block.timestamp - accStartTime;
        // Railway runs hourly, window opens at 6h mark (not before)
        require(elapsed >= cycleInterval, "Cycle not complete");
        
        uint256 cycleId = activeAccCycleId;
        
        // CRITICAL: On FIRST batch call, immediately freeze ETH for this cycle
        // New ETH from trades goes to NEXT cycle from this moment on
        if (snapshotProgressNft == 0 && snapshotProgressToken == 0 && !nftSnapshotDone && !tokenSnapshotDone) {
            // This is the first batch call - freeze the current cycle
            // Increment activeAccCycleId so new deposits go to next cycle
            activeAccCycleId++;
            accStartTime = block.timestamp; // Reset accumulation timer for new cycle
            currentDisplayCycleId = activeAccCycleId;
            // cycleId still refers to the OLD cycle we're processing
        }
        
        // Phase 1: NFT Snapshot (batched)
        if (!nftSnapshotDone && nftTracker != address(0)) {
            // LOCK holder count on first batch to prevent infinite loop from new holders
            if (snapshotProgressNft == 0) {
                snapshotNftLen = INFTTracker(nftTracker).holderCount();
            }
            uint256 nftLen = snapshotNftLen; // Use locked count
            uint256 end = snapshotProgressNft + snapshotBatchSize;
            if (end > nftLen) end = nftLen;
            
            uint256 batchTotal = 0;
            uint256 batchCount = 0;
            
            for (uint256 i = snapshotProgressNft; i < end; i++) {
                address holder = INFTTracker(nftTracker).holderAt(i);
                uint256 points = INFTTracker(nftTracker).balanceOf(holder);
                if (points >= INFTTracker(nftTracker).minHoldAmount()) {
                    cycleNftHolderPoints[cycleId][holder] = points;
                    batchTotal += points;
                    batchCount++;
                }
            }
            
            // Accumulate totals
            cycleNftTotalPoints[cycleId] += batchTotal;
            cycleNftCount[cycleId] += batchCount;
            snapshotProgressNft = end;
            
            if (snapshotProgressNft >= nftLen) {
                nftSnapshotDone = true;
            } else {
                return; // More NFT holders to process, Railway calls again
            }
        } else if (nftTracker == address(0)) {
            nftSnapshotDone = true;
        }
        
        // Phase 2: Token Snapshot (batched)
        if (!tokenSnapshotDone && tokenTracker != address(0)) {
            // LOCK holder count on first batch to prevent infinite loop from new holders
            if (snapshotProgressToken == 0) {
                snapshotTokenLen = ITokenTracker(tokenTracker).getNumberOfTokenHolders();
            }
            uint256 tokenLen = snapshotTokenLen; // Use locked count
            uint256 end = snapshotProgressToken + snapshotBatchSize;
            if (end > tokenLen) end = tokenLen;
            
            uint256 batchTotal = 0;
            
            for (uint256 i = snapshotProgressToken; i < end; i++) {
                address holder = ITokenTracker(tokenTracker).holderAt(i);
                uint256 bal = ITokenTracker(tokenTracker).balanceOf(holder);
                if (bal >= ITokenTracker(tokenTracker).minimumTokenBalanceForDividends()) {
                    cycleTokenHolderPoints[cycleId][holder] = bal;
                    batchTotal += bal;
                }
            }
            
            // Accumulate totals
            cycleTokenTotalPoints[cycleId] += batchTotal;
            snapshotProgressToken = end;
            
            if (snapshotProgressToken >= tokenLen) {
                tokenSnapshotDone = true;
            } else {
                return; // More Token holders to process, Railway calls again
            }
        } else if (tokenTracker == address(0)) {
            tokenSnapshotDone = true;
        }
        
        // Phase 3: All snapshots done - record block and emit event
        // M-16: Record snapshot block to prevent manipulation (same as old takeSnapshots)
        cycleSnapshotBlock[cycleId] = block.number;
        emit SnapshotTaken(cycleId, cycleNftTotalPoints[cycleId], cycleTokenTotalPoints[cycleId]);
        
        // Phase 4: Buy reward token using NEW ETH pools
        // This uses nftEthPool, tokenAutoEthPool, tokenManualEthPool (not old cycleAccumulatedEth)
        // and fills nftAutoPool, tokenAutoPool, tokenManualPool with bought tokens
        if (rewardToken != address(0)) {
            _buyRewardTokenInternal(cycleId);
        }
        
        // Phase 5: Start claim phase
        _startClaimPhaseInternal();
        
        // Reset snapshot progress for next epoch
        snapshotProgressNft = 0;
        snapshotProgressToken = 0;
        nftSnapshotDone = false;
        tokenSnapshotDone = false;
    }

    /**
     * @notice Check if snapshot is in progress
     */
    function isSnapshotInProgress() external view returns (bool) {
        return (snapshotProgressNft > 0 || snapshotProgressToken > 0) && 
               !(nftSnapshotDone && tokenSnapshotDone);
    }

    /**
     * @notice Get snapshot progress (for monitoring)
     */
    function getSnapshotProgress() external view returns (
        uint256 nftProgress, 
        uint256 nftTotal, 
        bool nftDone,
        uint256 tokenProgress, 
        uint256 tokenTotal, 
        bool tokenDone
    ) {
        nftProgress = snapshotProgressNft;
        nftTotal = nftTracker != address(0) ? INFTTracker(nftTracker).holderCount() : 0;
        nftDone = nftSnapshotDone;
        tokenProgress = snapshotProgressToken;
        tokenTotal = tokenTracker != address(0) ? ITokenTracker(tokenTracker).getNumberOfTokenHolders() : 0;
        tokenDone = tokenSnapshotDone;
    }

    /**
     * @notice Batch end a cycle - combines flushDistributions + endCycle
     * @dev Reduces gas from 2 separate txs to 1 tx
     *      Called by Railway before accumulation cycle ends
     */
    function batchEndCycle() external onlyAllowed {
        // MainToken V2 now swaps tokens->ETH inline, no swap needed here
        
        // 1. Flush any remaining distributions
        _flushDistributionsInternal();
        
        // 2. End cycle (sweep unclaimed → swap → treasury)
        _endCycleInternal();
    }

    /**
     * @notice Set snapshot batch size (owner only)
     */
    function setSnapshotBatchSize(uint256 _size) external onlyOwner {
        require(_size >= 100 && _size <= 10000, "Invalid batch size");
        snapshotBatchSize = _size;
    }

    function _startClaimPhaseInternal() internal {
        require(!isDistActive, "Distribution already active");
        
        // NOTE: activeAccCycleId was ALREADY incremented in batchStartEpoch() on first batch
        // So the cycle we're distributing is (activeAccCycleId - 1)
        // But we stored it in cycleId at the start of batchStartEpoch, so just use that
        
        // The elapsed check is now against the NEW cycle's accStartTime (set in first batch)
        // This requires the full snapshot batches to complete within the cycle interval
        // which should always be true since we're called right after snapshots complete
        
        // Start distribution for the FROZEN cycle (the one we just finished snapshotting)
        activeDistCycleId = activeAccCycleId - 1; // The cycle that was frozen on first batch
        distStartTime = block.timestamp;
        isDistActive = true;
        
        // New accumulation cycle was ALREADY started in batchStartEpoch() first batch
        // activeAccCycleId and accStartTime already updated there
        
        // Reset batch indices for new distribution
        lastProcessedIndexNft = 0;
        lastProcessedIndexToken = 0;
        
        emit ClaimPhaseStarted(activeDistCycleId);
    }

    function _flushDistributionsInternal() internal {
        if (!isDistActive) return;
        
        uint256 cycleId = activeDistCycleId;
        
        // Process remaining NFT holders
        if (nftTracker != address(0)) {
            uint256 nftLen = INFTTracker(nftTracker).holderCount();
            
            for (uint256 i = lastProcessedIndexNft; i < nftLen; i++) {
                address holder = INFTTracker(nftTracker).holderAt(i);
                if (!hasClaimedAuto[cycleId][holder]) {
                    uint256 points = cycleNftHolderPoints[cycleId][holder];
                    if (points > 0 && cycleNftTotalPoints[cycleId] > 0) {
                        uint256 share = (nftAutoPool[cycleId] * points) / cycleNftTotalPoints[cycleId];
                        if (share > 0) {
                            hasClaimedAuto[cycleId][holder] = true;
                            // Decrement pool to fix accounting (H-7)
                            nftAutoPool[cycleId] -= share;
                            _sendReward(holder, share);
                        }
                    }
                }
            }
            lastProcessedIndexNft = nftLen;
        }
        
        // Process remaining Token holders
        if (tokenTracker != address(0)) {
            uint256 tokenLen = ITokenTracker(tokenTracker).getNumberOfTokenHolders();
            
            for (uint256 i = lastProcessedIndexToken; i < tokenLen; i++) {
                address holder = ITokenTracker(tokenTracker).holderAt(i);
                if (!hasClaimedAuto[cycleId][holder]) {
                    uint256 balance = cycleTokenHolderPoints[cycleId][holder];
                    if (balance > 0 && cycleTokenTotalPoints[cycleId] > 0) {
                        uint256 share = (tokenAutoPool[cycleId] * balance) / cycleTokenTotalPoints[cycleId];
                        if (share > 0) {
                            hasClaimedAuto[cycleId][holder] = true;
                            // Decrement pool to fix accounting (H-7)
                            tokenAutoPool[cycleId] -= share;
                            _sendReward(holder, share);
                        }
                    }
                }
            }
            lastProcessedIndexToken = tokenLen;
        }
    }

    function _endCycleInternal() internal {
        if (!isDistActive) return;
        
        uint256 cycleId = activeDistCycleId;
        
        // Calculate unclaimed manual pool
        uint256 unclaimedManual = tokenManualPool[cycleId];
        
        // Calculate excess NFT points (beyond MAX_NFT_POINTS cap)
        uint256 excessNftRewards = 0;
        if (nftTracker != address(0)) {
            uint256 nftLen = INFTTracker(nftTracker).holderCount();
            
            for (uint256 i = 0; i < nftLen; i++) {
                address holder = INFTTracker(nftTracker).holderAt(i);
                uint256 actualPoints = INFTTracker(nftTracker).balanceOf(holder);
                if (actualPoints > MAX_NFT_POINTS) {
                    uint256 excess = actualPoints - MAX_NFT_POINTS;
                    uint256 excessShare = (nftAutoPool[cycleId] * excess) / (cycleNftTotalPoints[cycleId] + excess);
                    excessNftRewards += excessShare;
                }
            }
        }
        
        uint256 totalToSweep = unclaimedManual + excessNftRewards;
        
        if (totalToSweep > 0) {
            // If using ERC20 reward token, swap to ETH first
            if (rewardToken != address(0)) {
                uint256 ethReceived = _swapTokenForEth(totalToSweep);
                if (ethReceived > 0 && treasury != address(0)) {
                    (bool success, ) = treasury.call{value: ethReceived}("");
                    require(success, "Treasury transfer failed");
                }
            } else {
                // ETH rewards - send directly
                if (treasury != address(0)) {
                    (bool success, ) = treasury.call{value: totalToSweep}("");
                    require(success, "Treasury transfer failed");
                }
            }
            
            emit UnclaimedSwept(unclaimedManual, cycleId);
            if (excessNftRewards > 0) {
                emit ExcessPointsSwept(excessNftRewards, cycleId);
            }
        }
        
        isDistActive = false;
    }
}