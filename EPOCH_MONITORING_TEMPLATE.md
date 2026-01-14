# Epoch Transition Monitoring Report

## Run Information
| Metric | Value |
|--------|-------|
| Run Timestamp | |
| Cycle ID | |
| Scheduled Time | |
| Actual Start Time | |
| Total Duration | |
| Railway Cost | |

---

## Timing Metrics
| Check | Status | Notes |
|-------|--------|-------|
| Was run on time (within 5 min window)? | ⬜ | |
| Time since last epoch (should be ~6h) | | |
| Accumulation elapsed time | | |
| Distribution elapsed time (if active) | | |

---

## Transaction Summary
| Function | TX Hash | Gas Used | Gas Cost (ETH) | Status |
|----------|---------|----------|----------------|--------|
| `takeSnapshots()` | | | | ⬜ |
| `buyRewardToken()` | | | | ⬜ |
| `startClaimPhase()` | | | | ⬜ |
| `flushDistributions()` | | | | ⬜ |
| `endCycle()` | | | | ⬜ |

**Total Gas Cost:** 

---

## Contract State Before
| Parameter | Value |
|-----------|-------|
| `isDistActive` | |
| `currentDisplayCycleId` | |
| `rewardToken` | |
| `accStartTime` | |
| Contract ETH Balance | |
| `getAvailableEthForBuy()` | |

---

## Contract State After
| Parameter | Value |
|-----------|-------|
| `isDistActive` | |
| `currentDisplayCycleId` | |
| `accStartTime` (new) | |
| Contract ETH Balance | |

---

## Reward Token Purchase
| Metric | Value |
|--------|-------|
| Reward Token Address | |
| ETH Spent on Buy | |
| Tokens Received | |
| Effective Price (ETH/token) | |

---

## Snapshot Results
| Pool | Total Points | Holder Count |
|------|--------------|--------------|
| NFT Pool | | |
| Token Pool | | |

---

## Distribution Tracking
| Metric | Value |
|--------|-------|
| NFT Auto Pool Size | |
| Token Auto Pool Size | |
| Token Manual Pool Size | |
| Distribution Started? | ⬜ |

---

## Sweep Summary (if endCycle ran)
| Metric | Value |
|--------|-------|
| Unclaimed Manual Pool | |
| NFT Excess Points Value | |
| Total Swept | |
| Swapped to ETH | |
| Sent to Treasury | |
| Treasury TX | |

---

## Errors & Issues
| Issue | Details |
|-------|---------|
| | |

---

## Next Epoch
| Metric | Value |
|--------|-------|
| Next Snapshot Window | |
| Next Claim Phase | |
| Expected Transition | |

---

## Verification Checklist
- [ ] Railway logs show successful execution
- [ ] All transactions confirmed on BaseScan
- [ ] Cycle ID incremented
- [ ] New accumulation started (`accStartTime` updated)
- [ ] Distribution started (`isDistActive` = true)
- [ ] Reward token purchased (if set)
- [ ] No reverted transactions
- [ ] Treasury received sweep (if applicable)
