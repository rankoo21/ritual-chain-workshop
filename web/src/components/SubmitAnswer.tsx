"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { encodeAbiParameters, keccak256, parseAbiParameters, type Hex } from "viem";
import { useNow } from "@/hooks/useNow";
import bountyAbi from "@/abi/CommitRevealBounty";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { canCommit, canReveal, type Bounty } from "@/lib/bounty";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Input,
  Textarea,
  Button,
  TxStatus,
  Notice,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

/** localStorage key where we stash the salt so the user can reveal later. */
function saltKey(bountyId: bigint, addr: string) {
  return `crb:salt:${ritualChain.id}:${contractAddress}:${bountyId}:${addr.toLowerCase()}`;
}
function answerKey(bountyId: bigint, addr: string) {
  return `crb:answer:${ritualChain.id}:${contractAddress}:${bountyId}:${addr.toLowerCase()}`;
}

/** commitment = keccak256(abi.encode(answer, salt, sender, bountyId)). */
function computeCommitment(
  answer: string,
  salt: Hex,
  sender: `0x${string}`,
  bountyId: bigint,
): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("string, bytes32, address, uint256"),
      [answer, salt, sender, bountyId],
    ),
  );
}

function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return ("0x" +
    Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")) as Hex;
}

export function SubmitAnswer({
  bountyId,
  bounty,
  onSubmitted,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onSubmitted: () => void;
}) {
  const { address, isConnected } = useAccount();
  const now = useNow();

  if (canCommit(bounty, now)) {
    return (
      <CommitCard
        bountyId={bountyId}
        address={address}
        isConnected={isConnected}
        onSubmitted={onSubmitted}
      />
    );
  }
  if (canReveal(bounty, now)) {
    return (
      <RevealCard
        bountyId={bountyId}
        address={address}
        isConnected={isConnected}
        onSubmitted={onSubmitted}
      />
    );
  }
  return null;
}

function CommitCard({
  bountyId,
  address,
  isConnected,
  onSubmitted,
}: {
  bountyId: bigint;
  address?: `0x${string}`;
  isConnected: boolean;
  onSubmitted: () => void;
}) {
  const [answer, setAnswer] = useState("");
  const tx = useWriteTx(() => {
    setAnswer("");
    onSubmitted();
  });

  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress || !address) return;

    const salt = randomSalt();
    const commitment = computeCommitment(answer.trim(), salt, address, bountyId);

    // Persist salt + answer locally so the user can reveal after the deadline.
    try {
      localStorage.setItem(saltKey(bountyId, address), salt);
      localStorage.setItem(answerKey(bountyId, address), answer.trim());
    } catch {
      /* storage may be unavailable; the reveal form lets them paste manually */
    }

    try {
      await tx.run({
        address: contractAddress,
        abi: bountyAbi,
        functionName: "submitCommitment",
        args: [bountyId, commitment],
        chainId: ritualChain.id,
        gas: 300000n,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  return (
    <Card>
      <CardHeader
        title="Submit a sealed answer"
        subtitle="Only a hash is stored on-chain now. You reveal the answer after the submission deadline."
      />
      <CardBody>
        <form onSubmit={handleCommit} className="space-y-3">
          <Field label="Your answer" hint="Kept in your browser until you reveal. Never sent on-chain until reveal.">
            <Textarea
              value={answer}
              onChange={(e) => setAnswer(e.target.value)}
              rows={5}
              placeholder="Write your submission…"
            />
          </Field>
          <Button
            type="submit"
            disabled={!isConnected || !answer.trim() || tx.isBusy}
            className="w-full"
          >
            {tx.isBusy ? "Committing…" : "Submit commitment"}
          </Button>
          {!isConnected && (
            <p className="text-xs text-zinc-500">Connect your wallet to commit.</p>
          )}
          <TxStatus
            state={tx.state}
            error={tx.error}
            hash={tx.hash}
            explorerBase={explorerBase}
          />
        </form>
      </CardBody>
    </Card>
  );
}

function RevealCard({
  bountyId,
  address,
  isConnected,
  onSubmitted,
}: {
  bountyId: bigint;
  address?: `0x${string}`;
  isConnected: boolean;
  onSubmitted: () => void;
}) {
  const stored = (() => {
    if (!address) return { answer: "", salt: "" };
    try {
      return {
        answer: localStorage.getItem(answerKey(bountyId, address)) ?? "",
        salt: localStorage.getItem(saltKey(bountyId, address)) ?? "",
      };
    } catch {
      return { answer: "", salt: "" };
    }
  })();

  const [answer, setAnswer] = useState(stored.answer);
  const [salt, setSalt] = useState(stored.salt);
  const tx = useWriteTx(() => onSubmitted());

  async function handleReveal(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !salt || !contractAddress) return;
    try {
      await tx.run({
        address: contractAddress,
        abi: bountyAbi,
        functionName: "revealAnswer",
        args: [bountyId, answer.trim(), salt as Hex],
        chainId: ritualChain.id,
        gas: 300000n,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  return (
    <Card>
      <CardHeader
        title="Reveal your answer"
        subtitle="Submission window closed. Reveal the answer + salt you committed."
      />
      <CardBody>
        <Notice tone="amber">
          The answer and salt must match exactly what you committed, or the reveal
          reverts.
        </Notice>
        <form onSubmit={handleReveal} className="mt-3 space-y-3">
          <Field label="Your answer">
            <Textarea
              value={answer}
              onChange={(e) => setAnswer(e.target.value)}
              rows={5}
              placeholder="The exact answer you committed…"
            />
          </Field>
          <Field label="Salt" hint="Auto-filled if you committed in this browser.">
            <Input
              value={salt}
              onChange={(e) => setSalt(e.target.value)}
              placeholder="0x…"
            />
          </Field>
          <Button
            type="submit"
            disabled={!isConnected || !answer.trim() || !salt || tx.isBusy}
            className="w-full"
          >
            {tx.isBusy ? "Revealing…" : "Reveal answer"}
          </Button>
          <TxStatus
            state={tx.state}
            error={tx.error}
            hash={tx.hash}
            explorerBase={explorerBase}
          />
        </form>
      </CardBody>
    </Card>
  );
}
