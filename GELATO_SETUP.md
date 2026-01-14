# Gelato Epoch Automation for 66M Rewards

## Key Insight

**`distributeAuto()` is NOT needed as a Gelato task!**  
It's already called piggyback on every token transfer in `MainToken.sol`:
```solidity
try rewardsContract.distributeAuto() {} catch {}
```

---

## Timing Sequence (Within Each 6h Epoch)

```
ACCUMULATION CYCLE (6 hours)
├── 0:00 - 5:50   → ETH flows in from tax
├── 5:50          → takeSnapshots() [Gelato Task 1]
├── 5:51          → buyRewardToken() [Gelato Task 2 - if set]
├── 5:55          → startClaimPhase() [Gelato Task 3]
│                   ↳ Starts NEXT accumulation
│                   ↳ Starts DISTRIBUTION of this epoch
│
DISTRIBUTION CYCLE (6 hours, parallel to next accumulation)
├── 0:00 - 5:55   → distributeAuto() via token transfers (automatic)
│                 → Users claim manual 30% on website
├── 5:55          → endCycle() [Gelato Task 4]
│                   ↳ Flush remaining distributions
│                   ↳ Sweep unclaimed → swap → ETH → TREASURWEE
└── 6:00          → Distribution complete
```

---

## Precise Gelato Task Schedule

**All tasks repeat every 6 hours, with these offsets from epoch start:**

| # | Task Name | Function | Offset | When (if epoch starts 00:00) |
|---|-----------|----------|--------|------------------------------|
| 1 | 66M-TakeSnapshot | `takeSnapshots()` | +5h50m | 05:50 |
| 2 | 66M-BuyReward | `buyRewardToken()` | +5h51m | 05:51 |
| 3 | 66M-StartClaim | `startClaimPhase()` | +5h55m | 05:55 |
| 4 | 66M-EndCycle | `endCycle()` | +5h55m (from dist start) | 11:55 |

**Note:** Task 4 runs 6h after Task 3, not from the same epoch start.

---

## Gelato Configuration

### Contract
```
Address: 0x9945116E0f2B6fB6ba5A3d1a3aA938bf6B7211CF
Network: Base Mainnet
```

### Task 1: 66M-TakeSnapshot
- **Function:** `takeSnapshots()`
- **Trigger:** Time-based, every 6 hours
- **Start time:** Align to `accStartTime + 21000` seconds (5h50m)

### Task 2: 66M-BuyReward  
- **Function:** `buyRewardToken()`
- **Trigger:** Time-based, every 6 hours
- **Start time:** 1 minute after Task 1

### Task 3: 66M-StartClaim
- **Function:** `startClaimPhase()`
- **Trigger:** Time-based, every 6 hours
- **Start time:** 5 minutes after Task 1

### Task 4: 66M-EndCycle
- **Function:** `endCycle()`
- **Trigger:** Time-based, every 6 hours
- **Start time:** 6 hours after Task 3

---

## ABI for Gelato

```json
[
  "function takeSnapshots() external",
  "function buyRewardToken() external",
  "function startClaimPhase() external",
  "function endCycle() external"
]
```

---

## Current Epoch Timing

Check current `accStartTime`:
```bash
cast call 0x9945116E0f2B6fB6ba5A3d1a3aA938bf6B7211CF "accStartTime()" --rpc-url https://mainnet.base.org
```

Calculate your Gelato start times from that timestamp.
