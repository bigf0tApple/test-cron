require('dotenv').config();
const { ethers } = require('ethers');

// Configuration
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT;

// Cycle interval in seconds (3 hours)
const CYCLE_INTERVAL = 3 * 60 * 60; // 10800 seconds

// ABI for the functions we need
const ABI = [
    "function isDistActive() external view returns (bool)",
    "function accStartTime() external view returns (uint256)",
    "function distStartTime() external view returns (uint256)",
    "function cycleInterval() external view returns (uint256)",
    "function rewardToken() external view returns (address)",
    "function activeAccCycleId() external view returns (uint256)",
    "function activeDistCycleId() external view returns (uint256)",
    "function getAvailableEthForBuy() external view returns (uint256)",
    "function cycleAccumulatedEth(uint256) external view returns (uint256)",
    "function takeSnapshots() external",
    "function startClaimPhase() external",
    "function endCycle() external",
    "function buyRewardToken() external",
    "function distributeAuto() external",
    "function flushDistributions() external",
    "function currentDisplayCycleId() external view returns (uint256)"
];

// Helper function to add delay between calls
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

// Helper to format time
function formatTime(seconds) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return `${h}h ${m}m ${s}s`;
}

async function run() {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`[${new Date().toISOString()}] RAILWAY CRON - Epoch Transition`);
    console.log(`${'='.repeat(60)}`);

    if (!PRIVATE_KEY || !REWARDS_CONTRACT) {
        console.error("❌ Missing env vars: PRIVATE_KEY or REWARDS_CONTRACT");
        process.exit(1);
    }

    try {
        const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
        const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
        const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

        console.log(`Wallet: ${wallet.address}`);
        console.log(`Contract: ${REWARDS_CONTRACT}`);
        console.log(`RPC: ${RPC_URL}`);

        // Get current state
        const isDistActive = await contract.isDistActive();
        const cycleInterval = await contract.cycleInterval();
        const displayCycleId = await contract.currentDisplayCycleId();
        const rewardToken = await contract.rewardToken();
        const now = Math.floor(Date.now() / 1000);

        console.log(`\n--- Current State ---`);
        console.log(`Display Cycle ID: ${displayCycleId}`);
        console.log(`Distribution Active: ${isDistActive}`);
        console.log(`Cycle Interval: ${formatTime(cycleInterval.toNumber())}`);
        console.log(`Reward Token: ${rewardToken === ethers.constants.AddressZero ? 'ETH (none set)' : rewardToken}`);

        // ==================== EPOCH TRANSITION SEQUENCE ====================
        // This runs every 3 hours and handles the overlapping epochs:
        // 1. Close previous epoch (if distribution is active)
        // 2. Start new distribution for current accumulated epoch
        // 3. New accumulation begins automatically

        // STEP 1: Close previous epoch if distribution is active
        if (isDistActive) {
            console.log(`\n[STEP 1] CLOSING PREVIOUS EPOCH (Cycle ${displayCycleId})`);

            // Check if distribution period has elapsed
            const distStartTime = await contract.distStartTime();
            const distElapsed = now - distStartTime.toNumber();
            console.log(`   Distribution elapsed: ${formatTime(distElapsed)}`);

            if (distElapsed >= cycleInterval.toNumber() - 300) { // 5 min buffer
                // 1a. Flush remaining distributions
                console.log(`   1a. Flushing remaining distributions...`);
                try {
                    const tx1 = await contract.flushDistributions({ gasLimit: 3000000 });
                    console.log(`       TX: ${tx1.hash}`);
                    await tx1.wait();
                    console.log(`       ✓ Flush complete`);
                } catch (e) {
                    console.log(`       ⚠ Flush skipped: ${e.reason || 'nothing to flush'}`);
                }
                await sleep(2000); // 2 second delay

                // 1b. End the cycle (sweeps unclaimed → Treasury)
                console.log(`   1b. Ending cycle (sweep→Treasury)...`);
                const tx2 = await contract.endCycle({ gasLimit: 2000000 });
                console.log(`       TX: ${tx2.hash}`);
                await tx2.wait();
                console.log(`       ✓ Cycle ended, unclaimed swept to Treasury`);
                await sleep(2000);
            } else {
                const remaining = cycleInterval.toNumber() - distElapsed;
                console.log(`   ⏳ Not time yet. ${formatTime(remaining)} remaining.`);
                console.log(`\n✓ Cron job complete (waiting for distribution period to end)`);
                return;
            }
        } else {
            console.log(`\n[STEP 1] No active distribution to close (first epoch or already closed)`);
        }

        // STEP 2: Check if accumulation period has completed
        const accStartTime = await contract.accStartTime();
        const accElapsed = now - accStartTime.toNumber();
        console.log(`\n[STEP 2] CHECKING ACCUMULATION STATUS`);
        console.log(`   Accumulation elapsed: ${formatTime(accElapsed)}`);

        if (accElapsed >= cycleInterval.toNumber() - 300) { // 5 min buffer
            console.log(`   ✓ Accumulation period complete. Starting transition...`);

            // 2a. Take snapshots of holders
            console.log(`\n   2a. Taking holder snapshots...`);
            const tx3 = await contract.takeSnapshots({ gasLimit: 3000000 });
            console.log(`       TX: ${tx3.hash}`);
            await tx3.wait();
            console.log(`       ✓ Snapshots captured`);
            await sleep(2000);

            // 2b. Buy reward token with accumulated ETH (if reward token set)
            if (rewardToken !== ethers.constants.AddressZero) {
                const ethAvailable = await contract.getAvailableEthForBuy();
                console.log(`\n   2b. Buying reward tokens (${ethers.utils.formatEther(ethAvailable)} ETH available)...`);

                if (ethAvailable.gt(0)) {
                    const tx4 = await contract.buyRewardToken({ gasLimit: 500000 });
                    console.log(`       TX: ${tx4.hash}`);
                    await tx4.wait();
                    console.log(`       ✓ Reward tokens purchased`);
                } else {
                    console.log(`       ⚠ No ETH available for purchase`);
                }
                await sleep(2000);
            } else {
                console.log(`\n   2b. No reward token set (distributing ETH directly)`);
            }

            // 2c. Start claim phase (allocates pools, sets isDistActive=true)
            console.log(`\n   2c. Starting claim phase...`);
            const tx5 = await contract.startClaimPhase({ gasLimit: 1000000 });
            console.log(`       TX: ${tx5.hash}`);
            await tx5.wait();
            console.log(`       ✓ Claim phase started`);
            console.log(`       ✓ New accumulation epoch started automatically`);

        } else {
            const remaining = cycleInterval.toNumber() - accElapsed;
            console.log(`   ⏳ Not time yet. ${formatTime(remaining)} remaining until transition.`);
        }

        console.log(`\n${'='.repeat(60)}`);
        console.log(`✓ CRON JOB COMPLETE`);
        console.log(`${'='.repeat(60)}\n`);

    } catch (error) {
        console.error(`\n❌ ERROR: ${error.reason || error.message}`);
        if (error.error?.data) {
            console.error(`   Data: ${error.error.data}`);
        }
        process.exit(1);
    }
}

run().then(() => process.exit(0));
