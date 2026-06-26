# Test Plan — Reveal Cases

Run with `forge test -vvv`. All 26 tests pass (25 unit + 1 fuzz, 256 runs).

## Commitment binding (the core of reveal security)

| # | Test | What it proves |
|---|------|----------------|
| 1 | `test_Reveal_Valid` | A correct (answer, salt) reproduces the commitment and is accepted. |
| 2 | `test_Reveal_RevertWrongSalt` | Right answer + wrong salt → `commitment mismatch`. |
| 3 | `test_Reveal_RevertWrongAnswer` | Tampered answer + right salt → `commitment mismatch`. |
| 4 | `test_Reveal_RevertImpersonation` | A non-committer cannot reveal someone else's answer (`no commitment`). `msg.sender` is bound into the hash. |
| 5 | `test_Reveal_RevertCrossBountyReplay` | A commitment computed for bounty A cannot be revealed in bounty B (`commitment mismatch`). `bountyId` is bound in. |
| 6 | `testFuzz_OnlyMatchingRevealSucceeds` | Fuzzed: any `salt != wrongSalt` always fails to reveal. |

## Reveal timing / state

| # | Test | What it proves |
|---|------|----------------|
| 7 | `test_Reveal_RevertBeforeSubmissionDeadline` | Cannot reveal while submissions are still open. |
| 8 | `test_Reveal_RevertAfterRevealDeadline` | Cannot reveal after the reveal window closes. |
| 9 | `test_Reveal_RevertDoubleReveal` | A submission can be revealed only once. |
| 10 | `test_Reveal_RevertAnswerTooLong` | Oversized answers are rejected at reveal. |

## Commit phase (hiding)

| # | Test | What it proves |
|---|------|----------------|
| 11 | `test_Commit_HidesAnswer` | During submission the stored answer is empty; only the hash is visible. |
| 12 | `test_Commit_RevertDoubleCommit` | One commitment per address per bounty (anti-spam). |
| 13 | `test_Commit_RevertEmptyCommitment` | Zero-hash commitments rejected. |
| 14 | `test_Commit_RevertAfterDeadline` | No commitments after the submission deadline. |

## Judging (batch, owner-gated)

| # | Test | What it proves |
|---|------|----------------|
| 15 | `test_JudgeAll_BatchesRevealedAnswers` | Exactly one batch judging call covers all revealed answers; review stored. |
| 16 | `test_JudgeAll_RevertNotOwner` | Only the owner can judge. |
| 17 | `test_JudgeAll_RevertWhileRevealOpen` | Cannot judge before the reveal window closes. |
| 18 | `test_JudgeAll_RevertNoRevealedAnswers` | Cannot judge if nobody revealed (committed-but-silent excluded). |
| 19 | `test_JudgeAll_RevertDoubleJudge` | Judging happens once. |

## Finalize (human decision + payout)

| # | Test | What it proves |
|---|------|----------------|
| 20 | `test_FinalizeWinner_PaysRevealedWinner` | Reward transfers to the chosen revealed submitter. |
| 21 | `test_FinalizeWinner_RevertBeforeJudge` | Cannot finalize before judging. |
| 22 | `test_FinalizeWinner_RevertUnrevealedWinner` | A committed-but-unrevealed submission cannot win. |
| 23 | `test_FinalizeWinner_RevertDoubleFinalize` | Finalization happens once (reward can't be drained twice). |

## Creation guards

| # | Test | What it proves |
|---|------|----------------|
| 24 | `test_CreateBounty_StoresStateAndPhase` | Initial state + `Submission` phase. |
| 25 | `test_CreateBounty_RevertNoReward` | Reward required. |
| 26 | `test_CreateBounty_RevertBadDeadlines` | Reveal deadline must follow submission deadline. |

## Fork tests — against live Ritual Chain state

File: `test/RitualForkBounty.t.sol`. Run:

```
$env:RITUAL_RPC_URL="https://rpc.ritualfoundation.org"
forge test --match-contract RitualForkBounty --fork-url $env:RITUAL_RPC_URL -vvv
```

| # | Test | What it proves |
|---|------|----------------|
| F1 | `test_Fork_SystemContractsExist` | We really are on chainId 1979; RitualWallet + TEE registry have code. |
| F2 | `test_Fork_RitualWalletDeposit` | The real RitualWallet deposit path (used to pay for async AI judging) works live. |
| F3 | `test_Fork_CommitRevealFinalizeLifecycle` | Full commit → reveal lifecycle on real chain state; answer hidden during submission. |
| F4 | `test_Fork_TamperedRevealRejected` | A tampered reveal is rejected against live state too. |

Result: `4 passed`.

## Real on-chain E2E — with live AI judging

File: `scripts/e2e.mjs` (see `scripts/README.md`). Sends real transactions to
Ritual Chain and a real LLM inference (`0x0802`) for batch judging.

Verified run output:

| Step | Result |
|------|--------|
| deploy `RitualCommitRevealBounty` | success |
| `createBounty` | bounty id = 1 |
| `submitCommitment` | **stored answer length: 0** (answer hidden on-chain) |
| `revealAnswer` | revealed count = 1 |
| `judgeAll` (real LLM, async) | status: success — `aiReview` = 1408 bytes on-chain |
| `finalizeWinner` | status: success (reward paid to revealed winner) |

This is the end-to-end proof that answers stay hidden until judging, and that
judging is a single real batch AI call.
