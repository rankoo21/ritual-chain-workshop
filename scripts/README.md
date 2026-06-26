# E2E scripts — real on-chain lifecycle on Ritual Chain

These scripts run the commit-reveal bounty **for real** on Ritual Chain
(chainId 1979), including a **real AI judging call** via the LLM inference
precompile (`0x0802`) inside a TEE executor.

## Files

- `e2e.mjs` — full lifecycle: deploy → createBounty → submitCommitment →
  revealAnswer → judgeAll (real LLM) → finalizeWinner.
- `check.mjs` — derives ONLY your public address + balance from the `.env`
  private key (never prints the key). Use it to confirm funding before `e2e`.

## Setup

1. Install deps:
   ```bash
   npm install
   ```
2. Create a **throwaway testnet** key and put it in `scripts/.env`
   (copy from `.env.example`):
   ```
   PRIVATE_KEY=0x...        # TESTNET ONLY — never a real/mainnet key
   RITUAL_RPC_URL=https://rpc.ritualfoundation.org
   ```
   `.env` is gitignored, so the secret is never committed.
3. Fund the address at https://faucet.ritualfoundation.org
   (need ~1 RITUAL: the AI judging call alone costs ~0.31 RITUAL).
4. Confirm:
   ```bash
   node check.mjs
   ```
5. Run the full lifecycle:
   ```bash
   npm run e2e
   ```

## What a successful run looks like

```
During submission -> revealed: false | stored answer length: 0   <- HIDDEN
Revealing answer...
Revealed count: 1
Calling judgeAll with real LLM input (async settlement)...
judgeAll status: success
judged = true
aiReview bytes length = 1408            <- real LLM verdict on-chain
finalizeWinner status: success
Explorer: https://explorer.ritualfoundation.org/address/0x...
```

## Notes / gotchas (learned from real runs)

- **`block.timestamp` is in MILLISECONDS on Ritual.** Deadlines in the script
  use `chainNow + 120000n` (120s), not seconds. The contract is unit-agnostic —
  it just compares against `block.timestamp` — so deadlines must be in the same
  unit the chain uses.
- **RitualWallet must be funded for the EOA, not the contract.** Async precompile
  fees are charged to the signing EOA. The script deposits 0.5 RITUAL so the
  batch LLM settlement (~0.31 RITUAL) can pay.
- **Public RPC nonce flakiness.** The public RPC sometimes reports stale/cached
  nonces ("nonce too low" / "already known"). The script manages the nonce
  locally and retries on nonce errors — you may see
  `nonce conflict, retrying...` lines; that is expected and self-heals.
- **One commitment per address.** The contract enforces one submission per EOA
  per bounty (anti-spam). The script demonstrates a single participant
  end-to-end; for a multi-party demo, use multiple funded keys.
- **Judging is async.** `judgeAll` triggers a short-running async LLM call;
  the settled review is read back from the contract after the tx is mined.

## Security

- Use a **testnet throwaway key only**. RITUAL testnet tokens have no value.
- Never put a mainnet key or a key holding real funds in `.env`.
