# Privacy-Preserving AI Bounty Judge
## Commit-Reveal Implementation — Ritual AI Homework

**Author**: RafliRealm (Discord: arokmub)  
**GitHub**: https://github.com/RafliRealm/ritual-chain-workshop

---

## Overview

This contract extends the workshop AI Bounty Judge by adding a **commit-reveal scheme**
that prevents participants from reading each other's answers during the submission phase.

**Problem**: In the original contract, answers were public immediately. Late participants
could copy earlier answers and submit a slightly improved version — unfair in a
winner-takes-all bounty.

**Solution**: Participants commit a *hash* of their answer first. The actual answer is
revealed only after the submission deadline, when it's too late to copy anyone.

---

## Bounty Lifecycle

```
createBounty()
      │
      ▼
[Submission Phase]  ──  before submissionDeadline
  submitCommitment()     hash only, answer hidden
      │
      ▼  submissionDeadline passes
      │
[Reveal Phase]      ──  after submissionDeadline, before revealDeadline
  revealAnswer()         contract verifies hash, marks eligible
      │
      ▼  revealDeadline passes
      │
[Judging Phase]
  judgeAll()             owner triggers Ritual AI batch judgment
      │
      ▼
  finalizeWinner()       owner picks winner by index, reward transferred
```

---

## Commitment Formula

```solidity
bytes32 commitment = keccak256(
    abi.encodePacked(answer, salt, msg.sender, bountyId)
);
```

- **salt** — random bytes32, prevents brute-force preimage attacks
- **msg.sender** — prevents copying another participant's commitment
- **bountyId** — prevents reusing a commitment across different bounties

---

## How to Deploy on Remix

### Step 1 — Compile
1. Open [remix.ethereum.org](https://remix.ethereum.org)
2. Create `CommitRevealBounty.sol`, paste the contract
3. Compiler: `0.8.20+`, EVM version: `paris` or `london`
4. Hit **Compile**

### Step 2 — Connect MetaMask to Ritual Testnet
- Network name: Ritual Chain Testnet
- RPC: `https://testnet.rpc.ritual.net` (or as per Ritual docs)
- Chain ID: check ritual.net
- Ensure you have RITUAL tokens for gas

### Step 3 — Deploy
1. Environment: **Injected Provider — MetaMask**
2. Select `CommitRevealBounty`
3. In the `VALUE` field set your reward amount (in ETH/RITUAL)
4. Call `createBounty` with:
   - `description`: your bounty question
   - `submissionDeadline`: Unix timestamp (e.g. `now + 1 hour`)
   - `revealDeadline`: Unix timestamp (e.g. `now + 2 hours`)

---

## How to Test on Remix (Step by Step)

### Generate a commitment (before submitting)
Call the view function `computeCommitment` with:
- `answer`: `"My answer here"`
- `salt`: any random bytes32, e.g. `0xdeadbeef...` (32 bytes)
- `sender`: your MetaMask address
- `bountyId`: `1`

Copy the returned `bytes32`.

### Submit commitment
Call `submitCommitment(1, <bytes32 from above>)`

### After submission deadline — reveal
Call `revealAnswer(1, "My answer here", <same salt>)`

### Judge
Call `judgeAll(1, 0x)` — pass empty bytes for now, or encode a JSON payload

### Finalize
Call `finalizeWinner(1, <winnerIndex>)` where index = position in participants array

---

## Architecture Note — Commit-Reveal vs Ritual-Native

| Aspect | Commit-Reveal | Ritual-Native TEE |
|---|---|---|
| Answer visibility | Hidden during submission, **public after reveal** | Hidden until after judging |
| Privacy guarantee | Hash-based, cryptographic | TEE hardware-enforced |
| On-chain storage | Commitment hash → then plaintext | Ciphertext only |
| AI sees answers | After reveal deadline | Inside TEE, never public |
| EVM compatibility | Any EVM chain | Ritual only |
| Complexity | Low | High |

The key limitation of commit-reveal: answers become public **before** AI judging happens.
A Ritual TEE approach solves this — the LLM receives decrypted answers privately inside
the TEE, and only the winner + scores are published afterward.

---

## Reflection

**What should be public?**
Bounty description, reward amount, deadlines, commitment hashes, and the final winner
should all be public — this ensures the contest is auditable and trustless.

**What should stay hidden?**
Actual answers must stay hidden during the submission phase to prevent copying.
In the commit-reveal scheme they become public at reveal time; in a Ritual TEE system
they could stay private until after judging is complete.

**What should AI decide vs humans?**
AI is well-suited to rank and score answers objectively against the bounty rubric —
especially at scale where human review is slow. However, the *final payout decision*
should remain with a human (the owner) for accountability: the AI recommends, the human
confirms. This prevents fully automated payouts from being exploited by adversarial
inputs or LLM hallucinations. On-chain, the human-in-the-loop is enforced by
`finalizeWinner()` being owner-only.
