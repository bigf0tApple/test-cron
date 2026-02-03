/**
 * ====================================================================
 * RAILWAY1: EPOCH AUTOMATION SERVICE
 * ====================================================================
 * 
 * This service automates the RewardsContract epoch cycle:
 * - Calls batchStartEpoch() repeatedly until snapshot completes
 * - Calls batchEndCycle() when distribution period ends
 * 
 * NEW BEHAVIOR (v2):
 * - ETH is FROZEN on FIRST batchStartEpoch() call at 6H mark
 * - Subsequent calls continue the batched snapshot
 * - Final call triggers buy + distribution start
 * 
 * RUN: node index.js (via Railway cron every 5 minutes)
 * ====================================================================
 */

require('dotenv').config();
const { ethers } = require('ethers');

// ====== CONFIGURATION ======
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.RAILWAY_PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT;
const MIN_ETH_BALANCE = ethers.utils.parseEther('0.0005');

// ====== ABI ======
const ABI = [
    // View functions
    "function isDistActive() external view returns (bool)",
    "function accStartTime() external view returns (uint256)",
    "function distStartTime() external view returns (uint256)",
    "function cycleInterval() external view returns (uint256)",
    "function currentDisplayCycleId() external view returns (uint256)",
    "function getAvailableEthForBuy() external view returns (uint256)",
    // Snapshot monitoring
    "function isSnapshotInProgress() external view returns (bool)",
    "function getSnapshotProgress() external view returns (uint256 nftProgress, uint256 nftTotal, bool nftDone, uint256 tokenProgress, uint256 tokenTotal, bool tokenDone)",
    // NEW: Bot-friendly info
    "function getCurrentEpochInfo() external view returns (uint256 cycleId, uint256 ethRaised, uint256 ethForRewards, uint256 timeElapsed, uint256 timeRemaining, bool isEpochComplete, bool isSnapshotActive)",
    // Batch functions
    "function batchStartEpoch() external",
    "function batchEndCycle() external"
];

// ====== HELPERS ======
const formatTime = (s) => `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ${s % 60}s`;
const formatEth = (wei) => ethers.utils.formatEther(wei);

async function safeCall(contract, method, options = {}) {
    console.log(`   → Simulating ${method}()...`);
    try {
        await contract.callStatic[method](options);
        console.log(`   → Simulation OK, sending tx...`);
        const tx = await contract[method](options);
        console.log(`   → TX: ${tx.hash}`);
        const receipt = await tx.wait();
        console.log(`   ✓ ${method}() SUCCESS (gas: ${receipt.gasUsed.toString()})`);
        return true;
    } catch (error) {
        const reason = error.reason || error.message;
        // Don't log as error if it's just "Cycle not complete"
        if (reason.includes('Cycle not complete') || reason.includes('Distribution already active')) {
            console.log(`   ⏳ ${method}(): ${reason}`);
        } else {
            console.log(`   ✗ ${method}() FAILED: ${reason}`);
        }
        return false;
    }
}

