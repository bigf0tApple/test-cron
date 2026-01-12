require('dotenv').config();
const { ethers } = require('ethers');

// Configuration
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const REWARDS_CONTRACT = process.env.REWARDS_CONTRACT;

// Minimal ABI for endCycle
const ABI = [
    "function endCycle() external",
    "function cycleInterval() external view returns (uint256)",
    "function getTimeUntilNextCycle() external view returns (uint256)",
    "function currentDisplayCycleId() external view returns (uint256)"
];

async function run() {
    console.log(`[${new Date().toISOString()}] Starting Cron Job...`);

    if (!PRIVATE_KEY || !REWARDS_CONTRACT) {
        console.error("Missing env vars: PRIVATE_KEY or REWARDS_CONTRACT");
        process.exit(1);
    }

    try {
        const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
        const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
        const contract = new ethers.Contract(REWARDS_CONTRACT, ABI, wallet);

        console.log("Connected to wallet:", wallet.address);
        console.log("Contract:", REWARDS_CONTRACT);

        // Check if cycle is over
        const timeLeft = await contract.getTimeUntilNextCycle();
        const cycleId = await contract.currentDisplayCycleId();

        console.log(`Current Cycle ID: ${cycleId}`);
        console.log(`Time Left: ${timeLeft.toString()} seconds`);

        if (timeLeft.eq(0)) {
            console.log("Cycle is over! Triggering endCycle()...");

            // Gas estimation (optional but good practice)
            // const gasLimit = await contract.estimateGas.endCycle(); 
            // Using hardcoded gas limit to be safe if estimation fails due to weird state
            const tx = await contract.endCycle({ gasLimit: 500000 });

            console.log(`Transaction sent: ${tx.hash}`);
            await tx.wait();
            console.log("Transaction confirmed! Cycle ended.");
        } else {
            console.log("Not yet time to end cycle.");
        }

    } catch (error) {
        console.error("Error running cron:", error);
        process.exit(1);
    }
}

// Run immediately safely
run().then(() => {
    // Keep process alive for a moment to ensure logs flush? No, just exit.
    process.exit(0);
});
