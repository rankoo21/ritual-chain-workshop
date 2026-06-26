// Real on-chain end-to-end test of the commit-reveal bounty on Ritual Chain.
//
// It performs the COMPLETE lifecycle with a REAL AI judging call:
//   1. deploy RitualCommitRevealBounty
//   2. createBounty (escrows the reward)
//   3. submitCommitment for two participants (answers hidden)
//   4. revealAnswer for both after the submission deadline
//   5. judgeAll -> real LLM inference precompile (0x0802), batch judging
//   6. finalizeWinner -> pays the winner
//
// Requirements:
//   - env PRIVATE_KEY: a Ritual Chain account funded from the faucet
//     (https://faucet.ritualfoundation.org). The same account plays owner +
//     both participants for simplicity, but commitments still bind msg.sender.
//   - env RITUAL_RPC_URL (optional, defaults to the public RPC).
//
// Run:
//   cd scripts
//   npm install
//   set PRIVATE_KEY=0x...   (Windows cmd)   /   $env:PRIVATE_KEY="0x..." (pwsh)
//   npm run e2e
//
// NOTE: short deadlines are used so the script can run start-to-finish. The LLM
// call is async (commitment -> executor -> settlement); we read the settled
// review from the contract after the tx is mined.

import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  parseEther,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Minimal .env loader (no extra dependency). Reads scripts/.env if present and
// only sets variables that aren't already in the environment.
// ---------------------------------------------------------------------------
function loadDotEnv() {
  const envPath = join(__dirname, ".env");
  if (!existsSync(envPath)) return;
  const raw = readFileSync(envPath, "utf-8");
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    // strip optional surrounding quotes
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (key && process.env[key] === undefined) process.env[key] = value;
  }
}
loadDotEnv();

// ---------------------------------------------------------------------------
// Chain + clients
// ---------------------------------------------------------------------------
const RPC = process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org";
const PK = process.env.PRIVATE_KEY;
if (!PK || PK.includes("your_testnet_private_key_here")) {
  console.error(
    "PRIVATE_KEY is not set. Edit scripts/.env and put your TESTNET key in\n" +
      "  PRIVATE_KEY=0x...\n" +
      "Fund the address at https://faucet.ritualfoundation.org"
  );
  process.exit(1);
}

const ritual = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const account = privateKeyToAccount(PK.startsWith("0x") ? PK : `0x${PK}`);
const publicClient = createPublicClient({ chain: ritual, transport: http(RPC) });
const walletClient = createWalletClient({
  account,
  chain: ritual,
  transport: http(RPC),
});

// ---------------------------------------------------------------------------
// System addresses
// ---------------------------------------------------------------------------
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
const TEE_REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";
const LLM_PRECOMPILE = "0x0000000000000000000000000000000000000802";

const ritualWalletAbi = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "lockDuration", type: "uint256" }],
    outputs: [],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
];

const registryAbi = [
  {
    name: "getServicesByCapability",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "capability", type: "uint8" },
      { name: "checkValidity", type: "bool" },
    ],
    outputs: [
      {
        type: "tuple[]",
        components: [
          {
            name: "node",
            type: "tuple",
            components: [
              { name: "paymentAddress", type: "address" },
              { name: "teeAddress", type: "address" },
              { name: "teeType", type: "uint8" },
              { name: "publicKey", type: "bytes" },
              { name: "endpoint", type: "string" },
              { name: "certPubKeyHash", type: "bytes32" },
              { name: "capability", type: "uint8" },
            ],
          },
          { name: "isValid", type: "bool" },
          { name: "workloadId", type: "bytes32" },
        ],
      },
    ],
  },
];

// ---------------------------------------------------------------------------
// Load compiled artifact
// ---------------------------------------------------------------------------
const artifact = JSON.parse(
  readFileSync(
    join(
      __dirname,
      "..",
      "out",
      "RitualCommitRevealBounty.sol",
      "RitualCommitRevealBounty.json"
    ),
    "utf-8"
  )
);
const abi = artifact.abi;
const bytecode = artifact.bytecode.object;

