// Prints ONLY the public address + balance derived from the .env key.
// Never prints the private key itself.
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { privateKeyToAccount } from "viem/accounts";
import { createPublicClient, http, defineChain, formatEther } from "viem";

const __dirname = dirname(fileURLToPath(import.meta.url));
const envPath = join(__dirname, ".env");
if (!existsSync(envPath)) {
  console.error("No .env file found.");
  process.exit(1);
}
const env = {};
for (const line of readFileSync(envPath, "utf-8").split(/\r?\n/)) {
  const t = line.trim();
  if (!t || t.startsWith("#")) continue;
  const i = t.indexOf("=");
  if (i === -1) continue;
  env[t.slice(0, i).trim()] = t.slice(i + 1).trim();
}

const pk = env.PRIVATE_KEY;
if (!pk || pk.includes("your_testnet_private_key_here")) {
  console.error("PRIVATE_KEY not set in .env");
  process.exit(1);
}
if (!/^0x[0-9a-fA-F]{64}$/.test(pk)) {
  console.error("PRIVATE_KEY format looks wrong (need 0x + 64 hex chars).");
  process.exit(1);
}

const account = privateKeyToAccount(pk);
console.log("PUBLIC ADDRESS:", account.address);

const RPC = env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org";
const ritual = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const client = createPublicClient({ chain: ritual, transport: http(RPC) });
const bal = await client.getBalance({ address: account.address });
console.log("BALANCE:", formatEther(bal), "RITUAL");
if (bal === 0n) {
  console.log(
    "\n=> Fund THIS address at https://faucet.ritualfoundation.org, then run: npm run e2e"
  );
} else {
  console.log("\n=> Funded. You can run: npm run e2e");
}
