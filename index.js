/**
 * ====================================================================
 * 66M REWARDS - RAILWAY EPOCH AUTOMATION
 * ====================================================================
 * 
 * FLOW OVERVIEW (Two Overlapping 6h Cycles):
 * 
 * ┌─────────────── EPOCH N ────────────────┐
 * │                                         │
 * │  ACCUMULATION (6h)                      │
 * │  └── ETH flows in from token tax        │
 * │  └── Stored in cycleAccumulatedEth[N]   │
 * │                                         │
 * │  At 5h55m:                              │
 * │   1. takeSnapshots()  - capture holders │
 * │   2. buyRewardToken() - swap ETH→token  │
 * │   3. startClaimPhase()- start dist      │
 * │      └── Starts EPOCH N+1 accumulation  │
 * │      └── Starts EPOCH N distribution    │
 * │                                         │
 * ├─────────────── EPOCH N DISTRIBUTION ───┤
 * │                                         │
 * │  DISTRIBUTION (6h, parallel)            │
 * │  └── distributeAuto() via token txs     │
 * │  └── Users claim manual 30% on website  │
 * │                                         │
 * │  At 5h55m (after dist start):           │
 * │   4. endCycle()                         │
 * │      └── Flush remaining distributions  │
 * │      └── Sweep unclaimed → swap → ETH   │
 * │      └── Send ETH to TREASURWEE         │
 * │                                         │
 * └─────────────────────────────────────────┘
 * 
 * This script runs every ~30 minutes and checks:
 * 1. Is there an active distribution that needs to end?
 * 2. Is the accumulation cycle ready for transition?
 * 
 * ====================================================================
 */

require('dotenv').config();
const { ethers } = require('ethers');

// ====== CONFIGURATION ======
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT || '0x9945116E0f2B6fB6ba5A3d1a3aA938bf6B7211CF';
const MIN_ETH_BALANCE = ethers.utils.parseEther('0.0005'); // 0.0005 ETH minimum

// ====== ABI ======
const ABI = [
    // View functions
    "function isDistActive() external view returns (bool)",
    "function accStartTime() external view returns (uint256)",
    "function distStartTime() external view returns (uint256)",
    "function cycleInterval() external view returns (uint256)",
    "function rewardToken() external view returns (address)",
    "function currentDisplayCycleId() external view returns (uint256)",
    "function getAvailableEthForBuy() external view returns (uint256)",
    // State-changing functions
    "function takeSnapshots() external",
    "function buyRewardToken() external",
    "function startClaimPhase() external",
    "function flushDistributions() external",
    "function endCycle() external"
];

// ====== HELPERS ======
const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
const formatTime = (s) => `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ${s % 60}s`;

async function safeCall(contract, method, options = {}) {
    console.log(`   → Simulating ${method}()...`);
    try {
        await contract.callStatic[method](options);
        console.log(`   → Simulation OK, sending tx...`);
        const tx = await contract[method](options);
        console.log(`   → TX: ${tx.hash}`);
        await tx.wait();
        console.log(`   ✓ ${method}() SUCCESS`);
        return true;
    } catch (error) {
        console.log(`   ✗ ${method}() FAILED: ${error.reason || error.message}`);
        return false;
    }
}

