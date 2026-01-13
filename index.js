require('dotenv').config();
const { ethers } = require('ethers');

// Configuration
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT;

// Minimum ETH balance required to run (prevents wasted gas on low balance)
const MIN_ETH_BALANCE = ethers.utils.parseEther('0.001'); // 0.001 ETH

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

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

function formatTime(seconds) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return `${h}h ${m}m ${s}s`;
}

// Simulate a call before sending - prevents wasted gas on reverts
async function safeCall(contract, methodName, options = {}) {
    console.log(`   Simulating ${methodName}()...`);
    try {
        // Static call first to check if it would succeed
        await contract.callStatic[methodName](options);
        console.log(`   ✓ Simulation passed, sending transaction...`);

        // If simulation passed, send the real transaction
        const tx = await contract[methodName](options);
        console.log(`   TX: ${tx.hash}`);
        await tx.wait();
        console.log(`   ✓ ${methodName}() complete`);
        return true;
    } catch (error) {
        const reason = error.reason || error.message || 'Unknown error';
        console.log(`   ⚠ ${methodName}() would fail: ${reason}`);
        console.log(`   → Skipping to save gas`);
        return false;
    }
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

        // CHECK WALLET BALANCE FIRST
        const balance = await provider.getBalance(wallet.address);
        console.log(`\nWallet: ${wallet.address}`);
        console.log(`Balance: ${ethers.utils.formatEther(balance)} ETH`);

        if (balance.lt(MIN_ETH_BALANCE)) {
            console.error(`\n❌ INSUFFICIENT BALANCE`);
            console.error(`   Need at least ${ethers.utils.formatEther(MIN_ETH_BALANCE)} ETH for gas`);
            console.error(`   Please fund the wallet and try again`);
            process.exit(1);
        }

        console.log(`Contract: ${REWARDS_CONTRACT}`);

        // Get current state (view calls - free, no gas)
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

        // ==================== STEP 1: Close Previous Epoch ====================
        if (isDistActive) {
            const distStartTime = await contract.distStartTime();
            const distElapsed = now - distStartTime.toNumber();
            console.log(`\n[STEP 1] CLOSING PREVIOUS EPOCH (Cycle ${displayCycleId})`);
            console.log(`   Distribution elapsed: ${formatTime(distElapsed)}`);

            if (distElapsed >= cycleInterval.toNumber() - 300) {
                // Flush distributions (with safe call)
                console.log(`\n   1a. Flushing remaining distributions...`);
                await safeCall(contract, 'flushDistributions', { gasLimit: 3000000 });
                await sleep(2000);

                // End cycle (with safe call)
                console.log(`\n   1b. Ending cycle...`);
                const endSuccess = await safeCall(contract, 'endCycle', { gasLimit: 2000000 });
                if (!endSuccess) {
                    console.log(`\n⚠ Could not end cycle. Check contract state.`);
                    process.exit(0);
                }
                await sleep(2000);
            } else {
                const remaining = cycleInterval.toNumber() - distElapsed;
                console.log(`   ⏳ Not time yet. ${formatTime(remaining)} remaining.`);
                console.log(`\n✓ Cron job complete (waiting)`);
                return;
            }
        } else {
            console.log(`\n[STEP 1] No active distribution to close`);
        }

        // ==================== STEP 2: Start New Epoch ====================
        const accStartTime = await contract.accStartTime();
        const accElapsed = now - accStartTime.toNumber();
        console.log(`\n[STEP 2] CHECKING ACCUMULATION STATUS`);
        console.log(`   Accumulation elapsed: ${formatTime(accElapsed)}`);

        if (accElapsed >= cycleInterval.toNumber() - 300) {
            console.log(`   ✓ Accumulation complete. Starting transition...`);

            // Take snapshots
            console.log(`\n   2a. Taking holder snapshots...`);
            const snapshotSuccess = await safeCall(contract, 'takeSnapshots', { gasLimit: 3000000 });
            if (!snapshotSuccess) {
                console.log(`\n⚠ Snapshot failed. Stopping.`);
                process.exit(0);
            }
            await sleep(2000);

            // Buy reward token (if set)
            if (rewardToken !== ethers.constants.AddressZero) {
                const ethAvailable = await contract.getAvailableEthForBuy();
                console.log(`\n   2b. Buying reward tokens (${ethers.utils.formatEther(ethAvailable)} ETH available)...`);

                if (ethAvailable.gt(0)) {
                    await safeCall(contract, 'buyRewardToken', { gasLimit: 500000 });
                } else {
                    console.log(`   → No ETH available, skipping`);
                }
                await sleep(2000);
            } else {
                console.log(`\n   2b. No reward token set (distributing ETH directly)`);
            }

            // Start claim phase
            console.log(`\n   2c. Starting claim phase...`);
            const startSuccess = await safeCall(contract, 'startClaimPhase', { gasLimit: 1000000 });
            if (startSuccess) {
                console.log(`   ✓ New distribution epoch started!`);
            }

        } else {
            const remaining = cycleInterval.toNumber() - accElapsed;
            console.log(`   ⏳ Not time yet. ${formatTime(remaining)} remaining.`);
        }

        console.log(`\n${'='.repeat(60)}`);
        console.log(`✓ CRON JOB COMPLETE`);
        console.log(`${'='.repeat(60)}\n`);

    } catch (error) {
        console.error(`\n❌ ERROR: ${error.reason || error.message}`);
        process.exit(1);
    }
}

run().then(() => process.exit(0));
