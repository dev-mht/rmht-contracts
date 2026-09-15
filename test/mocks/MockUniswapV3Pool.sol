// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/libraries/UniswapV3TWAP.sol";

/// @notice Mock de pool Uniswap v3 — REÉCRIT le 27/08/2026 pour supporter
///         l'oracle TWAP (observe() / observations() / cardinalité), en plus
///         du spot slot0() qu'il exposait déjà.
///
/// @dev  MODÈLE D'HISTORIQUE : le mock ne simule pas un vrai ring buffer
///       d'observations Uniswap (inutilement complexe et non déterministe) —
///       il stocke une liste de SEGMENTS (timestamp de début, tick), et
///       reconstruit `tickCumulative(t)` par intégration exacte de ces
///       segments. C'est strictement équivalent du point de vue d'un
///       consommateur de `observe()`, et ça permet d'écrire des scénarios de
///       manipulation lisibles ("prix à X pendant 1h, puis pompé à Y").
///
///       DEUX SÉMANTIQUES DE CHANGEMENT DE PRIX, à ne pas confondre :
///         • setSqrtPriceX96(v)  → RÉÉCRIT tout l'historique : la pool se
///           comporte comme si le prix avait TOUJOURS valu v. Le TWAP est
///           donc égal au spot. C'est le comportement historique attendu par
///           les tests écrits avant le passage au TWAP (ils changeaient le
///           spot et lisaient le prix dans la foulée) — d'où leur validité
///           inchangée.
///         • applyPriceChange(v) → AJOUTE un segment à partir de maintenant,
///           en conservant l'historique passé. C'est ce qu'il faut pour
///           tester un vrai TWAP : après un pump instantané, le TWAP reste
///           proche de l'ancien prix tant que la fenêtre n'a pas défilé.
contract MockUniswapV3Pool {
    address public immutable token0Addr;
    address public immutable token1Addr;
    uint160 public sqrtPriceX96Value;

    /// @dev AJOUTÉ 24/08/2026 (couverture de branches) : true par défaut
    ///      (comportement identique à avant), permet de simuler une pool
    ///      verrouillée mid-swap pour tester "RMHT: Pool locked mid-swap"
    ///      et le no-op équivalent dans _pokeMilestone().
    bool public unlockedValue = true;

    // ───────────────────────── état oracle (TWAP) ─────────────────────────

    struct TickSegment {
        uint32 startTime;
        int24 tick;
    }

    TickSegment[] private _segments; // ordre croissant de startTime

    /// @notice Timestamp de la plus ancienne observation encore "stockée".
    uint32 public oldestObservationTs;

    uint16 public observationIndexValue;
    uint16 public observationCardinalityValue;
    uint16 public observationCardinalityNextValue;

    /// @dev Permet d'exercer la branche `!initialized` de
    ///      getOldestObservationSecondsAgo() (cardinalité en cours
    ///      d'augmentation : le slot index+1 existe mais n'a jamais été écrit).
    bool public nextSlotInitialized = true;

    /// @notice Historique par défaut d'une pool "mature" dans les tests.
    uint32 public constant DEFAULT_HISTORY = 7 days;

    /// @notice Valeurs de cardinalité par défaut : au-dessus du plancher
    ///         exigé par RMHT.setConfig() (MIN_OBSERVATION_CARDINALITY).
    uint16 public constant DEFAULT_CARDINALITY = 2000;

    constructor(address _token0, address _token1, uint160 _sqrtPriceX96) {
        token0Addr = _token0;
        token1Addr = _token1;
        observationIndexValue = 0;
        observationCardinalityValue = DEFAULT_CARDINALITY;
        observationCardinalityNextValue = DEFAULT_CARDINALITY;
        _resetHistory(_sqrtPriceX96, DEFAULT_HISTORY);
    }

    // ───────────────────────── setters de test ─────────────────────────

    function setUnlocked(bool v) external {
        unlockedValue = v;
    }

    /// @notice Change le prix ET réécrit l'historique : le TWAP vaudra
    ///         exactement ce prix. Sémantique volontairement conservée pour
    ///         que les tests antérieurs au TWAP restent valides tels quels.
    function setSqrtPriceX96(uint160 v) external {
        _resetHistory(v, _currentHistorySpan());
    }

    /// @notice Change le prix À PARTIR DE MAINTENANT, sans toucher au passé.
    ///         C'est le setter à utiliser pour tester le lissage du TWAP.
    function applyPriceChange(uint160 v) external {
        sqrtPriceX96Value = v;
        int24 newTick = tickFromSqrtPriceX96(v);
        uint32 nowTs = uint32(block.timestamp);
        if (_segments.length != 0 && _segments[_segments.length - 1].startTime == nowTs) {
            _segments[_segments.length - 1].tick = newTick;
        } else {
            _segments.push(TickSegment({startTime: nowTs, tick: newTick}));
        }
    }

    /// @notice Fixe la profondeur d'historique disponible (en secondes),
    ///         sans toucher aux prix. `0` = pool qui vient d'écrire une
    ///         observation dans ce bloc même.
    function setHistorySeconds(uint32 secondsOfHistory) external {
        uint32 nowTs = uint32(block.timestamp);
        oldestObservationTs = secondsOfHistory >= nowTs ? 0 : nowTs - secondsOfHistory;
    }

    function setObservationState(uint16 index, uint16 cardinality, uint16 cardinalityNext) external {
        observationIndexValue = index;
        observationCardinalityValue = cardinality;
        observationCardinalityNextValue = cardinalityNext;
    }

    function setNextSlotInitialized(bool v) external {
        nextSlotInitialized = v;
    }

    /// @notice Nombre de segments de prix actuellement en mémoire (debug).
    function segmentCount() external view returns (uint256) {
        return _segments.length;
    }

    // ───────────────────────── interface pool ─────────────────────────

    function token0() external view returns (address) {
        return token0Addr;
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (
            sqrtPriceX96Value,
            _segments.length == 0 ? int24(0) : _segments[_segments.length - 1].tick,
            observationIndexValue,
            observationCardinalityValue,
            observationCardinalityNextValue,
            0,
            unlockedValue
        );
    }

    /// @dev Reproduit le contrat d'`observe()` d'Uniswap v3, y compris le
    ///      revert 'OLD' quand la cible dépasse l'historique disponible.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            require(uint256(secondsAgos[i]) <= block.timestamp, "OLD");
            uint32 target = uint32(block.timestamp) - secondsAgos[i];
            require(target >= oldestObservationTs, "OLD");
            tickCumulatives[i] = _tickCumulativeAt(target);
        }
    }

    /// @dev Seuls les index réellement consultés par
    ///      UniswapV3TWAP.getOldestObservationSecondsAgo() ont besoin d'être
    ///      fidèles : l'index "le plus ancien" et l'index 0 de repli.
    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized)
    {
        if (index != 0 && !nextSlotInitialized) {
            // Uniswap écrit blockTimestamp = 1 dans les slots pré-alloués mais
            // jamais encore utilisés (grow()), avec initialized = false.
            return (1, 0, 0, false);
        }
        return (oldestObservationTs, 0, 0, true);
    }

    // ───────────────────────── internes ─────────────────────────

    function _currentHistorySpan() internal view returns (uint32) {
        uint32 nowTs = uint32(block.timestamp);
        return nowTs > oldestObservationTs ? nowTs - oldestObservationTs : 0;
    }

    function _resetHistory(uint160 sqrtPriceX96, uint32 historySeconds) internal {
        sqrtPriceX96Value = sqrtPriceX96;
        uint32 nowTs = uint32(block.timestamp);
        uint32 start = historySeconds >= nowTs ? 0 : nowTs - historySeconds;
        oldestObservationTs = start;
        delete _segments;
        _segments.push(TickSegment({startTime: start, tick: tickFromSqrtPriceX96(sqrtPriceX96)}));
    }

    /// @dev Intégrale du tick de `oldestObservationTs` à `t`, exactement ce
    ///      que la pool réelle accumule dans `tickCumulative`.
    function _tickCumulativeAt(uint32 t) internal view returns (int56 acc) {
        for (uint256 i = 0; i < _segments.length; i++) {
            uint32 segStart = _segments[i].startTime;
            if (segStart < oldestObservationTs) segStart = oldestObservationTs;
            if (segStart >= t) break;

            uint32 segEnd = (i + 1 < _segments.length) ? _segments[i + 1].startTime : t;
            if (segEnd > t) segEnd = t;
            if (segEnd <= segStart) continue;

            acc += int56(_segments[i].tick) * int56(uint56(segEnd - segStart));
        }
    }

    /// @notice Inverse (approché au tick près) de
    ///         UniswapV3TWAP.getSqrtRatioAtTick — recherche dichotomique sur
    ///         la plage de ticks valides. Test-only : le gas n'a aucune
    ///         importance ici, et ça évite de porter getTickAtSqrtRatio()
    ///         (et son lot de constantes magiques) dans le code de
    ///         production juste pour les besoins des mocks.
    function tickFromSqrtPriceX96(uint160 sqrtPriceX96) public pure returns (int24) {
        int24 lo = -887272;
        int24 hi = 887272;
        if (sqrtPriceX96 < UniswapV3TWAP.getSqrtRatioAtTick(lo)) return lo;
        while (lo < hi) {
            int24 mid = lo + int24((int256(hi) - int256(lo) + 1) / 2);
            if (UniswapV3TWAP.getSqrtRatioAtTick(mid) <= sqrtPriceX96) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }
}
