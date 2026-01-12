// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRewards
 * @notice Interface for the Rewards contract
 */
interface IRewards {
    // Deposit rewards from token tax
    function depositRewards(uint256 amount) external payable;
    
    // Trigger auto-distribution (called on sells)
    function distributeAuto() external;
    
    // Cycle management (Railway calls)
    function takeSnapshots() external;
    function startClaimPhase() external;
    function endCycle() external;
    function flushDistributions() external;
    
    // View functions
    function getPendingDistributionCount() external view returns (uint256 nftPending, uint256 tokenPending);
    function getCurrentCycleId() external view returns (uint256);
    function getCurrentCycleTotalRewards() external view returns (uint256);
    function getClaimableAmount(address holder) external view returns (uint256);
    function getTimeUntilNextCycle() external view returns (uint256);
    
    // Token management
    function setRewardToken(address _rewardToken) external;
    function getWhitelistedRewardTokens() external view returns (address[] memory);
}

/**
 * @title ITokenTracker
 * @notice Interface for the Token Tracker contract
 */
interface ITokenTracker {
    // Balance management
    function setBalance(address account, uint256 newBalance) external;
    function balanceOf(address account) external view returns (uint256);
    
    // Holder enumeration
    function getNumberOfTokenHolders() external view returns (uint256);
    function holderAt(uint256 index) external view returns (address);
    
    // Configuration
    function minimumTokenBalanceForDividends() external view returns (uint256);
    
    // Snapshot
    function takeSnapshot(uint256 cycleId) external;
    function cycleToTotalBalances(uint256 cycleId) external view returns (uint256);
    function cycleToHolderBalances(uint256 cycleId, address holder) external view returns (uint256);
    
    // Exclusions
    function excludedAddresses(address account) external view returns (bool);
    function setExcludedAddress(address addr, bool exclude) external;
}

/**
 * @title INFTTracker
 * @notice Interface for the NFT Tracker contract
 */
interface INFTTracker {
    // Balance (points) management
    function balanceOf(address account) external view returns (uint256);
    function updateBalance(address from, address to, uint256 tokenId, uint256 points) external;
    
    // Holder enumeration
    function holderCount() external view returns (uint256);
    function holderAt(uint256 index) external view returns (address);
    
    // Configuration
    function minHoldAmount() external view returns (uint256);
    
    // Points calculations
    function getEligiblePoints(address holder) external view returns (uint256);
    function getTotalMaxPoints() external view returns (uint256);
    function getExcessPoints() external view returns (uint256);
    function MAX_POINTS_PER_NFT() external view returns (uint256);
    
    // Snapshot
    function takeSnapshot(uint256 cycleId) external;
    function cycleToTotalPoints(uint256 cycleId) external view returns (uint256);
    function cycleToHolderPoints(uint256 cycleId, address holder) external view returns (uint256);
    
    // Token ID data
    function pointsPerTokenId(uint256 tokenId) external view returns (uint256);
}

/**
 * @title IMainToken
 * @notice Interface for the Main Token contract
 */
interface IMainToken {
    // Tax configuration
    function TAX_BPS() external view returns (uint256);
    function BPS_DIVISOR() external view returns (uint256);
    function WWMM_BPS() external view returns (uint256);
    function REWARDS_BPS() external view returns (uint256);
    
    // Addresses
    function wwmmWallet() external view returns (address);
    function tokenTracker() external view returns (address);
    function rewardsContract() external view returns (address);
    function tokenLocker() external view returns (address);
    
    // State
    function launchBlock() external view returns (uint256);
    function isTradingEnabled() external view returns (bool);
    function taxAccumulated() external view returns (uint256);
    
    // Stats
    function totalTaxCollected() external view returns (uint256);
    function totalRewardsSent() external view returns (uint256);
    function totalWwmmSent() external view returns (uint256);
    function getTaxStats() external view returns (uint256 totalTax, uint256 totalWwmm, uint256 totalRewards);
    
    // Pair management
    function isUniswapPair(address pair) external view returns (bool);
    function setIsUniswapPair(address pair, bool isPair) external;
    
    // Tax exclusions
    function isExcludedFromTax(address account) external view returns (bool);
    function setExcludedFromTax(address account, bool excluded) external;
}

/**
 * @title ITokenLocker
 * @notice Interface for the Token Locker (Vesting) contract
 */
interface ITokenLocker {
    // Constants
    function BLOCKS_PER_MONTH() external view returns (uint256);
    function CLIFF_BLOCKS() external view returns (uint256);
    
    // Vesting info
    function getVestingCount() external view returns (uint256);
    function getVestingInfo(uint256 index) external view returns (
        address beneficiary,
        uint256 totalAmount,
        uint256 startBlock,
        uint256 durationBlocks,
        uint256 released,
        uint256 releasable
    );
    function releasableAmount(uint256 index) external view returns (uint256);
    function getTotalReleasable(address beneficiary) external view returns (uint256);
    
    // Timing
    function getBlocksUntilCliffEnd() external view returns (uint256);
    function getBlocksUntilNextUnlock(uint256 index) external view returns (uint256);
    
    // Actions
    function release(uint256 index) external;
    function releaseAll() external;
    
    // Summary
    function getVestingSummary() external view returns (
        uint256 totalLocked,
        uint256 totalReleased,
        uint256 totalReleasable
    );
    function getBeneficiarySummary(address beneficiary) external view returns (
        uint256 totalAllocated,
        uint256 totalReleased,
        uint256 totalReleasable
    );
}

/**
 * @title INFTContract
 * @notice Interface for the NFT Contract
 */
interface INFTContract {
    // Constants
    function MAX_SUPPLY() external view returns (uint256);
    function PRESALE_MAX() external view returns (uint256);
    function PRESALE_PRICE_USD() external view returns (uint256);
    
    // State
    function presaleActive() external view returns (bool);
    function postPresaleActive() external view returns (bool);
    function mintedCount() external view returns (uint256);
    
    // Pricing
    function getCurrentEthPrice() external view returns (uint256);
    function getPostPresaleMintPrice() external view returns (uint256);
    function getPostPresaleCost(uint256 quantity) external view returns (
        uint256 ethCost,
        uint256 ethCostWithSurcharge,
        uint256 tokenCost
    );
    
    // Price lock
    function lockMintPrice() external;
    function mintPriceLockExpiry(address user) external view returns (uint256);
    function mintPriceLocked(address user) external view returns (uint256);
    
    // Minting
    function mintPresaleETH(address to, uint256 quantity) external payable;
    function mintPresaleSOL(address to, uint256 quantity) external;
    function mintPresaleUSDC(address to, uint256 quantity) external;
    function mintPostPresaleETH(address to, uint256 quantity) external payable;
    function mintWithToken(address to, uint256 quantity) external;
    
    // NFT data
    function tokenIdToPoints(uint256 tokenId) external view returns (uint256);
    function walletMintedCount(address wallet) external view returns (uint256);
}