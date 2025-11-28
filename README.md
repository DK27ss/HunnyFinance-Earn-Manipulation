# HunnyFinance Multiple Vulnerabilities Report

**Affected Contract:** `HyperStaking` 

(Proxy at `0x31dd9Be51cC7A96359cAaE6Cb4f5583C89D81985` on BSC)

---

## Summary

The `HyperStaking` contract contains at least two critical vulnerabilities.

1.  **Principal Manipulation:** An attacker can manipulate the internal accounting of their principal investment to generate artificial "earned" tokens, allowing them to claim illegitimate bonuses.
2.  **Epoch Manipulation:** An attacker can bypass the time-based loyalty mechanism by repeatedly calling the `rebase()` function, granting them 100% loyalty instantly to maximize bonus theft.

Both vulnerabilities can be exploited independently to drain funds from the protocol.

---

## Exploit 1 - Principal & Earned Manipulation

### Description

The first flaw is located in the `unstake()` function, when called with a `_bonus` of `0`, it enters a code block that recalculates the user `principal`, the logic incorrectly uses the user current KISS balance to determine the new principal.

```solidity
function unstake(
    uint256 _amount,
    uint256 _bonus,
    bool _trigger
) external {
    if (_trigger) {
        rebase();
    }

    uint256 maxBonus = getBonus(msg.sender);
    uint256 bonusAmount = maxBonus > _bonus ? _bonus : maxBonus;
    uint256 hugBalance = IERC20(HUG).balanceOf(msg.sender);
    bonusAmount = bonusAmount > hugBalance ? hugBalance : bonusAmount;
    uint256 totalAmount = _amount.add(bonusAmount);

    if (bonusAmount > 0) {
        IStakingVault(vault).withdraw(address(this), msg.sender, bonusAmount);
        bonusInfo[msg.sender].epoch = epoch.number;
        bonusInfo[msg.sender].principal = IERC20(KISS).balanceOf(msg.sender).sub(_amount);
    } else {
        uint256 balance = IERC20(KISS).balanceOf(msg.sender);
        uint256 remain = balance.sub(_amount);
        bonusInfo[msg.sender].principal = remain > bonusInfo[msg.sender].principal
            ? bonusInfo[msg.sender].principal
            : remain; // <-- incorrect logic
    }

    IERC20(LOVE).approve(lockup, 0);
    IERC20(LOVE).approve(lockup, totalAmount);
    IStakingLockup(lockup).unstake(msg.sender, totalAmount);
    IERC20(KISS).safeTransferFrom(msg.sender, address(this), _amount);
}
```

An attacker can artificially reduce their visible KISS balance (by transferring tokens to another controlled address) before calling `unstake()`, the contract interprets this as a withdrawal and drastically reduces the attacker recorded `principal`, even though they still hold the tokens.

### Vector

1.  **Deposit** Attacker stakes `N` LOVE, receives `N` KISS. `principal` is `N`.
2.  **Hide** Attacker transfers most of their KISS tokens away.
3.  **Manipulation** Attacker calls `unstake()` with a small amount and `_bonus=0`, the contract sees a low balance and reduces their `principal` to a near-zero value.
4.  **Recover** Attacker transfers the KISS tokens back.
5.  **Fake Earn** The contract now calculates `earned = balance - principal`, since `principal` is near-zero, almost the entire balance is considered "earned".
6.  **Claim** The attacker waits for their `loyaltyRatio` to increase, then claims a large bonus based on these artificial earnings.

---

## Exploit 2 - Epoch & LoyaltyRatio Manipulation

### Description

Vulnerability lies in how the contract manages time and loyalty, the `rebase()` function is public and can be called by anyone to advance the contract epoch, however, it only processes one epoch per call.

```solidity
function rebase() public {
    if (epoch.endBlock <= block.number) {
        IKISS(KISS).rebase(epoch.distribute, epoch.number);

        epoch.endBlock = epoch.endBlock.add(epoch.length);
        epoch.number++; // <-- advance epoch.number

        if (distributor != address(0)) {
            IDistributor(distributor).distribute();
        }

        uint256 balance = contractBalance();
        uint256 staked = IKISS(KISS).circulatingSupply();

        if (balance <= staked) {
            epoch.distribute = 0;
        } else {
            epoch.distribute = balance.sub(staked);
        }
    }
}
```

This allows an attacker to repeatedly call the function if a long time has passed, artificially inflating the `epoch.number`, the user loyalty is calculated based on the number of epochs passed since they staked

```solidity
function getLoyaltyRatio(address _depositor) public view returns (uint8) {
    BonusInfo memory info = bonusInfo[_depositor];
    if (info.epoch == 0) return 0; 
    uint8[11] memory fibonacciSequence = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144];
    // vulnerable epochPassed calculation
    uint256 epochPassed = epoch.number.sub(info.epoch);
    if (epochPassed >= 144) {
        return 100; // <-- 100% loyalty
    } else if (epochPassed > 0) {
        for (uint8 i = 0; i < 11; i++) {
            if (epochPassed < fibonacciSequence[i]) {
                return fibonacciSequence[i - 1];
            }
        }
    }

    return 0;
}
```

by controlling `epoch.number`, the attacker controls `epochPassed` and can grant themselves maximum loyalty instantly.

### Vector

1.  **Deposit** The attacker stakes any amount of LOVE, their `bonusInfo.epoch` is recorded.
2.  **Spam `rebase()`** The attacker calls the `rebase()` function 144 times in rapid succession, this advances `epoch.number` by 144.
3.  **100% Loyalty** The `getLoyaltyRatio()` function now calculates `epochPassed` to be >= 144 and returns 100.
4.  **Claim Max Bonus** The attacker can immediately call `unstake()` and claim the maximum possible bonus, a privilege that should have taken 48 days to acquire.

### Impact

*   **Drain Funds** Direct and critical threat to the **$50,163** of TVL. An attacker can systematically drain funds from the contract.
*   **Bypasses Core Protocol Mechanic** This attack completely nullifies the time-based staking incentive (loyalty), which is a core part of the protocol tokenomics.
*   **Instant, Unearned Gains:** It allows an attacker to extract the maximum bonus immediately after staking.
*   **Compounding Threat** When combined with the principal manipulation vulnerability, an attacker can first create a large amount of fake `earned` tokens, and then use this second exploit to claim a bonus on them immediately at a 100% ratio.

---

## 4. Recommendations

### Principal Manipulation

The `principal` recalculation logic in `unstake()` must be removed. A user's principal should only ever decrease by the explicit amount of capital they are withdrawing. It should never be inferred from a volatile token balance.

```solidity
// Recommended logic for principal decrease
uint256 amountToUnstakeFromPrincipal = ...;
bonusInfo[msg.sender].principal = bonusInfo[msg.sender].principal.sub(amountToUnstakeFromPrincipal);
```

### Epoch Manipulation

The `rebase()` function must be hardened against manipulation. It should process multiple pending epochs in a single call to ensure that the contract state is updated atomically. To prevent out-of-gas errors, this loop should be capped.

```solidity
// Recommended fix for rebase()
function rebase() public {
    // Cap iterations to prevent out-of-gas, while processing enough epochs
    // to neutralize the loyalty attack vector. 144 is a robust choice.
    for (uint i = 0; i < 144; i++) {
        if (epoch.endBlock <= block.number) {
            IKISS(KISS).rebase(epoch.distribute, epoch.number);

            epoch.endBlock = epoch.endBlock.add(epoch.length);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();
            uint256 staked = IKISS(KISS).circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked);
            }
        } else {
            // Exit loop once all pending epochs are processed
            break;
        }
    }
}
```
