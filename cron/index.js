/**
 * ====================================================================
 * RAILWAY1: EPOCH AUTOMATION SERVICE (Continuous Mode)
 * ====================================================================
 * 
 * This service runs ONCE when triggered, loops until epoch is complete,
 * then exits. Designed to be triggered by Railway scheduler at 6H mark.
 * 
 * FLOW:
 * 1. Check if epoch complete (6H passed)
 * 2. If yes, call batchStartEpoch() back-to-back until done
 * 3. Exit when distribution is started
 * 4. Separately handle batchEndCycle() at distribution end
 * 
 * RUN: Trigger once every 6 hours via Railway scheduler
 * ====================================================================
 */

require('dotenv').config();
const { ethers } = require('ethers');

// ====== CONFIGURATION ======
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.RAILWAY_PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT;
const MIN_ETH_BALANCE = ethers.utils.parseEther('0.001');

// Delay between calls (milliseconds) - just enough to avoid rate limits
const CALL_DELAY_MS = 2000; // 2 seconds between calls

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
const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

function log(msg) {
    console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function safeCall(contract, method, options = {}) {
    log(`→ Calling ${method}()...`);
    try {
        // Simulate first
        await contract.callStatic[method](options);

        // Execute
        const tx = await contract[method](options);
        log(`  TX: ${tx.hash}`);
        const receipt = await tx.wait();
        log(`  ✓ SUCCESS (gas: ${receipt.gasUsed.toString()})`);
        return { success: true, receipt };
    } catch (error) {
        const reason = error.reason || error.message;
        log(`  ✗ FAILED: ${reason}`);
        return { success: false, reason };
    }
}

// ====== MAIN: START EPOCH ======
async function runStartEpoch() {
    log(`${'═'.repeat(60)}`);
    log(`RAILWAY1: START EPOCH (Continuous Mode)`);
    log(`${'═'.repeat(60)}`);

    if (!PRIVATE_KEY || !REWARDS_CONTRACT) {
        log("❌ Missing RAILWAY_PRIVATE_KEY or REWARDS_CONTRACT in .env");
        process.exit(1);
    }

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

    // Check balance
    const balance = await provider.getBalance(wallet.address);
    log(`Wallet: ${wallet.address}`);
    log(`Balance: ${formatEth(balance)} ETH`);

    if (balance.lt(MIN_ETH_BALANCE)) {
        log(`❌ Need at least ${formatEth(MIN_ETH_BALANCE)} ETH`);
        process.exit(1);
    }

    // Get contract state
    const now = Math.floor(Date.now() / 1000);
    const cycleInterval = (await contract.cycleInterval()).toNumber();
    const accStartTime = (await contract.accStartTime()).toNumber();
    const accElapsed = now - accStartTime;
    const cycleId = await contract.currentDisplayCycleId();

    log(`\n─── Status ───`);
    log(`Cycle ID: ${cycleId}`);
    log(`Cycle Interval: ${formatTime(cycleInterval)}`);
    log(`Time Elapsed: ${formatTime(accElapsed)}`);

    // Check if epoch ready
    if (accElapsed < cycleInterval) {
        const remaining = cycleInterval - accElapsed;
        log(`\n⏳ Epoch not complete yet. ${formatTime(remaining)} remaining.`);
        log(`✓ Nothing to do, exiting.`);
        return;
    }

    log(`\n🚀 EPOCH COMPLETE - Starting continuous processing...`);

    // ============================================================
    // CONTINUOUS LOOP: Call batchStartEpoch until done
    // ============================================================
    let batchCount = 0;
    let done = false;

    while (!done) {
        batchCount++;
        log(`\n─── Batch ${batchCount} ───`);

        // Check progress before call
        const snapshotInProgress = await contract.isSnapshotInProgress();
        if (snapshotInProgress) {
            const progress = await contract.getSnapshotProgress();
            log(`NFT: ${progress.nftProgress}/${progress.nftTotal} (done: ${progress.nftDone})`);
            log(`Token: ${progress.tokenProgress}/${progress.tokenTotal} (done: ${progress.tokenDone})`);
        }

        // Call batchStartEpoch
        const result = await safeCall(contract, 'batchStartEpoch', { gasLimit: 3000000 });

        if (!result.success) {
            if (result.reason.includes('Distribution already active')) {
                // This means we finished and distribution started
                log(`\n✅ EPOCH COMPLETE! Distribution is now active.`);
                done = true;
            } else if (result.reason.includes('Cycle not complete')) {
                // This shouldn't happen but handle it
                log(`\n⚠️ Cycle not complete. Exiting.`);
                done = true;
            } else {
                // Real error
                log(`\n❌ Unexpected error. Exiting.`);
                done = true;
            }
        } else {
            // Check if we're done after successful call
            const stillInProgress = await contract.isSnapshotInProgress();
            const isDistActive = await contract.isDistActive();

            if (isDistActive) {
                log(`\n✅ EPOCH COMPLETE! Distribution is now active.`);
                done = true;
            } else if (!stillInProgress) {
                // Snapshot done but distribution not active yet? Check again
                log(`Checking if distribution started...`);
                await sleep(1000);
                const distActive = await contract.isDistActive();
                if (distActive) {
                    log(`\n✅ EPOCH COMPLETE! Distribution is now active.`);
                    done = true;
                }
            }
        }

        if (!done) {
            // Small delay between calls to avoid rate limits
            await sleep(CALL_DELAY_MS);
        }
    }

    // Show final status
    try {
        const epochInfo = await contract.getCurrentEpochInfo();
        log(`\n─── New Epoch Info ───`);
        log(`Cycle: ${epochInfo.cycleId}`);
        log(`ETH Raised (new cycle): ${formatEth(epochInfo.ethRaised)} ETH`);
    } catch (e) {
        // Old contract without this function
    }

    log(`\n${'═'.repeat(60)}`);
    log(`✅ RAILWAY1 COMPLETE - Processed ${batchCount} batches`);
    log(`${'═'.repeat(60)}`);
}

// ====== MAIN: END CYCLE ======
async function runEndCycle() {
    log(`${'═'.repeat(60)}`);
    log(`RAILWAY1: END CYCLE`);
    log(`${'═'.repeat(60)}`);

    if (!PRIVATE_KEY || !REWARDS_CONTRACT) {
        log("❌ Missing config");
        process.exit(1);
    }

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

    const isDistActive = await contract.isDistActive();
    if (!isDistActive) {
        log("No active distribution to end.");
        return;
    }

    const now = Math.floor(Date.now() / 1000);
    const cycleInterval = (await contract.cycleInterval()).toNumber();
    const distStartTime = (await contract.distStartTime()).toNumber();
    const distElapsed = now - distStartTime;

    log(`Distribution elapsed: ${formatTime(distElapsed)}`);

    if (distElapsed < cycleInterval) {
        log(`⏳ Distribution not complete yet. ${formatTime(cycleInterval - distElapsed)} remaining.`);
        return;
    }

    log(`🔄 Ending distribution...`);
    await safeCall(contract, 'batchEndCycle', { gasLimit: 1500000 });

    log(`\n${'═'.repeat(60)}`);
    log(`✅ CYCLE ENDED`);
    log(`${'═'.repeat(60)}`);
}

// ====== ENTRY POINT ======
const mode = process.argv[2] || 'start';

if (mode === 'end') {
    runEndCycle()
        .then(() => process.exit(0))
        .catch((e) => {
            console.error(`❌ FATAL: ${e.message}`);
            process.exit(1);
        });
} else {
    runStartEpoch()
        .then(() => process.exit(0))
        .catch((e) => {
            console.error(`❌ FATAL: ${e.message}`);
            process.exit(1);
        });
}
