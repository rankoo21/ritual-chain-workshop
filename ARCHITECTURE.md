# Architecture Note

## 1. Required Track — Commit-Reveal (any EVM chain)

### What is stored on-chain
- During **submission**: only the commitment hash
  `keccak256(abi.encode(answer, salt, msg.sender, bountyId))`. The plaintext
  answer never touches the chain in this phase.
- During **reveal**: the plaintext answer + the `revealed` flag. Plaintext is
  now public — but that is fine, because the submission window has closed and no
  one can submit a new commitment after seeing it.
- The AI review bytes are stored after `judgeAll` for auditability.

### Where plaintext answers exist
- **Submission phase:** only in the participant's own client/wallet. Nowhere
  on-chain, nowhere shared.
- **Reveal phase:** broadcast in the `revealAnswer` calldata and stored on-chain.

### Security properties
- **Hiding:** the salt gives the commitment high entropy, so short or guessable
  answers can't be recovered by brute-forcing the hash during submission.
- **Binding:** once committed, a participant cannot change their answer — the
  reveal must reproduce the exact hash.
- **No impersonation / no replay:** `msg.sender` and `bountyId` are inside the
  hash.
- **Anti-spam:** one commitment per address per bounty; a bounded submission cap.
- **Liveness:** a participant who never reveals is simply excluded from judging;
  an unrevealed submission can never be selected as winner.

### Trust model
The AI **assists** (`judgeAll` produces a review over the batch), but a human
owner makes the final, accountable decision in `finalizeWinner`. Funds only move
on the human action, to a submitter who actually revealed a valid answer.

## 2. Advanced Track — Ritual-native hidden submissions (TEE)

Goal: answers remain **encrypted even through judging**, so plaintext is never
public on-chain at all — not even after a reveal.

```
participant                          chain                         TEE executor (enclave)
-----------                          -----                         ----------------------
encrypt(answer) to executor pubkey
(ECIES)  ──────────────────────────▶ store ciphertext on-chain
                                     (commitment optional, for
                                      anti-tamper binding)
                                            │
 owner: judgeAll(bountyId, llmInput) ──────▶ LLM precompile 0x0802 ─▶ decrypt all answers
                                                                      inside enclave,
                                                                      judge the BATCH,
                                                                      emit only the verdict
                                     verdict bytes ◀──────────────────┘
 finalizeWinner(winnerIndex) ◀────── human reviews verdict
```

### Where plaintext answers exist (Advanced)
- **Participant side:** plaintext exists only in the participant's client before
  encryption.
- **On-chain:** only ciphertext (ECIES-encrypted to the executor's public key)
  and/or a commitment hash. Never plaintext.
- **Inside the TEE:** plaintext exists transiently inside the enclave during the
  single batch inference, then is discarded. It never leaves the enclave.
- **Output:** only the AI verdict/ranking leaves the enclave and lands on-chain.

### On-chain vs off-chain
- **On-chain:** bounty metadata, rubric, ciphertext blobs (or commitments),
  deadlines, the AI verdict, the finalized winner, escrowed reward.
- **Off-chain (enclave / DA):** decrypted answers (transient, in-enclave),
  optional conversation history JSONL on the DA provider (GCS/HF/Pinata).

### How the LLM receives submissions for batch judging
All revealed/encrypted answers are packed into a **single** `messagesJson`
payload (one `judgeAll` → one inference call), not one call per answer. This
respects Ritual's "at most one short-running async call per transaction" rule
and is cheaper and more consistent (the model ranks the whole field in one
context). The contract decodes the response envelope and checks `has_error`
before trusting `completion_data`. The encrypted-secrets path uses ECIES with a
**12-byte** AES-GCM nonce (Ritual requirement) and one signature per blob.

### Ritual building blocks used
- **LLM inference precompile `0x0802`** — batch judging in a TEE.
- **`encryptedSecrets` + `userPublicKey`** — private inputs (encrypted answers /
  API keys) and optionally encrypted outputs, per the `ritual-dapp-secrets`
  skill.
- **`RitualWallet` (`0x532F...3948`)** — funds async settlement fees.
- **`TEEServiceRegistry`** — selects a valid executor (capability `LLM = 1`),
  using its `teeAddress` and `publicKey`.

### Tradeoff
The Required Track reveals plaintext after the deadline (simple, fully on-chain
verifiable, runs on any EVM). The Advanced Track keeps answers encrypted
end-to-end but trusts the TEE attestation and a live executor. Both share the
exact same commit-reveal lifecycle and the same `_runJudge` seam — only the
judging implementation differs.
