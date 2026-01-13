# WEE Rewards Cron Service

Automated Railway service for epoch transitions in the WEE RewardsContract.

## How It Works

Every 3 hours, this service:
1. **Closes the previous epoch** (if active)
   - Flushes remaining distributions
   - Sweeps unclaimed rewards → Treasury (swaps tokens → ETH first)
2. **Starts new distribution**
   - Takes holder snapshots
   - Buys reward tokens with accumulated ETH
   - Allocates to NFT/Token pools
3. **New accumulation begins automatically**

## Overlapping Epochs

```
Hour 0-3:  Epoch 0 Accumulating
Hour 3-6:  Epoch 0 Distributing  +  Epoch 1 Accumulating
Hour 6-9:  Epoch 1 Distributing  +  Epoch 2 Accumulating
```

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `PRIVATE_KEY` | Executor wallet private key | `0x1234...` |
| `REWARDS_CONTRACT` | RewardsContract address | `0xABCD...` |
| `RPC_URL` | Base RPC endpoint (optional) | `https://mainnet.base.org` |

## Railway Setup

1. Connect this repository to Railway
2. Set environment variables in Railway dashboard
3. Configure cron schedule: `0 */3 * * *` (every 3 hours on the hour)

## Local Testing

```bash
cp .env.example .env
# Edit .env with your values
npm install
node index.js
```

## Call Sequence with Delays

```
flushDistributions()  → 2s delay
endCycle()            → 2s delay
takeSnapshots()       → 2s delay
buyRewardToken()      → 2s delay
startClaimPhase()
```

Total time: ~30 seconds including transaction confirmations.

## Error Handling

- If any call fails, the cron exits with error code 1
- Railway will retry on next scheduled run
- Failed transactions do NOT corrupt contract state (reverts are safe)
