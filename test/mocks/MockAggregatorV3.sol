// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

// ═══════════════════════════════════════════════════════════════════════════
//  MockAggregatorV3 — pour les tests Foundry (test/RMHT.t.sol,
//  test/invariants/RMHT.invariant.t.sol)
//
//  API alignée sur ce que ces fichiers appellent réellement :
//    - constructeur à 1 argument : MockAggregatorV3(uint8 decimals_)
//    - setRoundData(int256 answer, uint256 startedAt, uint256 updatedAt)
//      pour fixer answer/startedAt/updatedAt en un seul appel.
//
//  ⚠️ Ce fichier est distinct de script/MockAggregatorV3_testnet_20260802_2145.sol
//  (utilisé par le script de déploiement testnet), qui garde volontairement
//  une API différente (constructeur à 2 arguments, setFixedTimestamp, etc.)
//  car c'est ce qu'attend DeployRMHT_testnet_20260802_2145.s.sol. Les deux
//  fichiers ne sont pas interchangeables.
// ═══════════════════════════════════════════════════════════════════════════

// Réutilise l'interface déjà déclarée dans src/RMHT.sol au lieu de la
// redéclarer ici : les deux définitions étaient identiques mais, comme
// distinctes, provoquaient "Identifier already declared" dès qu'un fichier
// de test importait à la fois src/RMHT.sol et ce mock (ex: test/RMHT.t.sol).
import {AggregatorV3Interface} from "../../src/RMHT.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    address public owner;
    uint8 private immutable _decimals;

    uint80 private _roundId;
    int256 private _answer;

    /// @dev On ne stocke pas startedAt/updatedAt en absolu, mais leur écart
    ///      avec block.timestamp AU MOMENT de setRoundData(). latestRoundData()
    ///      rejoue cet écart sur le block.timestamp courant à chaque lecture.
    ///      Ça reproduit le comportement "autoFresh" attendu par les tests :
    ///      setRoundData(answer, block.timestamp, block.timestamp) doit rester
    ///      "frais" même après un vm.warp() ultérieur sans nouvel appel — voir
    ///      test_PerformUpkeep_WorksAfterCooldown /
    ///      testFuzz_MultipleMilestones_NeverExceedVault, qui warpent puis
    ///      relisent le feed sans le rafraîchir. Un simple stockage figé de
    ///      updatedAt le rendrait périmé (RMHT: ETH price feed stale) dès que
    ///      le warp dépasse ETH_USD_HEARTBEAT.
    uint256 private _startedAtOffset;
    uint256 private _updatedAtOffset;

    /// @dev AJOUTÉ 24/08/2026 (couverture de branches) : par défaut,
    ///      latestRoundData() renvoie toujours answeredInRound == roundId,
    ///      ce qui rend structurellement impossible de tester le require
    ///      côté RMHT.sol ("Stale price round" / "Stale sequencer round").
    ///      Ce flag permet de simuler un round périmé (answeredInRound
    ///      volontairement en retard sur roundId) sans changer le
    ///      comportement par défaut de tous les tests existants.
    bool private _forceStaleRound;

    event RoundDataSet(int256 answer, uint256 startedAt, uint256 updatedAt);

    modifier onlyOwner() {
        require(msg.sender == owner, "MockAggregatorV3: Not owner");
        _;
    }

    /// @param decimals_ Nombre de decimals du feed (8 = standard Chainlink USD feeds)
    constructor(uint8 decimals_) {
        owner = msg.sender;
        _decimals = decimals_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 reportedAnsweredInRound = _forceStaleRound && _roundId > 0 ? _roundId - 1 : _roundId;
        return (_roundId, _answer, block.timestamp - _startedAtOffset, block.timestamp - _updatedAtOffset, reportedAnsweredInRound);
    }

    /// @notice AJOUTÉ 24/08/2026 — active/désactive la simulation d'un round
    ///         périmé (answeredInRound < roundId) pour tester les requires
    ///         "RMHT: Stale price round" / "RMHT: Stale sequencer round".
    function setForceStaleRound(bool stale) external onlyOwner {
        _forceStaleRound = stale;
    }

    /// @notice Fixe answer/startedAt/updatedAt et incrémente roundId.
    ///         startedAt/updatedAt sont interprétés comme "il y a X secondes
    ///         par rapport à maintenant" (X = offset) — cet écart est ensuite
    ///         rejoué sur block.timestamp à chaque lecture de latestRoundData().
    function setRoundData(int256 answer, uint256 startedAt, uint256 updatedAt) external onlyOwner {
        require(startedAt <= block.timestamp && updatedAt <= block.timestamp, "MockAggregatorV3: future timestamp");
        _answer = answer;
        _startedAtOffset = block.timestamp - startedAt;
        _updatedAtOffset = block.timestamp - updatedAt;
        _roundId += 1;
        emit RoundDataSet(answer, startedAt, updatedAt);
    }
}

