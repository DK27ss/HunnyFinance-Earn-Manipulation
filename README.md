# HunnyFinance - earn Inflation & loyaltyRatio Manipulation

**Affected Contract:** `HyperStaking` 

(Proxy at `0x31dd9Be51cC7A96359cAaE6Cb4f5583C89D81985` on BSC)

---

## Summary

The `HyperStaking` contract contains at least two critical vulnerabilities.

1.  **Principal Manipulation** An attacker can manipulate the internal accounting of their principal investment to generate artificial "earned" tokens, allowing them to claim illegitimate bonuses.
2.  **Epoch Manipulation** An attacker can bypass the time-based loyalty mechanism by repeatedly calling the `rebase()` function, granting them 100% loyalty instantly to maximize bonus theft.

Both vulnerabilities can be exploited independently to drain funds from the protocol.

---

## Exploit 1 - Earn Manipulation

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

<img width="1629" height="344" alt="Screenshot from 2025-11-28 15-58-36" src="https://github.com/user-attachments/assets/6723ff02-ca5c-4c04-b84e-98c5187f2c85" />

// Execution flow - https://app.blocksec.com/explorer/tx/bsc/0x78fb374db2c8ba6bd3dc0b4c69f2a9c4ac6ea4f011a6533ce6f0696913172a8e

<img width="2255" height="390" alt="Screenshot from 2025-11-28 15-57-16" src="https://github.com/user-attachments/assets/45d76991-1830-4859-8a33-2d98a0020a7c" />

### Vector

1.  **Deposit** Attacker stakes `N` LOVE, receives `N` KISS. `principal` is `N`.
2.  **Hide** Attacker transfers most of their KISS tokens away.
3.  **Manipulation** Attacker calls `unstake()` with a small amount and `_bonus=0`, the contract sees a low balance and reduces their `principal` to a near-zero value.
4.  **Recover** Attacker transfers the KISS tokens back.
5.  **Inflated Earn** The contract now calculates `earned = balance - principal`, since `principal` is near-zero, almost the entire balance is considered "earned".
6.  **Claim** The attacker waits for their `loyaltyRatio` to increase, then claims a large bonus based on these artificial earnings.

---

## Exploit 2 - loyaltyRatio Manipulation

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

<img width="1377" height="284" alt="Screenshot from 2025-11-28 15-13-31" src="https://github.com/user-attachments/assets/678e496a-2bb5-4e0c-b08e-424fe5e0d5c4" />

with instant `loyaltyRatio`, the attacker therefore receives a `100% bonus` based on their inflated `earn` from the previous manipulation.

<img width="585" height="284" alt="Screenshot from 2025-11-28 15-12-20" src="https://github.com/user-attachments/assets/d9be9a96-d2d2-4c93-9c78-5fe7201109af" />

https://app.blocksec.com/explorer/tx/bsc/0x2fde0b10da04e2b13f0572fd928363a75a5cd1c2ef280107f198c713a7097008

### Vector

1.  **Deposit** The attacker stakes any amount of LOVE, their `bonusInfo.epoch` is recorded.
2.  **Rebase** The attacker calls the `rebase()` function 144 times in rapid succession, this advances `epoch.number` by 144.
3.  **Manipulation** The `getLoyaltyRatio()` function now calculates `epochPassed` to be >= 144 and returns 100.
4.  **Claim** The attacker can immediately call `unstake()` and claim the maximum possible bonus, a privilege that should have taken 48 days to acquire.

### Impact

*   **Drain** Direct and critical threat to the **$50,163** (10,114,087 LOVE) of TVL, an attacker can systematically drain funds from the contract.
*   This attack completely nullifies the time-based staking incentive `loyalty`, which is a core part of the protocol tokenomics, It allows an attacker to extract the maximum bonus immediately after staking.
*   When combined with the principal manipulation vulnerability, an attacker can first create a large amount of fake `earned` tokens, and then use this second exploit to claim a bonus on them immediately at a 100% ratio.

---

### Profit & HUG Dependency

Nuance of this exploit lies in the final profit realization step, while the vulnerabilities allow an attacker to generate a massive `illegitimate` bonus claim, materializing this bonus as actual `LOVE` tokens is gated by another mechanism, the **HUG token**.

- **HUG as a Claim Voucher** The `unstake()` function explicitly limits the claimable bonus amount (`bonusAmount`) to the attacker balance of `HUG` tokens.
- **1:1 Burn Ratio** The `StakingVault` contract, when paying out the bonus, burns an amount of HUG tokens exactly equal to the amount of `LOVE` bonus paid out.

This creates a crucial economic condition for the attack profitability:

**`Price(LOVE) > Price(HUG)`**

Attacker must acquire HUG tokens on the open market, the exploit is only profitable if the cost of acquiring these HUG tokens is less than the value of the `LOVE` tokens they manage to drain.

This dependency on an external, low-liquidity token has two major consequences:

1.  **Economic Bottleneck** The profitability of the attack is not guaranteed and depends on market conditions and the price impact (slippage) of buying the scarce HUG supply.
2.  **Harm to Legitimate Users** It forces a competition for HUG between attackers and legitimate users, since an attacker can generate a much larger potential reward, they have a greater incentive to buy out the entire `HUG supply`, effectively blocking legitimate users from ever claiming their own, patiently-earned bonuses.
