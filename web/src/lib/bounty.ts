import type { Address } from "viem";

/** Parsed shape of the `getBounty` tuple return value (commit-reveal). */
export type Bounty = {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  submissionDeadline: bigint;
  revealDeadline: bigint;
  judged: boolean;
  finalized: boolean;
  submissionCount: bigint;
  winnerIndex: bigint;
  aiReview: `0x${string}`;
};

/** getBounty returns a positional tuple — map it to a named object. */
export function parseBounty(
  raw: readonly [
    Address,
    string,
    string,
    bigint,
    bigint,
    bigint,
    boolean,
    boolean,
    bigint,
    bigint,
    `0x${string}`,
  ],
): Bounty {
  const [
    owner,
    title,
    rubric,
    reward,
    submissionDeadline,
    revealDeadline,
    judged,
    finalized,
    submissionCount,
    winnerIndex,
    aiReview,
  ] = raw;
  return {
    owner,
    title,
    rubric,
    reward,
    submissionDeadline,
    revealDeadline,
    judged,
    finalized,
    submissionCount,
    winnerIndex,
    aiReview,
  };
}

/**
 * Commit-reveal phases:
 * - submission: before the submission deadline (commitments only)
 * - reveal: after submission deadline, before reveal deadline
 * - ready: reveal window closed, awaiting judging
 * - judged: AI has judged, awaiting human finalize
 * - finalized: winner paid
 */
export type BountyStatus =
  | "submission"
  | "reveal"
  | "ready"
  | "judged"
  | "finalized";

export function getBountyStatus(
  b: Bounty,
  nowMs = Date.now(),
): BountyStatus {
  if (b.finalized) return "finalized";
  if (b.judged) return "judged";
  if (nowMs < Number(b.submissionDeadline)) return "submission";
  if (nowMs < Number(b.revealDeadline)) return "reveal";
  return "ready";
}

export const STATUS_META: Record<
  BountyStatus,
  { label: string; tone: "green" | "amber" | "indigo" | "zinc" }
> = {
  submission: { label: "Submission open", tone: "green" },
  reveal: { label: "Reveal open", tone: "amber" },
  ready: { label: "Ready for judging", tone: "amber" },
  judged: { label: "Judged", tone: "indigo" },
  finalized: { label: "Finalized", tone: "zinc" },
};

/** Can a participant still submit a commitment? (now in milliseconds) */
export function canCommit(b: Bounty, nowMs = Date.now()): boolean {
  return !b.judged && !b.finalized && nowMs < Number(b.submissionDeadline);
}

/** Can a participant reveal their answer now? (now in milliseconds) */
export function canReveal(b: Bounty, nowMs = Date.now()): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    nowMs >= Number(b.submissionDeadline) &&
    nowMs < Number(b.revealDeadline)
  );
}
