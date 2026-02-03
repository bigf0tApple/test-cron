/**
 * ====================================================================
 * WEEV2 ARB MONITOR - RAILWAY CRON SERVICE
 * ====================================================================
 * 
 * Polls ARBContract.getArbInfo() every 10 seconds.
 * If an arb opportunity exists (gap >= 2%), calls WWMM.keeperTrigger()
 * 
 * This is a BACKUP for the piggyback system - catches missed opportunities.
 * 
 * Cost estimate:
 * - Reads: FREE (no gas, just RPC calls)
 * - Writes: ~0.01-0.02 ETH per arb (only when opportunity exists)
 * 
 * ====================================================================
 */

require('dotenv').config();
const { ethers } = require('ethers');

// ====== CONFIGURATION ======
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const PRIVATE_KEY = process.env.RAILWAY_PRIVATE_KEY;

// Contract addresses - UPDATE THESE AFTER DEPLOYMENT
const ARB_CONTRACT = process.env.ARB_CONTRACT || '';
const WWMM_CONTRACT = process.env.WWMM_CONTRACT || '';

// Polling interval in milliseconds (10 seconds)
const POLL_INTERVAL_MS = 10000;

// Minimum gap to log (in bps) - just for logging, contract handles threshold
const LOG_GAP_THRESHOLD = 100; // 1%

// Minimum ETH balance to keep the keeper running
const MIN_ETH_BALANCE = ethers.utils.parseEther('0.001');

// ====== ABIs ======
const ARB_ABI = [
    "function getArbInfo() external view returns (bool available, bool wethPoolExpensive, uint256 optimalAmount)",
    "function gapThresholdBps() external view returns (uint256)"
];

const WWMM_ABI = [
    "function keeperTrigger() external",
    "function keepers(address) external view returns (bool)",
    "function paused() external view returns (bool)"
];

// ====== STATE ======
let provider;
let wallet;
let arbContract;
let wwmmContract;
let lastArbTime = 0;
let totalArbs = 0;
let totalGasUsed = ethers.BigNumber.from(0);

// ====== HELPERS ======
function log(msg) {
    console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function checkAndTriggerArb() {
    try {
        // 1. Check if arb opportunity exists
        const [available, wethPoolExpensive, optimalAmount] = await arbContract.getArbInfo();

        if (!available) {
            // No opportunity - silent (don't spam logs)
            return { triggered: false, reason: 'no_opportunity' };
        }

        // 2. Log the opportunity
        const amountFormatted = ethers.utils.formatEther(optimalAmount);
        const direction = wethPoolExpensive ? 'WETH→SOL' : 'SOL→WETH';
        log(`🎯 ARB OPPORTUNITY: ${direction}, ${amountFormatted} tokens`);

        // 3. Check if WWMM is paused
        const isPaused = await wwmmContract.paused();
        if (isPaused) {
            log(`⚠️ WWMM is paused, skipping`);
            return { triggered: false, reason: 'wwmm_paused' };
        }

        // 4. Check if we're an authorized keeper
        const isKeeper = await wwmmContract.keepers(wallet.address);
        if (!isKeeper) {
            log(`❌ Wallet ${wallet.address} is not an authorized keeper`);
            return { triggered: false, reason: 'not_keeper' };
        }

        // 5. Check ETH balance
        const balance = await provider.getBalance(wallet.address);
        if (balance.lt(MIN_ETH_BALANCE)) {
            log(`❌ Low ETH balance: ${ethers.utils.formatEther(balance)}`);
            return { triggered: false, reason: 'low_balance' };
        }

        // 6. Execute the arb via keeperTrigger
        log(`🚀 Triggering arb...`);
        const tx = await wwmmContract.keeperTrigger({
            gasLimit: 800000  // Should be enough for 4-hop arb
        });

        log(`📤 TX sent: ${tx.hash}`);
        const receipt = await tx.wait();

        // 7. Update stats
        totalArbs++;
        totalGasUsed = totalGasUsed.add(receipt.gasUsed.mul(receipt.effectiveGasPrice));
        lastArbTime = Date.now();

        log(`✅ ARB SUCCESS! Gas: ${receipt.gasUsed.toString()}, Total arbs: ${totalArbs}`);

        return { triggered: true, txHash: tx.hash };

    } catch (error) {
        // Check if it's a "Cycle not complete" or similar expected error
        const reason = error.reason || error.message;
        if (reason.includes('No arb opportunity') || reason.includes('Gap below threshold')) {
            // Expected - opportunity closed between check and execute
            return { triggered: false, reason: 'opportunity_closed' };
        }

        log(`❌ Error: ${reason}`);
        return { triggered: false, reason: 'error', error: reason };
    }
}

async function runLoop() {
    log(`${'═'.repeat(50)}`);
    log(`WEEV2 ARB MONITOR STARTED`);
    log(`${'═'.repeat(50)}`);
    log(`Polling every ${POLL_INTERVAL_MS / 1000} seconds`);
    log(`ARB Contract: ${ARB_CONTRACT}`);
    log(`WWMM Contract: ${WWMM_CONTRACT}`);
    log(`Keeper Wallet: ${wallet.address}`);

    // Check initial balance
    const balance = await provider.getBalance(wallet.address);
    log(`Wallet Balance: ${ethers.utils.formatEther(balance)} ETH`);

    // Check if authorized
    const isKeeper = await wwmmContract.keepers(wallet.address);
    if (!isKeeper) {
        log(`\n⚠️ WARNING: Wallet is NOT an authorized keeper!`);
        log(`Run: wwmmContract.setKeeper("${wallet.address}", true)`);
    } else {
        log(`✅ Wallet is authorized keeper`);
    }

    // Get threshold
    const threshold = await arbContract.gapThresholdBps();
    log(`Gap Threshold: ${threshold.toString()} bps (${threshold.toNumber() / 100}%)`);

    log(`\n${'─'.repeat(50)}\n`);

    // Main polling loop
    while (true) {
        await checkAndTriggerArb();

        // Wait for next poll
        await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL_MS));
    }
}

// ====== MAIN ======
async function main() {
    // Validate config
    if (!PRIVATE_KEY) {
        console.error("❌ Missing RAILWAY_PRIVATE_KEY in .env");
        process.exit(1);
    }

    if (!ARB_CONTRACT || !WWMM_CONTRACT) {
        console.error("❌ Missing ARB_CONTRACT or WWMM_CONTRACT in .env");
        process.exit(1);
    }

    // Initialize
    provider = new ethers.providers.JsonRpcProvider(RPC_URL);
    wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    arbContract = new ethers.Contract(ARB_CONTRACT, ARB_ABI, wallet);
    wwmmContract = new ethers.Contract(WWMM_CONTRACT, WWMM_ABI, wallet);

    // Run forever
    await runLoop();
}

main().catch((e) => {
    console.error(`\n❌ FATAL: ${e.message}`);
    process.exit(1);
});
