// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

/// @title MockRMHTWithMilestones
/// @notice Mock minimal de RMHT.sol pour tester RMHTFounderCustodian en isolation.
/// @dev Expose transfer()/balanceOf() (IERC20), milestonesReached(), et — depuis
///      le 28/08/2026 — claimRewards()/pendingRewardsOf() (IRMHTRewards), le
///      sous-ensemble utilisé par RMHTFounderCustodian.sol depuis l'ajout des
///      rewards de palier réclamables.
contract MockRMHTWithMilestones {
    mapping(address => uint256) public balanceOf;
    uint256 public milestonesReached;

    /// @notice Rewards de palier accumulés côté "RMHT" pour chaque adresse.
    /// @dev AJOUT 28/08/2026 — même modélisation que MockRMHTWithRewards.
    mapping(address => uint256) public pendingRewardOf_;

    bool public transferShouldFail;

    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Helper de test : crédite `to` en tokens (simule le mint initial de l'allocation).
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Helper de test : fixe directement le nombre de paliers franchis,
    ///         sans simuler tout le mécanisme pokeMilestone() de RMHT.sol.
    function setMilestonesReached(uint256 count) external {
        milestonesReached = count;
    }

    /// @notice Helper de test : force transfer() à échouer (return false), pour couvrir
    ///         la branche TransferFailed() de claim().
    function setTransferShouldFail(bool status) external {
        transferShouldFail = status;
    }

    /// @notice Helper de test : simule l'accumulation d'un reward de palier pour
    ///         `account` côté RMHT.sol (ce que fait _updateReward() au franchissement).
    function accrueReward(address account, uint256 amount) external {
        pendingRewardOf_[account] += amount;
    }

    /// @notice Miroir de RMHT.pendingRewardsOf().
    function pendingRewardsOf(address account) external view returns (uint256) {
        return pendingRewardOf_[account];
    }

    /// @dev Reproduit FIDÈLEMENT RMHT.claimRewards(), revert "RMHT: No rewards"
    ///      compris : c'est précisément ce revert qui faisait échouer
    ///      harvestVaultRewards() à vide avant le fix du 28/08/2026, et le
    ///      mock doit le reproduire pour que le test ait un sens.
    function claimRewards() external {
        uint256 reward = pendingRewardOf_[msg.sender];
        require(reward != 0, "RMHT: No rewards");
        pendingRewardOf_[msg.sender] = 0;
        balanceOf[msg.sender] += reward;
        emit Transfer(address(0), msg.sender, reward);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        if (transferShouldFail) return false;
        require(balanceOf[msg.sender] >= value, "Mock: insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }
}
