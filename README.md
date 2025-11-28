# HunnyFinance Earn Manipulation

**Affected Contract:** `HyperStaking` (Proxy at `0x31dd9Be51cC7A96359cAaE6Cb4f5583C89D81985` on BSC)

---

## 1. Summary

A critical vulnerability has been identified in the `HyperStaking` contract. It allows an attacker to manipulate the contract's internal accounting logic to generate artificial "earned" KISS tokens. These fake earnings make the attacker eligible for illegitimate bonuses in LOVE tokens, allowing them to progressively drain the funds deposited by other users.

---

## 2. Description

The flaw is located in the `unstake()` function of the `HyperStaking` contract. Specifically, when the function is called with a `_bonus` of `0`, it enters a code block intended to recalculate the user's `principal` (their base capital).

```solidity
    function unstake(
        uint256 _amount,
        uint256 _bonus,
        bool _trigger
    ) external {
        if (_trigger) {
            rebase();
        }

        // vesting unstake amount
        uint256 maxBonus = getBonus(msg.sender);
        uint256 bonusAmount = maxBonus > _bonus ? _bonus : maxBonus;
        uint256 hugBalance = IERC20(HUG).balanceOf(msg.sender);
        bonusAmount = bonusAmount > hugBalance ? hugBalance : bonusAmount;

        uint256 totalAmount = _amount.add(bonusAmount);

        if (bonusAmount > 0) {
            IStakingVault(vault).withdraw(address(this), msg.sender, bonusAmount);

            // reset loyalty & principal
            bonusInfo[msg.sender].epoch = epoch.number;
            bonusInfo[msg.sender].principal = IERC20(KISS).balanceOf(msg.sender).sub(_amount);
        } else {
            // calculate fair principal amount
            uint256 balance = IERC20(KISS).balanceOf(msg.sender);
            uint256 remain = balance.sub(_amount);
            bonusInfo[msg.sender].principal = remain > bonusInfo[msg.sender].principal
                ? bonusInfo[msg.sender].principal
                : remain; // <-- VULNERABILITY HERE
        }

        IERC20(LOVE).approve(lockup, 0);
        IERC20(LOVE).approve(lockup, totalAmount);
        IStakingLockup(lockup).unstake(msg.sender, totalAmount);

        IERC20(KISS).safeTransferFrom(msg.sender, address(this), _amount);
    }
```

The contract recalculates the new `principal` based on the user's KISS token balance at the time of the call. An attacker can artificially reduce their KISS balance (by temporarily transferring them to another address) just before calling `unstake()`. The contract interprets this low balance as a withdrawal and drastically reduces the recorded `principal`, while the attacker still actually owns all of their tokens.

---

## 3. Vector

The exploit is performed in several steps, which can be executed via an attack contract in a single atomic manipulation transaction.

1.  **Step 1: Initial Deposit**
    *   The attacker stakes an amount `N` of LOVE and receives `N` KISS tokens.
    *   Their `principal` is correctly recorded as `N`.

2.  **Step 2: Hiding Tokens**
    *   The attacker transfers a large portion (90%) of their KISS to a vault contract they control, their visible balance in the attack contract is now `0.1 * N`.

3.  **Step 3: Principal Manipulation**
    *   The attacker calls `unstake(small_amount, 0, false)`.
    *   The contract executes the vulnerable logic and recalculates the `principal` to a very low value (`0.05 * N`), the 95% reduction is achieved.

4.  **Step 4: Recovering Tokens**
    *   The attacker calls their KISS tokens back from the vault contract, their balance is now `~0.95 * N`.

5.  **Step 5: Creation of "Fake Earned" Tokens**
    *   The `HyperStaking` contract now sees a balance of `~0.95 * N` and a `principal` of `0.05 * N`.
    *   It calculates the earnings (`earned`) as `balance - principal`, which equals `0.9 * N`, these **earnings are artificial**.

6.  **Step 6: Claiming the Bonus**
    *   The attacker waits for their `loyaltyRatio` to increase (a few days).
    *   They call `unstake()`, this time claiming the maximum bonus, which is calculated based on the `0.9 * N` of fake earnings.
    *   The bonus LOVE tokens (stolen from other users) are sent to the `StakingLockup` contract.

7.  **Step 7: Final Withdrawal**
    *   After the 24-hour `claimPeriod`, the attacker calls `claim()` on `StakingLockup` to receive their initial capital plus the stolen bonus.

---

## 4. Impact

The vulnerability poses a direct and critical threat to the **$50,163** of TVL.

*   **Linear Scalability:** The profit is directly proportional to the capital invested.
*   **Impact on TVL:** An attacker with **$20,000** in capital can drain **$540 per day**, which is over **1% of the contract's total value each day**, such a drain rate is unsustainable and would lead to the protocol collapse.
*   **Increasing Profitability:** The profit grows exponentially with waiting time (due to the Fibonacci-based `loyaltyRatio`), incentivizing the attacker to be patient to maximize the damage.

---

## 5. Recommendations

To fix this flaw, the `principal` update logic must be made non-manipulable.

**Fix**
Remove the `principal` recalculation logic within the `unstake` function, a user `principal` should **never** be recalculated based on an external and volatile token balance.

The `principal` should only decrease when a user explicitly withdraws a portion of their capital, and this decrease must be equal to the amount of capital withdrawn, with no connection to the current balance.

```solidity
// During a principal unstake (not earned rewards)
uint256 amountToUnstakeFromPrincipal = ...;
bonusInfo[msg.sender].principal = bonusInfo[msg.sender].principal.sub(amountToUnstakeFromPrincipal);
```

This approach ensures that the contract accounting remains consistent and is not subject to external manipulation.
