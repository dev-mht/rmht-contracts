// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

/// @title MockRMHTWithRewards
/// @notice Mock minimal de RMHT.sol pour tester RMHTAirdropCustodian en isolation.
/// @dev Reproduit fidèlement le comportement réel de claimRewards() (y compris le
///      revert si reward == 0 — voir RMHT.sol ligne "RMHT: No rewards") plutôt que
///      de simuler un comportement idéalisé, pour que les tests du custodian
///      détectent les incompatibilités d'intégration réelles.
contract MockRMHTWithRewards {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public pendingRewardOf_;

    bool public transferShouldFail;

    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Helper de test : crédite `to` en tokens (simule le mint initial de l'allocation).
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Helper de test : simule l'accumulation d'un reward de palier pour `account`
    ///         côté RMHT.sol (ce que ferait _updateReward() sur franchissement de milestone).
    function accrueReward(address account, uint256 amount) external {
        pendingRewardOf_[account] += amount;
    }

    /// @notice Helper de test : force transfer() à échouer (return false), pour couvrir
    ///         la branche TransferFailed() de claim()/claimReward().
    function setTransferShouldFail(bool status) external {
        transferShouldFail = status;
    }

    function pendingRewardsOf(address account) external view returns (uint256) {
        return pendingRewardOf_[account];
    }

    /// @notice Mock de RMHT.milestonesReached() (interface IRMHTRewards, requis par
    ///         claim() depuis le déblocage hybride du 22/08/2026). Fixe à 0 par défaut
    ///         (`unlockedByMilestone` toujours faux) pour ne pas interférer avec les
    ///         scénarios existants basés sur `unlockTime`. Overridable par les tests
    ///         qui veulent spécifiquement couvrir le déblocage anticipé par palier.
    uint256 public milestonesReached_;

    function milestonesReached() external view returns (uint256) {
        return milestonesReached_;
    }

    /// @notice Helper de test : simule le nombre de paliers franchis côté RMHT.sol.
    function setMilestonesReached(uint256 value) external {
        milestonesReached_ = value;
    }

    /// @dev Reproduit RMHT.sol : revert si rien à réclamer, sinon transfert direct
    ///      (pas de mint : le "vault" mock est illimité pour simplifier le test).
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