// LLM 30-field request ABI (see ritual-dapp-llm skill).
const LLM_ABI = parseAbiParameters(
  [
    "address, bytes[], uint256, bytes[], bytes,",
    "string, string, int256, string, bool, int256, string, string,",
    "uint256, bool, int256, string, bytes, int256, string, string, bool,",
    "int256, bytes, bytes, int256, int256, string, bool,",
    "(string,string,string)",
  ].join("")
);

function buildLLMInput(executor, rubric, answers) {
  // One batch prompt for ALL answers (not one call per answer).
  const numbered = answers
    .map((a, i) => `Submission #${i}: ${a}`)
    .join("\n\n");
  const messages = [
    {
      role: "system",
      content:
        "You are an impartial bounty judge. Apply the rubric and rank all " +
        "submissions. Reply with the winning submission number and a one-line " +
        "reason.",
    },
    {
      role: "user",
      content: `Rubric: ${rubric}\n\nSubmissions:\n${numbered}`,
    },
  ];

  return encodeAbiParameters(LLM_ABI, [
    executor,
    [],
    300n,
    [],
    "0x",
    JSON.stringify(messages),
    "zai-org/GLM-4.7-FP8",
    0n,
    "",
    false,
    4096n,
    "",
    "",
    1n,
    true,
    0n,
    "medium",
    "0x",
    -1n,
    "auto",
    "",
    false,
    700n,
    "0x",
    "0x",
    -1n,
    1000n,
    "",
    false,
    ["", "", ""],
  ]);
}

// Explicit nonce management with retry — the public RPC caches nonces
// inconsistently and intermittently reports "nonce too low", so we track the
// nonce locally and, on a nonce error, refresh from the chain and retry.
let _nonce;
async function refreshNonce() {
  _nonce = await publicClient.getTransactionCount({
    address: account.address,
    blockTag: "pending",
  });
}

function isNonceError(e) {
  const s = (e?.shortMessage || e?.message || "") + JSON.stringify(e?.details || "");
  return /nonce/i.test(s) || /already known/i.test(s);
}

async function sendWithRetry(fn, label) {
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const hash = await fn(_nonce);
      _nonce++;
      return await publicClient.waitForTransactionReceipt({ hash });
    } catch (e) {
      if (isNonceError(e) && attempt < 6) {
        await new Promise((r) => setTimeout(r, 3000));
        await refreshNonce();
        console.log(`  [${label}] nonce conflict, retrying with nonce ${_nonce}...`);
        continue;
      }
      throw e;
    }
  }
}

// Send a contract write with our managed nonce and wait for the receipt.
async function write(params) {
  return sendWithRetry(
    (nonce) => walletClient.writeContract({ ...params, nonce }),
    params.functionName || "write"
  );
}