// ====== MAIN ======
async function run() {
    console.log(`\n${'═'.repeat(60)}`);
    console.log(`[${new Date().toISOString()}] RAILWAY1: EPOCH AUTOMATION`);
    console.log(`${'═'.repeat(60)}`);

    if (!PRIVATE_KEY) {
        console.error("❌ Missing RAILWAY_PRIVATE_KEY in .env");
        process.exit(1);
    }

    if (!REWARDS_CONTRACT) {
        console.error("❌ Missing REWARDS_CONTRACT in .env");
        process.exit(1);
    }

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

    // Check balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`\nWallet: ${wallet.address}`);
    console.log(`Balance: ${formatEth(balance)} ETH`);

    if (balance.lt(MIN_ETH_BALANCE)) {
        console.error(`❌ Need at least ${formatEth(MIN_ETH_BALANCE)} ETH`);
        process.exit(1);
    }

    // Get contract state
    const now = Math.floor(Date.now() / 1000);
    const isDistActive = await contract.isDistActive();
    const cycleInterval = (await contract.cycleInterval()).toNumber();
    const cycleId = await contract.currentDisplayCycleId();

    console.log(`\n─── Contract State ───`);
    console.log(`Cycle ID: ${cycleId}`);
    console.log(`Distribution Active: ${isDistActive}`);
    console.log(`Cycle Interval: ${formatTime(cycleInterval)}`);

    // ============================================================
    // STEP 1: END DISTRIBUTION IF TIME (batchEndCycle)
    // ============================================================
    if (isDistActive) {
        const distStartTime = (await contract.distStartTime()).toNumber();
        const distElapsed = now - distStartTime;
        const distRemaining = Math.max(0, cycleInterval - distElapsed);

        console.log(`\n─── Distribution Status ───`);
        console.log(`Elapsed: ${formatTime(distElapsed)}`);
        console.log(`Remaining: ${formatTime(distRemaining)}`);

        if (distElapsed >= cycleInterval) {
            console.log(`\n🔄 ENDING DISTRIBUTION with batchEndCycle()...`);
            const success = await safeCall(contract, 'batchEndCycle', { gasLimit: 1500000 });
            if (success) {
                console.log(`✓ Distribution cycle ENDED`);
            }
        } else {
            console.log(`\n⏳ Distribution still running. ${formatTime(distRemaining)} left.`);
        }
    }

    // ============================================================
    // STEP 2: START/CONTINUE EPOCH (batchStartEpoch)
    // This may need multiple calls for batched snapshots
    // ============================================================
    const accStartTime = (await contract.accStartTime()).toNumber();
    const accElapsed = now - accStartTime;
    const accRemaining = Math.max(0, cycleInterval - accElapsed);

    console.log(`\n─── Accumulation Status ───`);
    console.log(`Elapsed: ${formatTime(accElapsed)}`);
    console.log(`Remaining: ${formatTime(accRemaining)}`);

    // Check if snapshot is in progress (means we need to continue it)
    const snapshotInProgress = await contract.isSnapshotInProgress();

    if (snapshotInProgress) {
        // Snapshot already started, continue it
        const progress = await contract.getSnapshotProgress();
        console.log(`\n─── Snapshot Progress ───`);
        console.log(`NFT: ${progress.nftProgress}/${progress.nftTotal} (done: ${progress.nftDone})`);
        console.log(`Token: ${progress.tokenProgress}/${progress.tokenTotal} (done: ${progress.tokenDone})`);

        console.log(`\n🔄 CONTINUING SNAPSHOT with batchStartEpoch()...`);
        await safeCall(contract, 'batchStartEpoch', { gasLimit: 2000000 });
    } else if (accElapsed >= cycleInterval) {
        // Start new epoch (first batch call - this also freezes ETH!)
        console.log(`\n🔄 STARTING NEW EPOCH with batchStartEpoch()...`);
        console.log(`   (ETH will be FROZEN for this cycle on this first call)`);
        const success = await safeCall(contract, 'batchStartEpoch', { gasLimit: 2000000 });
        if (success) {
            // Check if we need more batches
            const stillInProgress = await contract.isSnapshotInProgress();
            if (stillInProgress) {
                console.log(`   → Snapshot started, needs more batches (Railway will continue)`);
            } else {
                console.log(`   → Snapshot complete, epoch started!`);
            }
        }
    } else {
        console.log(`\n⏳ Accumulation still running. ${formatTime(accRemaining)} left.`);
    }

    // Show current ETH raised
    try {
        const epochInfo = await contract.getCurrentEpochInfo();
        console.log(`\n─── Current Epoch Info ───`);
        console.log(`Cycle: ${epochInfo.cycleId}`);
        console.log(`ETH Raised: ${formatEth(epochInfo.ethRaised)} ETH`);
        console.log(`ETH for Rewards: ${formatEth(epochInfo.ethForRewards)} ETH`);
    } catch (e) {
        // Old contract without this function
        const ethForBuy = await contract.getAvailableEthForBuy();
        console.log(`\n─── ETH Status ───`);
        console.log(`Available for Rewards: ${formatEth(ethForBuy)} ETH`);
    }

    console.log(`\n${'═'.repeat(60)}`);
    console.log(`✓ RAILWAY1 COMPLETE`);
    console.log(`${'═'.repeat(60)}\n`);
}

run()
    .then(() => process.exit(0))
    .catch((e) => {
        console.error(`\n❌ FATAL: ${e.message}`);
        process.exit(1);
    });
