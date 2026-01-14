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

### 8. Auto Pools Swept to Treasury Instead of Distributed
**Mistake**: `endCycle()` was sweeping `remainingNftAuto + remainingTokenAuto` to treasury
**Problem**: Auto pools should be DISTRIBUTED to holders, not sent to treasury
**What SHOULD go to treasury**: Only `excessNftRewards` (beyond 342 cap) + `unclaimedTokenManual`
**Fix**: Updated `endCycle()` to only sweep excess/unclaimed, not auto pools
**Status**: ⚠️ FIXED IN SOURCE - REQUIRES REDEPLOYMENT

### 9. enableTrading() Never Called After Deployment (2026-01-14)
**Mistake**: After deploying 66M contracts and adding liquidity, `enableTrading()` was never called
**Problem**: Tax collection code requires `launchBlock > 0` to apply taxes:
```solidity
if (launchBlock > 0 && (isBuy || isSell)) {
    // Tax only collected when launchBlock is set
}
```
**Result**: 24 hours of trading with **ZERO tax collected** - all trades were tax-free
**Why Trading Still Worked**: Transfers aren't blocked, only the tax calculation is skipped
**Fix**: Called `enableTrading()` - TX `0xd9bb886daf9692e8fa2a3a831743ed9afb82183afe557af91f67a44355004e2f`
**Lesson**: Add `enableTrading()` to deployment checklist AND verify `getTaxStats()` after first trade
**Status**: ✅ FIXED - Taxes now collecting properly (launchBlock = 40804276)

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

### Enable Trading (⚠️ CRITICAL!)
- [ ] Add liquidity (TOKEN/WETH pair)
- [ ] **MainToken.enableTrading()** ← DO NOT FORGET!
- [ ] Verify with `getTaxStats()` after first trade to confirm taxes collecting

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

---

## 66M Deployment (2026-01-13)

### Deployed Contracts (Base Mainnet Block 40758777)
| Contract | Address |
|----------|---------|
| MainToken (66M/66M) | `0x49250e21a4fdfe969172a5548de96104dae7d26f` |
| TokenTracker | `0x4995DcA875f2aafA1f2694dF1B3bD6eFfcd2995C` |
| NFTTracker | `0x64c415a80be6fbd8f24fd14744a70adc277f3362` |
| Rewards | `0x9945116E0f2B6fB6ba5A3d1a3aA938bf6B7211CF` |
| TokenLocker | `0xb3960d6fbA22F122614ea0B559BC1d18f7184874` |

### Tokenomics (4-Wallet Vesting)
| Wallet | Amount | % |
|--------|--------|---|
| Dev | 134.7M | 13.47% |
| Core | 115.2M | 11.52% |
| Spillage | 57.2M | 5.72% |
| Free Wee | 74.9M | 7.49% |
| Deployer (Presale+LP) | 618M | 61.8% |

### 38-Month Decaying Vesting
- Period 1 (Months 1-10): 1.0x rate
- Period 2 (Months 11-22): 0.75x rate
- Period 3 (Months 23-38): 0.375x rate

### What Was Done
1. ✅ Recovered funds from old 66Mtest contracts (RewardsContract ETH + TokenLocker tokens)
2. ✅ Deployed new 66M token ecosystem via Deploy66M.s.sol
3. ✅ All linking done in deployment script (setTokenTracker, setRewardsContract, setTokenLocker, setUniswapRouter)
4. ⏳ Still needed: NFT deployment, Uniswap pair creation, enableTrading()

### New Features Added
- Piggyback token flush in NFTContract: `_flushTokensToMintFund()` forwards accumulated tokens to NFT_MINT_FUND on every mint