// ====== MAIN ======
async function run() {
    console.log(`\n${'═'.repeat(60)}`);
    console.log(`[${new Date().toISOString()}] 66M EPOCH AUTOMATION`);
    console.log(`${'═'.repeat(60)}`);

    if (!PRIVATE_KEY) {
        console.error("❌ Missing PRIVATE_KEY");
        process.exit(1);
    }

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

    // Check balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`\nWallet: ${wallet.address}`);
    console.log(`Balance: ${ethers.utils.formatEther(balance)} ETH`);

    if (balance.lt(MIN_ETH_BALANCE)) {
        console.error(`❌ Need at least ${ethers.utils.formatEther(MIN_ETH_BALANCE)} ETH`);
        process.exit(1);
    }

    // Get contract state
    const now = Math.floor(Date.now() / 1000);
    const isDistActive = await contract.isDistActive();
    const cycleInterval = (await contract.cycleInterval()).toNumber();
    const rewardToken = await contract.rewardToken();
    const cycleId = await contract.currentDisplayCycleId();

    console.log(`\n─── Contract State ───`);
    console.log(`Cycle ID: ${cycleId}`);
    console.log(`Distribution Active: ${isDistActive}`);
    console.log(`Cycle Interval: ${formatTime(cycleInterval)}`);
    console.log(`Reward Token: ${rewardToken === ethers.constants.AddressZero ? 'ETH' : rewardToken}`);

    // ============================================================
    // STEP 1: CHECK IF DISTRIBUTION NEEDS TO END
    // ============================================================
    if (isDistActive) {
        const distStartTime = (await contract.distStartTime()).toNumber();
        const distElapsed = now - distStartTime;
        const distRemaining = cycleInterval - distElapsed;

        console.log(`\n─── Distribution Status ───`);
        console.log(`Elapsed: ${formatTime(distElapsed)}`);
        console.log(`Remaining: ${formatTime(Math.max(0, distRemaining))}`);

        // End distribution if within 5-minute window of end
        if (distElapsed >= cycleInterval - 300) {
            console.log(`\n🔄 ENDING DISTRIBUTION CYCLE ${cycleId}...`);

            // Flush any remaining distributions
            console.log(`\n[1/2] Flushing distributions...`);
            await safeCall(contract, 'flushDistributions', { gasLimit: 3000000 });
            await sleep(3000);

            // End cycle (sweep unclaimed → swap → treasury)
            console.log(`\n[2/2] Ending cycle (sweep to treasury)...`);
            await safeCall(contract, 'endCycle', { gasLimit: 2000000 });
            await sleep(3000);

            console.log(`\n✓ Distribution cycle ${cycleId} ENDED`);
        } else {
            console.log(`\n⏳ Distribution still running. ${formatTime(distRemaining)} left.`);
        }
    }

    // ============================================================
    // STEP 2: CHECK IF ACCUMULATION READY FOR TRANSITION
    // ============================================================
    const accStartTime = (await contract.accStartTime()).toNumber();
    const accElapsed = now - accStartTime;
    const accRemaining = cycleInterval - accElapsed;

    console.log(`\n─── Accumulation Status ───`);
    console.log(`Elapsed: ${formatTime(accElapsed)}`);
    console.log(`Remaining: ${formatTime(Math.max(0, accRemaining))}`);

    // Start new epoch if within 5-minute window of end
    if (accElapsed >= cycleInterval - 300) {
        console.log(`\n🔄 STARTING NEW EPOCH...`);

        // 1. Take snapshots
        console.log(`\n[1/3] Taking holder snapshots...`);
        const snapOk = await safeCall(contract, 'takeSnapshots', { gasLimit: 5000000 });
        if (!snapOk) {
            console.log(`❌ Snapshot failed, aborting`);
            process.exit(1);
        }
        await sleep(3000);

        // 2. Buy reward token (if set and ETH available)
        if (rewardToken !== ethers.constants.AddressZero) {
            const ethAvailable = await contract.getAvailableEthForBuy();
            console.log(`\n[2/3] Buying reward tokens (${ethers.utils.formatEther(ethAvailable)} ETH)...`);
            if (ethAvailable.gt(0)) {
                await safeCall(contract, 'buyRewardToken', { gasLimit: 500000 });
                await sleep(3000);
            } else {
                console.log(`   → No ETH to buy, skipping`);
            }
        } else {
            console.log(`\n[2/3] No reward token set, distributing ETH directly`);
        }

        // 3. Start claim phase (starts new accumulation + distribution)
        console.log(`\n[3/3] Starting claim phase...`);
        const startOk = await safeCall(contract, 'startClaimPhase', { gasLimit: 1000000 });
        if (startOk) {
            console.log(`\n✓ NEW EPOCH STARTED!`);
            console.log(`   → New accumulation cycle began`);
            console.log(`   → Distribution of previous epoch began`);
        }
    } else {
        console.log(`\n⏳ Accumulation still running. ${formatTime(accRemaining)} left.`);
    }

    console.log(`\n${'═'.repeat(60)}`);
    console.log(`✓ CRON COMPLETE`);
    console.log(`${'═'.repeat(60)}\n`);
}

run()
    .then(() => process.exit(0))
    .catch((e) => {
        console.error(`\n❌ FATAL: ${e.message}`);
        process.exit(1);
    });
