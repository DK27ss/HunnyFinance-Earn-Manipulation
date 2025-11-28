# HunnyFinance Earn Manipulation

**Affected Contract:** `HyperStaking` (Proxy at `0x31dd9Be51cC7A96359cAaE6Cb4f5583C89D81985` on BSC)
**TVL at Risk:** ~10,114,087 LOVE (~$50,163)

---

## 1. Summary

A critical vulnerability has been identified in the `HyperStaking` contract. It allows an attacker to manipulate the contract's internal accounting logic to generate artificial "earned" KISS tokens. These fake earnings make the attacker eligible for illegitimate bonuses in LOVE tokens, allowing them to progressively drain the funds deposited by other users.

The attack does not require a flash loan, has a low barrier to entry, and its profitability increases with waiting time. It has been proven via an on-chain transaction.

---

## 2. Description

The flaw is located in the `unstake()` function of the `HyperStaking` contract. Specifically, when the function is called with a `_bonus` of `0`, it enters a code block intended to recalculate the user's `principal` (their base capital).

The flawed logic is as follows:

```solidity
// ... in the unstake() function
else {
    // calculate fair principal amount
    uint256 balance = IERC20(KISS).balanceOf(msg.sender);
    uint256 remain = balance.sub(_amount);
    bonusInfo[msg.sender].principal = remain > bonusInfo[msg.sender].principal
        ? bonusInfo[msg.sender].principal
        : remain; // <-- VULNERABILITY HERE
}
```

The contract recalculates the new `principal` based on the user's KISS token balance at the time of the call. An attacker can artificially reduce their KISS balance (by temporarily transferring them to another address) just before calling `unstake()`. The contract interprets this low balance as a withdrawal and drastically reduces the recorded `principal`, while the attacker still actually owns all of their tokens.

---

## 3. Attack Vector (Proof of Concept)

The exploit is performed in several steps, which can be executed via an attack contract in a single atomic manipulation transaction.

1.  **Step 1: Initial Deposit**
    *   The attacker stakes an amount `N` of LOVE and receives `N` KISS tokens.
    *   Their `principal` is correctly recorded as `N`.

2.  **Step 2: Hiding Tokens**
    *   The attacker transfers a large portion (e.g., 90%) of their KISS to a vault contract they control. Their visible balance in the attack contract is now `0.1 * N`.

3.  **Step 3: Principal Manipulation**
    *   The attacker calls `unstake(small_amount, 0, false)`.
    *   The contract executes the vulnerable logic and recalculates the `principal` to a very low value (e.g., `0.05 * N`). The 95% reduction is achieved.

4.  **Step 4: Recovering Tokens**
    *   The attacker calls their KISS tokens back from the vault contract. Their balance is now `~0.95 * N`.

5.  **Step 5: Creation of "Fake Earned" Tokens**
    *   The `HyperStaking` contract now sees a balance of `~0.95 * N` and a `principal` of `0.05 * N`.
    *   It calculates the earnings (`earned`) as `balance - principal`, which equals `0.9 * N`. These **earnings are artificial**.

6.  **Step 6: Claiming the Bonus**
    *   The attacker waits for their `loyaltyRatio` to increase (a few days).
    *   They call `unstake()`, this time claiming the maximum bonus, which is calculated based on the `0.9 * N` of fake earnings.
    *   The bonus LOVE tokens (stolen from other users) are sent to the `StakingLockup` contract.

7.  **Step 7: Final Withdrawal**
    *   After the 24-hour `claimPeriod`, the attacker calls `claim()` on `StakingLockup` to receive their initial capital plus the stolen bonus.

---

## 4. Impact

The vulnerability poses a direct and critical threat to the **$50,163** of TVL.

*   **Low Barrier to Entry:** The attack is profitable even with small amounts of capital.
    *   **$500 Capital:** Profit of **~$13.50** in 1 day.
    *   **$5,000 Capital:** Profit of **~$135** in 1 day.
*   **Linear Scalability:** The profit is directly proportional to the capital invested.
*   **Impact on TVL:** An attacker with **$20,000** in capital can drain **$540 per day**, which is over **1% of the contract's total value each day**. Such a drain rate is unsustainable and would lead to the protocol's collapse.
*   **Increasing Profitability:** The profit grows exponentially with waiting time (due to the Fibonacci-based `loyaltyRatio`), incentivizing the attacker to be patient to maximize the damage.

---

## 5. Recommendations

To fix this flaw, the `principal` update logic must be made non-manipulable.

**Immediate Fix:**
Remove the `principal` recalculation logic within the `unstake` function. A user's `principal` should **never** be recalculated based on an external and volatile token balance.

The `principal` should only decrease when a user explicitly withdraws a portion of their capital, and this decrease must be equal to the amount of capital withdrawn, with no connection to the current balance.

**Example of Secure Logic (to be adapted):**

```solidity
// During a principal unstake (not earned rewards)
uint256 amountToUnstakeFromPrincipal = ...;
bonusInfo[msg.sender].principal = bonusInfo[msg.sender].principal.sub(amountToUnstakeFromPrincipal);
```

This approach ensures that the contract's accounting remains consistent and is not subject to external manipulation.
