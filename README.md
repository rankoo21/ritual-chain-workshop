# Privacy-Preserving AI Bounty Judge — Commit-Reveal (Ritual workshop submission)

Fork of `cozfuttu/ritual-chain-workshop`. This submission secures the bounty
process so that **submissions stay hidden until judging is complete**, fixing
the original flaw where answers were public and could be copied and improved.

- **Required Track:** a commit-reveal flow in Solidity that works on **any EVM
  chain** — `hardhat/contracts/CommitRevealBounty.sol`.
- **Advanced Track:** a **Ritual-native** variant doing TEE-backed **batch** AI
  judging via the LLM inference precompile (`0x0802`) —
  `hardhat/contracts/RitualCommitRevealBounty.sol`.

## The flaw we fixed

The original `hardhat/contracts/AIJudge.sol` stored answers in plaintext via
`submitAnswer`. Every pending submission was world-readable, so a participant
could read existing answers, tweak them, and submit a "better" version before
the deadline. We replace open submission with a **commit-reveal** flow.

## Where things live

| Path | What |
|------|------|
| `hardhat/contracts/CommitRevealBounty.sol` | Commit-reveal core, any EVM chain. AI judging isolated behind the `_runJudge` hook. |
| `hardhat/contracts/RitualCommitRevealBounty.sol` | Ritual variant; overrides `_runJudge` to call LLM precompile `0x0802` for batch judging. |
| `hardhat/test/CommitRevealBounty.t.sol` | 26 unit + fuzz tests (Foundry-style, runs under Hardhat 3 Solidity tests). |
| `hardhat/test/RitualForkBounty.t.sol` | 4 fork tests against live Ritual Chain state. |
| `scripts/e2e.mjs` | Real on-chain lifecycle on Ritual with a **real AI judging call**. |
| `scripts/check.mjs` | Prints public address + balance for your `.env` key (never the key). |
| `ARCHITECTURE.md` | Data-flow note + Advanced (hidden-submission) design. |
| `TEST_PLAN.md` | Reveal-case test plan + fork + E2E results. |
| `REFLECTION.md` | Reflection answer. |

## Lifecycle

```
 createBounty            submitCommitment        revealAnswer          judgeAll        finalizeWinner
 (owner funds)   ─────▶  (hash only, hidden) ─▶  (answer + salt)  ─▶  (batch AI)  ─▶  (human picks winner, pays)
                  │                          │                    │               │
   Phase:     SUBMISSION  ── deadline ──▶  REVEAL  ── deadline ──▶  JUDGED  ─────▶  FINALIZED
```

1. **createBounty(title, rubric, submissionDeadline, revealDeadline)** `payable`
   Owner funds the reward and sets two deadlines. The rubric is public.
2. **submitCommitment(bountyId, commitment)** — only the hash
   `keccak256(abi.encode(answer, salt, msg.sender, bountyId))` goes on-chain.
   Nothing about the answer is observable. One commitment per address.
3. **revealAnswer(bountyId, answer, salt)** — after the submission deadline and
   before the reveal deadline. The contract recomputes the hash and checks it
   matches. Only matching reveals are valid.
4. **judgeAll(bountyId, llmInput)** — owner only, after the reveal deadline.
   A **single batch** AI call over all revealed answers. On Ritual this hits the
   LLM precompile; the review is stored on-chain.
5. **finalizeWinner(bountyId, winnerIndex)** — owner only. A human selects the
   winner (informed by the AI review). Winner must have a valid revealed answer.

## Why the commitment binds four fields

`keccak256(abi.encode(answer, salt, msg.sender, bountyId))`

- **answer** — what is committed to.
- **salt** — high entropy so short/guessable answers can't be brute-forced.
- **msg.sender** — no one can reveal on behalf of another participant.
- **bountyId** — a commitment can't be replayed across bounties.

Each has a dedicated negative test (see `TEST_PLAN.md`).

## Build & test

The repo's `hardhat/` already depends on `forge-std`, so the Solidity tests run
with Foundry directly:

```bash
cd hardhat
forge test -vvv                 # 26 unit + fuzz tests

# fork tests against live Ritual state:
#   pwsh: $env:RITUAL_RPC_URL="https://rpc.ritualfoundation.org"
forge test --match-contract RitualForkBounty --fork-url $RITUAL_RPC_URL -vvv
```

> `forge` may exit non-zero only due to `block-timestamp` lint *warnings*
> (expected for a deadline-based scheme); compilation and tests still succeed —
> check the suite summary line.

## Real on-chain end-to-end test (Advanced Track proof)

`scripts/e2e.mjs` runs the COMPLETE lifecycle on Ritual Chain with a **real AI
judging call** (LLM precompile `0x0802` in a TEE), not a simulation:

```bash
cd scripts
npm install
# put a faucet-funded TESTNET key in scripts/.env (see scripts/README.md)
node check.mjs
npm run e2e
```

Verified run output:

```
During submission -> revealed: false | stored answer length: 0   <- answer is HIDDEN
Revealing answer...
Revealed count: 1
Calling judgeAll with real LLM input (async settlement)...
judgeAll status: success
judged = true
aiReview bytes length = 1408            <- real LLM verdict stored on-chain
finalizeWinner status: success
```

`stored answer length: 0` during submission is the whole point: the plaintext
answer is never on-chain until reveal.

## Deploy on Ritual

Deploy `RitualCommitRevealBounty` (chainId 1979). Before `judgeAll`, fund the
owner EOA in `RitualWallet` so the async LLM settlement can pay its fee (~0.31
RITUAL per batch call in our run), and encode the 30-field batch LLM request
off-chain (see `ARCHITECTURE.md`, `scripts/e2e.mjs`, and the `ritual-dapp-llm`
skill).