async function main() {
  console.log("Account:", account.address);
  const bal = await publicClient.getBalance({ address: account.address });
  console.log("Native balance:", bal, "wei");
  if (bal === 0n) {
    throw new Error(
      "Account has 0 RITUAL. Fund it via https://faucet.ritualfoundation.org"
    );
  }

  await refreshNonce();

  // --- pick a live LLM executor -----------------------------------------
  const services = await publicClient.readContract({
    address: TEE_REGISTRY,
    abi: registryAbi,
    functionName: "getServicesByCapability",
    args: [1, true], // Capability.LLM = 1
  });
  if (!services.length) throw new Error("No live LLM executors");
  const executor = services[0].node.teeAddress;
  console.log("LLM executor:", executor);

  // --- ensure RitualWallet balance covers async LLM settlement ----------
  const walletBal = await publicClient.readContract({
    address: RITUAL_WALLET,
    abi: ritualWalletAbi,
    functionName: "balanceOf",
    args: [account.address],
  });
  if (walletBal < parseEther("0.4")) {
    console.log("Depositing 0.5 RITUAL into RitualWallet...");
    await write({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: "deposit",
      args: [200000n],
      value: parseEther("0.5"),
    });
    const after = await publicClient.readContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: "balanceOf",
      args: [account.address],
    });
    console.log("RitualWallet balance now:", after.toString(), "wei");
  } else {
    console.log(
      "RitualWallet already funded:",
      walletBal.toString(),
      "wei — skipping deposit"
    );
  }

  // --- deploy the bounty contract ---------------------------------------
  console.log("Deploying RitualCommitRevealBounty...");
  const deployRcpt = await sendWithRetry(
    (nonce) => walletClient.deployContract({ abi, bytecode, args: [], nonce }),
    "deploy"
  );
  const contract = deployRcpt.contractAddress;
  console.log("Deployed at:", contract);

  // --- create bounty with short deadlines -------------------------------
  // Base deadlines on the CHAIN's block timestamp, not the local clock.
  const latest = await publicClient.getBlock({ blockTag: "latest" });
  const chainNow = latest.timestamp;
  const subDeadline = chainNow + 120000n; // ~120s submission window (ms)
  const revDeadline = chainNow + 240000n; // then ~120s reveal window (ms)
  console.log(
    "Creating bounty... chainNow:",
    chainNow.toString(),
    "sub:",
    subDeadline.toString(),
    "rev:",
    revDeadline.toString()
  );
  await write({
    address: contract,
    abi,
    functionName: "createBounty",
    args: [
      "Best one-line poem about Ritual",
      "Judge on creativity and brevity.",
      subDeadline,
      revDeadline,
    ],
    value: parseEther("0.01"),
  });
  const bountyId = 1n;
  console.log("Bounty created, id =", bountyId.toString());

  // --- commit an answer (hidden) ----------------------------------------
  const answer = "Code that thinks, on chains that dream.";
  const salt = keccak256(toHex("salt-0"));
  const commitment = await publicClient.readContract({
    address: contract,
    abi,
    functionName: "computeCommitment",
    args: [answer, salt, account.address, bountyId],
  });
  console.log("Committing answer (only the hash goes on-chain)...");
  await write({
    address: contract,
    abi,
    functionName: "submitCommitment",
    args: [bountyId, commitment],
  });

  // Prove the answer is hidden during submission.
  const subDuringCommit = await publicClient.readContract({
    address: contract,
    abi,
    functionName: "getSubmission",
    args: [bountyId, 0n],
  });
  console.log(
    "During submission -> revealed:",
    subDuringCommit[2],
    "| stored answer length:",
    (subDuringCommit[3] || "").length
  );

  // --- wait for submission deadline, then reveal ------------------------
  console.log("Waiting for submission deadline...");
  await sleepUntil(subDeadline);

  console.log("Revealing answer...");
  await write({
    address: contract,
    abi,
    functionName: "revealAnswer",
    args: [bountyId, answer, salt],
  });

  const revealed = await publicClient.readContract({
    address: contract,
    abi,
    functionName: "revealedCount",
    args: [bountyId],
  });
  console.log("Revealed count:", revealed.toString());

  // --- wait for reveal deadline, then judge with REAL LLM ---------------
  console.log("Waiting for reveal deadline...");
  await sleepUntil(revDeadline);

  const llmInput = buildLLMInput(executor, "creativity and brevity", [answer]);
  console.log("Calling judgeAll with real LLM input (async settlement)...");
  const judgeRcpt = await write({
    address: contract,
    abi,
    functionName: "judgeAll",
    args: [bountyId, llmInput],
    gas: 6000000n,
  });
  console.log("judgeAll status:", judgeRcpt.status);

  const bounty = await publicClient.readContract({
    address: contract,
    abi,
    functionName: "getBounty",
    args: [bountyId],
  });
  console.log("judged =", bounty[6]);
  console.log("aiReview bytes length =", (bounty[10].length - 2) / 2);

  // --- finalize winner ---------------------------------------------------
  console.log("Finalizing winner (index 0)...");
  const finRcpt = await write({
    address: contract,
    abi,
    functionName: "finalizeWinner",
    args: [bountyId, 0n],
  });
  console.log("finalizeWinner status:", finRcpt.status);
  console.log("\nE2E lifecycle complete on Ritual Chain.");
  console.log(
    "Explorer: https://explorer.ritualfoundation.org/address/" + contract
  );
}

async function sleepUntil(deadlineMs) {
  // The contract checks against block.timestamp, which on Ritual is in
  // MILLISECONDS. Wait until the chain's latest block passes the deadline.
  for (;;) {
    const blk = await publicClient.getBlock({ blockTag: "latest" });
    if (blk.timestamp >= deadlineMs + 2000n) return;
    const remainingMs = Number(deadlineMs + 2000n - blk.timestamp);
    await new Promise((r) => setTimeout(r, Math.min(remainingMs + 1000, 5000)));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
