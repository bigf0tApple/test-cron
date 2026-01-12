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
    "function takeSnapshots() external",
    "function startClaimPhase() external",
    "function endCycle() external",
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
        const now = Math.floor(Date.now() / 1000);

        console.log(`Cycle ID: ${cycleId}`);
        console.log(`Is Distribution Active: ${isDistActive}`);
        console.log(`Cycle Interval: ${cycleInterval.toString()} seconds`);

        if (!isDistActive) {
            // We are in ACCUMULATION PHASE
            const accStartTime = await contract.accStartTime();
            const elapsed = now - accStartTime.toNumber();
            console.log(`Accumulation Phase - Elapsed: ${elapsed}s / ${cycleInterval.toString()}s`);

            if (elapsed >= cycleInterval.toNumber()) {
                console.log("Accumulation phase complete! Taking snapshots...");

                // Step 1: Take Snapshots
                let tx = await contract.takeSnapshots({ gasLimit: 2000000 });
                console.log(`takeSnapshots TX: ${tx.hash}`);
                await tx.wait();
                console.log("Snapshots taken!");

                // Step 2: Start Claim Phase
                console.log("Starting claim phase...");
                tx = await contract.startClaimPhase({ gasLimit: 500000 });
                console.log(`startClaimPhase TX: ${tx.hash}`);
                await tx.wait();
                console.log("Claim phase started! Distribution is now active.");
            } else {
                const remaining = cycleInterval.toNumber() - elapsed;
                console.log(`Not yet time. ${remaining}s remaining until snapshot.`);
            }
        } else {
            // We are in DISTRIBUTION PHASE
            const distStartTime = await contract.distStartTime();
            const elapsed = now - distStartTime.toNumber();
            console.log(`Distribution Phase - Elapsed: ${elapsed}s / ${cycleInterval.toString()}s`);

            if (elapsed >= cycleInterval.toNumber()) {
                console.log("Distribution phase complete! Ending cycle...");

                const tx = await contract.endCycle({ gasLimit: 2000000 });
                console.log(`endCycle TX: ${tx.hash}`);
                await tx.wait();
                console.log("Cycle ended! New accumulation phase started.");
            } else {
                const remaining = cycleInterval.toNumber() - elapsed;
                console.log(`Not yet time. ${remaining}s remaining until cycle end.`);
            }
        }

        console.log("Cron job complete.");

    } catch (error) {
        console.error("Error running cron:", error.reason || error.message);
        process.exit(1);
    }
}

run().then(() => process.exit(0));
