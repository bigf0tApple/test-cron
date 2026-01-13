require('dotenv').config();
const { ethers } = require('ethers');

// Configuration
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT;

// ABI for the functions we need
const ABI = [
    "function isDistActive() external view returns (bool)",
    "function accStartTime() external view returns (uint256)",
    "function distStartTime() external view returns (uint256)",
    "function cycleInterval() external view returns (uint256)",
    "function rewardToken() external view returns (address)",
    "function getAvailableEthForBuy() external view returns (uint256)",
    "function takeSnapshots() external",
    "function startClaimPhase() external",
    "function endCycle() external",
    "function buyRewardToken() external",
    "function distributeAuto() external",
    "function flushDistributions() external",
    "function currentDisplayCycleId() external view returns (uint256)"
];

async function run() {
    console.log(`\n[${new Date().toISOString()}] Starting Rewards Cron Job...`);

    if (!PRIVATE_KEY || !REWARDS_CONTRACT) {
        console.error("Missing env vars: PRIVATE_KEY or REWARDS_CONTRACT");
        process.exit(1);
    }

    try {
        const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
        const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
        const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

        console.log("Wallet:", wallet.address);
        console.log("Contract:", REWARDS_CONTRACT);

        // Get current state
        const isDistActive = await contract.isDistActive();
        const cycleInterval = await contract.cycleInterval();
        const cycleId = await contract.currentDisplayCycleId();
        const rewardToken = await contract.rewardToken();
        const now = Math.floor(Date.now() / 1000);

        console.log(`Cycle ID: ${cycleId}`);
        console.log(`Is Distribution Active: ${isDistActive}`);
        console.log(`Cycle Interval: ${cycleInterval.toString()} seconds`);
        console.log(`Reward Token: ${rewardToken}`);

        if (!isDistActive) {
            // ==================== ACCUMULATION PHASE ====================
            const accStartTime = await contract.accStartTime();
            const elapsed = now - accStartTime.toNumber();
            console.log(`\n[ACCUMULATION PHASE] Elapsed: ${elapsed}s / ${cycleInterval.toString()}s`);

            if (elapsed >= cycleInterval.toNumber()) {
                console.log("Accumulation complete! Starting transition...");

                // Step 1: Take Snapshots (captures holder points)
                console.log("1. Taking snapshots...");
                let tx = await contract.takeSnapshots({ gasLimit: 3000000 });
                console.log(`   TX: ${tx.hash}`);
                await tx.wait();
                console.log("   ✓ Snapshots taken!");

                // Step 2: Buy Reward Token FIRST (before allocating pools)
                if (rewardToken !== ethers.constants.AddressZero) {
                    const ethAvailable = await contract.getAvailableEthForBuy();
                    console.log(`2. Checking reward token purchase... (ETH available: ${ethers.utils.formatEther(ethAvailable)})`);

                    if (ethAvailable.gt(0)) {
                        console.log("   Buying reward tokens...");
                        tx = await contract.buyRewardToken({ gasLimit: 500000 });
                        console.log(`   TX: ${tx.hash}`);
                        await tx.wait();
                        console.log("   ✓ Reward tokens purchased!");
                    } else {
                        console.log("   No ETH available for purchase.");
                    }
                } else {
                    console.log("2. No reward token set (will distribute ETH directly).");
                }

                // Step 3: Start Claim Phase (allocates pools with purchased tokens/ETH)
                console.log("3. Starting claim phase...");
                tx = await contract.startClaimPhase({ gasLimit: 1000000 });
                console.log(`   TX: ${tx.hash}`);
                await tx.wait();
                console.log("   ✓ Claim phase started!");

                console.log("\n✓ Distribution phase is now active!");
            } else {
                const remaining = cycleInterval.toNumber() - elapsed;
                console.log(`Not yet time. ${remaining}s remaining until transition.`);
            }

        } else {
            // ==================== DISTRIBUTION PHASE ====================
            const distStartTime = await contract.distStartTime();
            const elapsed = now - distStartTime.toNumber();
            console.log(`\n[DISTRIBUTION PHASE] Elapsed: ${elapsed}s / ${cycleInterval.toString()}s`);

            // Try to process some auto distributions
            console.log("Processing auto distributions...");
            try {
                const tx = await contract.distributeAuto({ gasLimit: 1000000 });
                console.log(`   TX: ${tx.hash}`);
                await tx.wait();
                console.log("   ✓ Auto distribution batch processed.");
            } catch (e) {
                console.log("   No distributions to process or already complete.");
            }

            if (elapsed >= cycleInterval.toNumber()) {
                console.log("\nDistribution phase complete! Ending cycle...");

                // Flush any remaining distributions
                console.log("1. Flushing remaining distributions...");
                try {
                    let tx = await contract.flushDistributions({ gasLimit: 3000000 });
                    console.log(`   TX: ${tx.hash}`);
                    await tx.wait();
                    console.log("   ✓ Distributions flushed!");
                } catch (e) {
                    console.log("   Flush skipped (nothing to flush).");
                }

                // End the cycle (sweeps unclaimed to treasury)
                console.log("2. Ending cycle (sweeping unclaimed to treasury)...");
                const tx = await contract.endCycle({ gasLimit: 2000000 });
                console.log(`   TX: ${tx.hash}`);
                await tx.wait();
                console.log("   ✓ Cycle ended! Unclaimed rewards swept to treasury.");
                console.log("   ✓ New accumulation phase started.");

            } else {
                const remaining = cycleInterval.toNumber() - elapsed;
                console.log(`Not yet time to end. ${remaining}s remaining.`);
            }
        }

        console.log("\n✓ Cron job complete.");

    } catch (error) {
        console.error("\n✗ Error:", error.reason || error.message);
        if (error.error?.data) {
            console.error("  Data:", error.error.data);
        }
        process.exit(1);
    }
}

run().then(() => process.exit(0));
