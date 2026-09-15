// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../src/libraries/UniswapV3TWAP.sol";
import "./mocks/MockUniswapV3Pool.sol";

/// @notice Enveloppe EXTERNE des fonctions `internal` de la librairie.
/// @dev  Nécessaire pour tester les revert : une fonction `internal` de
///       librairie est inlinée dans l'appelant, donc son `require` remonte à
///       la même profondeur d'appel que le cheatcode `vm.expectRevert`, qui
///       refuse alors de matcher ("call didn't revert at a lower depth").
///       Passer par un contrat tiers rétablit une vraie frontière d'appel.
contract TWAPHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return UniswapV3TWAP.getSqrtRatioAtTick(tick);
    }

    function consult(address pool, uint32 secondsAgo) external view returns (int24) {
        return UniswapV3TWAP.consult(pool, secondsAgo);
    }

    function getOldestObservationSecondsAgo(address pool) external view returns (uint32) {
        return UniswapV3TWAP.getOldestObservationSecondsAgo(pool);
    }
}

/// @notice Tests unitaires de la librairie TWAP portée depuis Uniswap v3
///         (src/libraries/UniswapV3TWAP.sol), écrits le 27/08/2026 en même
///         temps que la résolution de S8.1.G4.
///
/// @dev  STRATÉGIE DE VÉRIFICATION DU PORT `getSqrtRatioAtTick` — le risque
///       n°1 d'un port bit-à-bit est UNE constante magique recopiée de
///       travers (19 constantes de 128 bits). Trois filets indépendants, dont
///       aucun ne réutilise les constantes du fichier testé :
///         1. Les deux valeurs PUBLIÉES d'Uniswap, MIN_SQRT_RATIO et
///            MAX_SQRT_RATIO, qui sont les sorties de la chaîne COMPLÈTE de
///            constantes aux ticks extrêmes : une seule constante fausse les
///            décale. C'est le test le plus discriminant du lot.
///         2. Le point fixe exact tick 0 → 2^96.
///         3. Une comparaison à des valeurs de sqrt(1.0001^tick)·2^96
///            calculées hors-chaîne en arithmétique décimale 200 chiffres
///            (donc sans passer par les constantes), avec une tolérance
///            relative de 1e-9 — l'erreur réelle mesurée sur toute la plage
///            de ticks est ≤ 2,03e-10.
contract UniswapV3TWAPTest is Test {
    /// @dev Valeurs publiées par Uniswap v3-core (TickMath.sol).
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;

    /// @dev Timestamp de départ, en LITTÉRAL. Avec via_ir, `uint256 t0 =
    ///      block.timestamp;` n'est pas fiable entre deux vm.warp() :
    ///      l'optimiseur peut re-substituer block.timestamp à la variable et
    ///      donc relire l'horloge APRÈS le premier warp (constaté ici : le
    ///      second warp partait de t0 déjà décalé). Des constantes littérales
    ///      suppriment le problème à la racine.
    uint256 constant T0 = 1_700_000_000;

    MockUniswapV3Pool pool;
    TWAPHarness harness;

    function setUp() public {
        vm.warp(T0);
        pool = new MockUniswapV3Pool(address(0xA), address(0xB), uint160(2 ** 96));
        harness = new TWAPHarness();
    }

    // ═════════════════ getSqrtRatioAtTick — exactitude du port ═════════════

    /// @notice Filet n°1 : les deux constantes publiées par Uniswap sont les
    ///         sorties de la chaîne entière aux ticks extrêmes.
    function test_SqrtRatio_MatchesPublishedUniswapBounds() public pure {
        assertEq(UniswapV3TWAP.getSqrtRatioAtTick(MIN_TICK), MIN_SQRT_RATIO, "MIN_SQRT_RATIO");
        assertEq(UniswapV3TWAP.getSqrtRatioAtTick(MAX_TICK), MAX_SQRT_RATIO, "MAX_SQRT_RATIO");
    }

    /// @notice Filet n°2 : point fixe exact, sqrt(1.0001^0)·2^96 = 2^96.
    function test_SqrtRatio_TickZeroIsExactlyQ96() public pure {
        assertEq(UniswapV3TWAP.getSqrtRatioAtTick(0), uint160(2 ** 96));
    }

    /// @notice Filet n°3 : comparaison aux valeurs mathématiques exactes,
    ///         calculées hors-chaîne sans les constantes du port.
    function test_SqrtRatio_MatchesHighPrecisionReference() public pure {
        _assertTickApprox(1, 79232123823359799118286999567);
        _assertTickApprox(-1, 79224201403219477170569942573);
        _assertTickApprox(60, 79466191966197645195421774832);
        _assertTickApprox(-60, 78990846045029531151608375685);
        _assertTickApprox(100, 79625275426524748796330556127);
        _assertTickApprox(-100, 78833030112140176575862854578);
        _assertTickApprox(10000, 130621891405341611593710811005);
        _assertTickApprox(-10000, 48055510970269007215549348796);
        _assertTickApprox(200000, 1744244129640337381386292603617837);
        _assertTickApprox(-200000, 3598751819609688046946418);
        _assertTickApprox(500000, 5697689776495288729098254599936056708424);
        _assertTickApprox(-500000, 1101692437043807370);
        _assertTickApprox(887271, 1461373636630004318672046398259762639463073250156);
        _assertTickApprox(-887271, 4295343489);
    }

    /// @dev Tolérance relative 1e-9 (l'écart réel maximal mesuré sur toute la
    ///      plage vaut 2,03e-10). Comparaison en entiers pour ne pas
    ///      réintroduire d'imprécision dans le test lui-même.
    function _assertTickApprox(int24 tick, uint256 expected) internal pure {
        uint256 got = UniswapV3TWAP.getSqrtRatioAtTick(tick);
        uint256 diff = got > expected ? got - expected : expected - got;
        // diff / expected <= 1e-9  <=>  diff * 1e9 <= expected
        assertLe(diff * 1e9, expected, "ecart relatif > 1e-9 vs reference exacte");
    }

    /// @notice Le résultat doit TOUJOURS tenir dans uint160 (le downcast du
    ///         port est non vérifié — c'est la contrainte |tick| <= MAX_TICK
    ///         qui le rend sûr, exactement comme dans l'original).
    function testFuzz_SqrtRatio_AlwaysFitsUint160(int24 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        uint256 r = UniswapV3TWAP.getSqrtRatioAtTick(tick);
        assertLe(r, type(uint160).max);
        assertGe(r, MIN_SQRT_RATIO);
        assertLe(r, MAX_SQRT_RATIO);
    }

    /// @notice Strictement croissant : une constante fausse casserait la
    ///         monotonie sur au moins un bit de l'exposant.
    function testFuzz_SqrtRatio_StrictlyIncreasing(int24 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick < MAX_TICK);
        assertLt(
            UniswapV3TWAP.getSqrtRatioAtTick(tick),
            UniswapV3TWAP.getSqrtRatioAtTick(tick + 1)
        );
    }

    /// @notice Symétrie : sqrt(1.0001^t)·sqrt(1.0001^-t) = 2^192, à l'erreur
    ///         d'arrondi près (les deux branches du port — avec et sans
    ///         l'inversion `type(uint256).max / ratio` — doivent se répondre).
    function testFuzz_SqrtRatio_ReciprocalSymmetry(int24 tick) public pure {
        vm.assume(tick > 0 && tick <= MAX_TICK);
        uint256 up = UniswapV3TWAP.getSqrtRatioAtTick(tick);
        uint256 down = UniswapV3TWAP.getSqrtRatioAtTick(-tick);
        uint256 product = up * down; // <= MAX_SQRT_RATIO * MIN_SQRT_RATIO, pas d'overflow
        uint256 target = 2 ** 192;
        uint256 diff = product > target ? product - target : target - product;
        assertLe(diff * 1e6, target, "symetrie t / -t hors tolerance");
    }

    function test_RevertSqrtRatio_AboveMaxTick() public {
        vm.expectRevert(bytes("T"));
        harness.getSqrtRatioAtTick(MAX_TICK + 1);
    }

    function test_RevertSqrtRatio_BelowMinTick() public {
        vm.expectRevert(bytes("T"));
        harness.getSqrtRatioAtTick(MIN_TICK - 1);
    }

    /// @notice Le cast `-int256(tick)` doit encaisser type(int24).min sans
    ///         déborder (c'est le seul endroit où un port naïf en 0.8
    ///         planterait autrement qu'avec le revert "T" attendu).
    function test_RevertSqrtRatio_Int24Min() public {
        vm.expectRevert(bytes("T"));
        harness.getSqrtRatioAtTick(type(int24).min);
    }

    // ═════════════════════════ consult ═════════════════════════

    /// @notice Historique plat : le tick moyen est exactement le tick courant.
    function test_Consult_FlatHistoryReturnsCurrentTick() public {
        int24 expectedTick = pool.tickFromSqrtPriceX96(uint160(2 ** 96));
        assertEq(UniswapV3TWAP.consult(address(pool), 1800), expectedTick);
    }

    /// @notice Moyenne pondérée par le temps sur deux régimes de prix :
    ///         tick A pendant la première moitié de la fenêtre, tick B
    ///         pendant la seconde → moyenne = (A + B) / 2.
    function test_Consult_TimeWeightedAverageOfTwoRegimes() public {
        // Historique remis à plat sur un tick connu.
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(0xA), address(0xB), uint160(2 ** 96));
        int24 tickA = p.tickFromSqrtPriceX96(uint160(2 ** 96)); // 0

        // 900 s plus tard, le prix change ; on lit 900 s après ça.
        vm.warp(T0 + 900);
        uint160 newSqrt = UniswapV3TWAP.getSqrtRatioAtTick(2000);
        p.applyPriceChange(newSqrt);
        int24 tickB = p.tickFromSqrtPriceX96(newSqrt);
        vm.warp(T0 + 1800);

        int24 mean = UniswapV3TWAP.consult(address(p), 1800);
        int24 expected = int24((int256(tickA) * 900 + int256(tickB) * 900) / 1800);
        assertEq(mean, expected);
        // Et surtout : la moyenne est STRICTEMENT entre les deux régimes,
        // donc le TWAP lisse bien au lieu de suivre le spot.
        assertGt(mean, tickA);
        assertLt(mean, tickB);
    }

    /// @notice Arrondi vers -infini sur delta négatif non divisible — c'est
    ///         le `if (delta < 0 && delta % secondsAgo != 0) tick--` du port.
    ///         Sans lui, la division entière de Solidity arrondirait vers 0,
    ///         donc surestimerait le prix moyen sur un tick négatif.
    function test_Consult_RoundsTowardNegativeInfinity() public {
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(0xA), address(0xB), uint160(2 ** 96));

        // 1000 s au tick 0, puis 1 s au tick -1 : cumul = -1 sur 1001 s.
        // -1 / 1001 = 0 en division tronquée, doit donner -1 après correction.
        vm.warp(T0 + 1000);
        p.applyPriceChange(UniswapV3TWAP.getSqrtRatioAtTick(-1));
        vm.warp(T0 + 1001);

        assertEq(UniswapV3TWAP.consult(address(p), 1001), int24(-1));
    }

    function test_RevertConsult_ZeroWindow() public {
        vm.expectRevert(bytes("UniswapV3TWAP: BP"));
        harness.consult(address(pool), 0);
    }

    /// @notice Fenêtre plus longue que l'historique réellement stocké : la
    ///         pool elle-même revert ("OLD"). C'est précisément ce que le
    ///         garde-fou fail-closed de RMHT.getRMHTPriceInETH() évite
    ///         d'atteindre en production.
    function test_RevertConsult_WindowLongerThanHistory() public {
        pool.setHistorySeconds(100);
        vm.expectRevert(bytes("OLD"));
        harness.consult(address(pool), 1800);
    }

    // ═════════════ getOldestObservationSecondsAgo ═════════════

    function test_OldestObservation_ReportsStoredHistory() public {
        pool.setHistorySeconds(1234);
        assertEq(UniswapV3TWAP.getOldestObservationSecondsAgo(address(pool)), 1234);
    }

    /// @notice Pool fraîchement créée : cardinalité 1, une seule observation
    ///         écrite dans ce bloc → 0 seconde d'historique disponible.
    function test_OldestObservation_FreshPoolReturnsZero() public {
        pool.setObservationState(0, 1, 1);
        pool.setHistorySeconds(0);
        assertEq(UniswapV3TWAP.getOldestObservationSecondsAgo(address(pool)), 0);
    }

    /// @notice Branche `!initialized` : cardinalité en cours d'augmentation,
    ///         le slot index+1 est pré-alloué mais jamais écrit → repli sur
    ///         l'observation 0 (comportement de l'OracleLibrary officiel).
    function test_OldestObservation_FallsBackToIndexZeroWhenNotInitialized() public {
        pool.setHistorySeconds(777);
        pool.setNextSlotInitialized(false);
        assertEq(UniswapV3TWAP.getOldestObservationSecondsAgo(address(pool)), 777);
    }

    function test_RevertOldestObservation_ZeroCardinality() public {
        pool.setObservationState(0, 0, 0);
        vm.expectRevert(bytes("UniswapV3TWAP: NI"));
        harness.getOldestObservationSecondsAgo(address(pool));
    }

    // ═══════════ cohérence port ↔ inverse (aller-retour) ═══════════

    /// @notice getSqrtRatioAtTick puis recherche du tick correspondant doit
    ///         redonner le tick de départ — vérifie que la fonction est bien
    ///         injective sur la grille de ticks (pas de plateau dû à une
    ///         constante trop petite).
    function testFuzz_SqrtRatio_RoundTripThroughTick(int24 tick) public view {
        vm.assume(tick >= MIN_TICK && tick < MAX_TICK);
        uint160 s = UniswapV3TWAP.getSqrtRatioAtTick(tick);
        assertEq(pool.tickFromSqrtPriceX96(s), tick);
    }
}
