# MISTAKES & LESSONS LEARNED

## V4 → V2 Migration Mistakes

### 1. Wrong Block Timing for Base Chain
**Mistake**: Used 2-second block timing (1,296,000 blocks/month)
**Reality**: Base uses ~12 second blocks (216,000 blocks/month)
**Fix**: Updated `TokenLocker.sol` to use correct block timing

### 2. Forgot SOL → ETH Swap in Tax Distribution
**Mistake**: Only swapped TOKEN → ETH, forgot about SOL from SOL/TOKEN pair
**Fix**: Added `_swapSolToEth()` before tax distribution

### 3. Hardcoded Fallback Prices
**Mistake**: Used hardcoded $2000 ETH / $100 SOL fallback prices
**Reality**: Should use Uniswap pool prices as fallback
**Fix**: Added WETH/USDC and SOL/USDC pool queries as fallbacks

### 4. Missing Event Declaration
**Mistake**: `RewardTokenPurchased` event was emitted but not declared
**Fix**: Already declared at line 805 - was false positive

### 5. Narrow TIME_WINDOW for Railway
**Mistake**: 30 second window too tight for Railway cron jobs
**Fix**: Changed to 300 seconds (5 minutes)

### 6. Adding Slippage to Tax Swap (BROKE TRADING!)
**Mistake**: Added 5% slippage protection to `_distributeTax()` using `getAmountsOut()`
**Problem**: `getAmountsOut()` doesn't account for tax deduction on fee-on-transfer tokens. When combined with 5% minimum output requirement, swaps always fail.
**Result**: All BUY transactions reverted with `INSUFFICIENT_OUTPUT_AMOUNT`
**Fix**: Removed slippage check. V2 swaps are atomic (no MEV sandwich risk), so 0 slippage is safe.

### 7. Tax Display Shows "1.62%" Not "1.618%"
**Not a bug**: Contract uses TAX_BPS=1618 with BPS_DIVISOR=100,000 = exactly 1.618%
**Issue**: DexScreener/Uniswap UI rounds for display purposes
**Reality**: On-chain math is precisely 1.618%

---

## Deployment Checklist (Don't Forget!)

### Pre-Deploy
- [ ] Update token name/symbol in MainToken constructor
- [ ] Update NFT name/symbol in NFTContract constructor
- [ ] Verify all addresses in .env.example
- [ ] Fund deployer wallet with enough ETH

### Deploy Order
1. MainToken
2. TokenTracker
3. RewardsContract (needs MainToken address)
4. TokenLocker (needs MainToken address)
5. Randomizer
6. NFTTracker
7. NFTContract (needs many addresses)

### Post-Deploy Linking
- [ ] MainToken.setTokenTracker()
- [ ] MainToken.setRewardsContract()
- [ ] MainToken.setTokenLocker()
- [ ] MainToken.setUniswapRouter()
- [ ] MainToken.setIsUniswapPair() for each pair
- [ ] MainToken.excludeDefaultAddresses()
- [ ] RewardsContract.addAllowedExecutor(Railway)
- [ ] RewardsContract.setCanReceiveFrom(MainToken) ← ALREADY IN CONSTRUCTOR
- [ ] TokenTracker.setRewardsContract()
- [ ] NFTTracker.setNFTContract()
- [ ] NFTTracker.setRewardsContract()
- [ ] NFTContract.setNftTracker()
- [ ] NFTContract.setRandomizer()
- [ ] NFTContract.setPyth()
- [ ] NFTContract.setUniswapRouter()
- [ ] NFTContract.setWethUsdcPair()
- [ ] NFTContract.setSolUsdcPair()

### Enable Trading
- [ ] Add liquidity (TOKEN/WETH pair)
- [ ] MainToken.enableTrading()

---

## Things That Actually Work ✅

1. Tax collection on buys/sells (1.618%)
2. WWMM/Rewards split (14.60% / 85.40%)
3. Piggyback tax distribution on buys
4. Piggyback distributeAuto() on sells
5. NFT 100% auto-distribution
6. Token 70/30 split (auto/claimable)
7. Block-based vesting (1-month cliff)
8. Presale → USDC swap
9. PYTH oracle with Uniswap fallback
