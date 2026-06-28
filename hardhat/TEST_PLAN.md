# Test Plan — CommitRevealBounty

**Author**: RafliRealm (Discord: arokmub)  
**GitHub**: https://github.com/RafliRealm/ritual-chain-workshop

Testing can be done manually on Remix using multiple MetaMask accounts,
or with Hardhat/Foundry. This document covers all critical edge cases.

---

## Setup (shared across tests)

```
owner    = accounts[0]
alice    = accounts[1]
bob      = accounts[2]
charlie  = accounts[3]

submissionDeadline = now + 300   (5 minutes)
revealDeadline     = now + 600   (10 minutes)
reward             = 1 ETH
bountyId           = 1
```

---

## Test Cases

### T01 — Happy path: valid commit, valid reveal, finalize winner ✅
```
1. owner calls createBounty("What is 2+2?", subDeadline, revDeadline) with 1 ETH
2. alice computes commitment = keccak256("Four", salt_a, alice, 1)
3. alice calls submitCommitment(1, commitment)
4. [time passes past submissionDeadline]
5. alice calls revealAnswer(1, "Four", salt_a)
6. getSubmission(1, alice) → eligible = true
7. [time passes past revealDeadline]
8. owner calls judgeAll(1, 0x)
9. owner calls finalizeWinner(1, 0)  // alice is index 0
10. alice's balance increases by 1 ETH ✅
```

### T02 — submitCommitment after submissionDeadline → revert ❌
```
1. createBounty(...)
2. [advance time past submissionDeadline]
3. alice calls submitCommitment(1, someHash)
→ Expected: revert SubmissionPhaseClosed
```

### T03 — Double commit by same address → revert ❌
```
1. createBounty(...)
2. alice calls submitCommitment(1, hash1)  // succeeds
3. alice calls submitCommitment(1, hash2)  // second attempt
→ Expected: revert AlreadyCommitted
```

### T04 — revealAnswer before submissionDeadline → revert ❌
```
1. createBounty(...)
2. alice calls submitCommitment(1, commitment)
3. alice immediately calls revealAnswer(1, "Four", salt_a)  // deadline not passed
→ Expected: revert RevealPhaseNotOpen
```

### T05 — revealAnswer after revealDeadline → revert ❌
```
1. createBounty(...)
2. alice calls submitCommitment(1, commitment)
3. [advance time past submissionDeadline AND revealDeadline]
4. alice calls revealAnswer(1, "Four", salt_a)
→ Expected: revert RevealPhaseClosed
```

### T06 — revealAnswer with wrong salt → ineligible, no revert ⚠️
```
1. createBounty(...)
2. alice commits keccak256("Four", salt_a, alice, 1)
3. [advance time to reveal phase]
4. alice calls revealAnswer(1, "Four", wrong_salt)
→ Expected: tx succeeds (no revert), but:
   getSubmission(1, alice).eligible = false
   event RevealInvalid emitted
```

### T07 — revealAnswer with wrong answer → ineligible ⚠️
```
1. alice commits keccak256("Four", salt_a, alice, 1)
2. alice reveals with answer = "4" (different string)
→ Expected: eligible = false, RevealInvalid emitted
```

### T08 — Participant without commitment tries to reveal → revert ❌
```
1. createBounty(...)
2. [advance time to reveal phase]
3. charlie (never committed) calls revealAnswer(1, "Four", anySalt)
→ Expected: revert NotCommitted
```

### T09 — judgeAll before revealDeadline → revert ❌
```
1. createBounty(...)
2. [advance time to reveal phase but NOT past revealDeadline]
3. owner calls judgeAll(1, 0x)
→ Expected: revert RevealPhaseStillOpen
```

### T10 — judgeAll called by non-owner → revert ❌
```
1. [advance time past revealDeadline]
2. alice calls judgeAll(1, 0x)
→ Expected: revert NotOwner
```

### T11 — finalizeWinner before judgeAll → revert ❌
```
1. [advance time past revealDeadline]
2. owner calls finalizeWinner(1, 0) without calling judgeAll first
→ Expected: revert JudgingNotDone
```

### T12 — finalizeWinner with ineligible winner → revert ❌
```
1. bob commits but never reveals (ineligible)
2. owner calls judgeAll(1, 0x)
3. bob is at index 0
4. owner calls finalizeWinner(1, 0)  // trying to pick bob
→ Expected: revert WinnerNotEligible
```

### T13 — finalizeWinner twice → revert ❌
```
1. alice eligible, judgeAll done
2. owner calls finalizeWinner(1, 0)  // succeeds, alice paid
3. owner calls finalizeWinner(1, 0)  // second call
→ Expected: revert AlreadyFinalized
```

### T14 — Multiple participants, only revealed ones eligible ✅
```
1. alice commits and reveals correctly → eligible
2. bob commits but does NOT reveal → not eligible
3. charlie commits and reveals with wrong salt → not eligible
4. getEligibleAnswers(1) → returns only alice's address and answer
5. owner finalizes alice as winner → succeeds ✅
```

### T15 — computeCommitment view matches on-chain verification ✅
```
1. Call computeCommitment("Four", salt, alice, 1) → hash1
2. alice calls submitCommitment(1, hash1)
3. alice calls revealAnswer(1, "Four", salt)
→ Expected: eligible = true (hashes match) ✅
```

---

## Running on Remix

1. Deploy contract
2. Use **Remix VM (Shanghai)** for fast local testing
3. Use the clock icon (⏰) to advance block.timestamp manually
4. Switch accounts using the **Account** dropdown to simulate multiple participants

---

## Foundry equivalent (optional)

```solidity
function testCommitRevealHappyPath() public {
    // Setup
    vm.deal(owner, 2 ether);
    vm.prank(owner);
    uint256 id = bounty.createBounty{value: 1 ether}(
        "What is 2+2?",
        block.timestamp + 300,
        block.timestamp + 600
    );

    // Commit
    bytes32 salt = bytes32(uint256(0xdeadbeef));
    bytes32 commitment = keccak256(abi.encodePacked("Four", salt, alice, id));
    vm.prank(alice);
    bounty.submitCommitment(id, commitment);

    // Reveal
    vm.warp(block.timestamp + 301);
    vm.prank(alice);
    bounty.revealAnswer(id, "Four", salt);

    // Judge + Finalize
    vm.warp(block.timestamp + 601);
    vm.prank(owner);
    bounty.judgeAll(id, "");
    
    uint256 balBefore = alice.balance;
    vm.prank(owner);
    bounty.finalizeWinner(id, 0);
    assertEq(alice.balance, balBefore + 1 ether);
}
```
