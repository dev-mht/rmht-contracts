// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../src/RMHT.sol";
import "../src/libraries/UniswapV3TWAP.sol";
import "./mocks/MockAggregatorV3.sol";
import "./mocks/MockUniswapV3Pool.sol";

/// @notice Tests d'INTÉGRATION de l'oracle TWAP dans RMHT (27/08/2026,
///         résolution de S8.1.G4). Les tests unitaires de la librairie
///         elle-même sont dans test/UniswapV3TWAP.t.sol.
///
/// @dev  CE QUE CE FICHIER DOIT PROUVER, dans l'ordre d'importance :
///         1. Qu'une manipulation INSTANTANÉE du prix ne déclenche plus de
///            palier — et, dans le même test, qu'elle l'aurait déclenché avec
///            l'ancienne lecture spot (sinon on ne prouve rien : un test qui
///            passe parce que le seuil n'est jamais atteint ne teste rien).
///         2. Que le TWAP finit quand même par refléter un VRAI mouvement de
///            marché soutenu (sinon on aurait juste cassé l'oracle).
///         3. Que le repli sur fenêtre raccourcie — retiré le 27/08/2026 —
///            n'était pas une protection dégradée mais une absence de
///            protection : test de régression explicite.
///         4. Que le comportement fail-closed est bien fail-closed :
///            getRMHTPriceInETH() revert, pokeMilestone() no-op, setConfig()
///            refuse une pool sous-dimensionnée.
contract RMHTTwapTest is Test {
    RMHT rmht;
    MockAggregatorV3 ethUsdFeed;
    MockAggregatorV3 sequencerFeed;
    MockUniswapV3Pool pool;

    address owner = address(0xA11CE);
    address airdropWallet = address(0xA1AD);
    address marketWallet = address(0xA2A2);
    address founderWallet = address(0xF01D);
    /// @dev AJOUT 28/08/2026 — 7e paramètre du constructeur RMHT (feedGovernor_).
    address feedGovernor = address(0xFEED);

    uint256 constant VAULT = 500_000_000 ether;
    uint256 constant AIRDROP = 65_000_000 ether;
    uint256 constant FOUNDER = 50_000_000 ether;
    uint256 constant MARKET = 385_000_000 ether;

    /// @dev cf. note dans test/UniswapV3TWAP.t.sol : littéral obligatoire,
    ///      `block.timestamp + X` n'est pas fiable entre deux vm.warp() sous
    ///      via_ir.
    uint256 constant T0 = 1_700_000_000;

    /// @dev Ticks choisis pour encadrer le PREMIER palier (500 000 $) avec la
    ///      configuration du setUp (supply éligible 5e8 RMHT, ETH à 3000 $) :
    ///        • BASE_TICK  → mcap ≈ 498 k$, juste SOUS le seuil
    ///        • PUMP_TICK  → mcap ≈ 3,4 M$, très au-DESSUS du seuil
    ///      Les tests ci-dessous ne se fient pas à ces valeurs approchées :
    ///      ils asserte(nt) explicitement de quel côté du seuil on se trouve.
    int24 constant BASE_TICK = -149200;
    int24 constant PUMP_TICK = -130000;

    function setUp() public {
        vm.warp(T0);

        vm.prank(owner);
        rmht = new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);

        ethUsdFeed = new MockAggregatorV3(8);
        sequencerFeed = new MockAggregatorV3(0);

        pool = new MockUniswapV3Pool(address(rmht), address(0xBEEF), UniswapV3TWAP.getSqrtRatioAtTick(BASE_TICK));

        sequencerFeed.setRoundData(0, block.timestamp - 2 hours, block.timestamp);
        ethUsdFeed.setRoundData(3000 * 1e8, block.timestamp, block.timestamp);
    }

    function _configure() internal {
        vm.prank(owner);
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
    }

    /// @dev Pool « miroir » dont l'historique est PLAT au tick donné : son
    ///      TWAP vaut donc exactement le spot à ce tick. C'est notre étalon
    ///      « ce qu'aurait lu l'ancien code spot », sans avoir à conserver
    ///      deux versions du contrat.
    function _spotEquivalentMcap(int24 tick) internal returns (uint256) {
        MockUniswapV3Pool mirror =
            new MockUniswapV3Pool(address(rmht), address(0xBEEF), UniswapV3TWAP.getSqrtRatioAtTick(tick));
        RMHT mirrorRmht;
        vm.prank(owner);
        mirrorRmht = new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);
        vm.prank(owner);
        mirrorRmht.setConfig(address(mirror), address(ethUsdFeed), address(sequencerFeed));
        return mirrorRmht.getMarketCap();
    }

    // ══════════════ 1. Manipulation instantanée : TWAP vs spot ══════════════

    /// @notice LE test central de S8.1.G4. Scénario d'attaque réaliste sur
    ///         une L2 : l'attaquant pompe le prix au bloc N, puis appelle
    ///         pokeMilestone() au bloc N+1 (≈ 1 s plus tard).
    ///         - Avec l'ancienne lecture spot : le palier s'arme.
    ///         - Avec le TWAP 30 min : le prix moyen bouge de ~1/1800 du
    ///           mouvement, le seuil n'est pas franchi, rien ne s'arme.
    function test_Attack_InstantPumpThenPoke_DoesNotArmMilestone() public {
        _configure();

        uint256 mcapBefore = rmht.getMarketCap();
        assertLt(mcapBefore, rmht.nextMilestoneUSD(), "setup: mcap de base doit etre SOUS le seuil");

        // Contre-preuve : au prix pompé, une lecture SPOT aurait franchi le
        // seuil. Sans cette assertion, le test passerait même si le pump
        // était trop faible pour compter.
        assertGe(
            _spotEquivalentMcap(PUMP_TICK),
            rmht.nextMilestoneUSD(),
            "setup: le pump doit etre assez fort pour armer en lecture spot"
        );

        // Pump instantané, puis un bloc plus tard on poke.
        pool.applyPriceChange(UniswapV3TWAP.getSqrtRatioAtTick(PUMP_TICK));
        vm.warp(T0 + 1);

        uint256 mcapAfterPump = rmht.getMarketCap();
        assertLt(mcapAfterPump, rmht.nextMilestoneUSD(), "le TWAP ne doit pas franchir le seuil sur 1 s de pump");

        rmht.pokeMilestone();
        assertFalse(rmht.milestoneArmed(), "aucun palier ne doit s'armer");
        assertEq(rmht.milestonesReached(), 0);
    }

    /// @notice Le pump doit être TENU pour compter : après la moitié de la
    ///         fenêtre le TWAP a bougé, mais toujours pas assez ici.
    ///         Quantifie le lissage plutôt que de se contenter d'un booléen.
    function test_Twap_MovesProportionallyToTimeHeld() public {
        _configure();
        uint256 mcapBefore = rmht.getMarketCap();

        pool.applyPriceChange(UniswapV3TWAP.getSqrtRatioAtTick(PUMP_TICK));

        vm.warp(T0 + 1);
        uint256 mcapAfter1s = rmht.getMarketCap();

        vm.warp(T0 + 900);
        uint256 mcapAfter900s = rmht.getMarketCap();

        vm.warp(T0 + 1800);
        uint256 mcapAfterFullWindow = rmht.getMarketCap();

        // Monotone croissant, et l'essentiel du mouvement n'arrive qu'à la
        // fin de la fenêtre — c'est exactement ce qui rend l'attaque chère.
        assertGe(mcapAfter1s, mcapBefore);
        assertGt(mcapAfter900s, mcapAfter1s);
        assertGt(mcapAfterFullWindow, mcapAfter900s);

        // Après 1 s, on est encore à moins de 1 % du chemin parcouru au bout
        // de la fenêtre complète.
        assertLt(mcapAfter1s - mcapBefore, (mcapAfterFullWindow - mcapBefore) / 100);
    }

    /// @notice Contrepartie indispensable : un VRAI mouvement de marché,
    ///         tenu sur toute la fenêtre, doit bien finir par déclencher le
    ///         palier. Sinon on n'aurait pas sécurisé l'oracle, on l'aurait
    ///         cassé.
    function test_Twap_SustainedMoveEventuallyArmsMilestone() public {
        _configure();

        pool.applyPriceChange(UniswapV3TWAP.getSqrtRatioAtTick(PUMP_TICK));
        vm.warp(T0 + 1800); // le nouveau prix a tenu toute la fenêtre TWAP

        assertGe(rmht.getMarketCap(), rmht.nextMilestoneUSD());

        rmht.pokeMilestone();
        assertTrue(rmht.milestoneArmed());
        assertEq(rmht.milestoneConfirmations(), 1);
    }

    // ═══════ 2. Régression : le repli sur fenêtre courte == pas de TWAP ═════

    /// @notice TEST DE RÉGRESSION du bug corrigé le 27/08/2026.
    ///         La première version de getRMHTPriceInETH() plafonnait la
    ///         fenêtre demandée à l'historique disponible :
    ///             window = min(TWAP_WINDOW, oldestAvailable)
    ///         Ce test montre pourquoi c'était inacceptable : sur une pool à
    ///         observationCardinality basse, `oldestAvailable` vaut l'écart
    ///         depuis le dernier swap, donc ~1 s après un pump — et un TWAP
    ///         sur 1 s est, au tick près, LE PRIX SPOT MANIPULÉ.
    ///         Le code actuel refuse cette lecture (cf. test suivant) ; on
    ///         garde celui-ci pour que quiconque envisagerait de « remettre
    ///         le repli pour éviter les reverts » voie noir sur blanc ce
    ///         qu'il réintroduit.
    function test_Regression_ShortWindowTwapEqualsManipulatedSpot() public {
        // Pool jeune : cardinalité 1, une seule observation, écrite au pump.
        MockUniswapV3Pool youngPool =
            new MockUniswapV3Pool(address(rmht), address(0xBEEF), UniswapV3TWAP.getSqrtRatioAtTick(BASE_TICK));
        youngPool.setObservationState(0, 1, 1);

        youngPool.applyPriceChange(UniswapV3TWAP.getSqrtRatioAtTick(PUMP_TICK));
        vm.warp(T0 + 1);
        youngPool.setHistorySeconds(1); // tout l'historique disponible = 1 s

        uint32 available = UniswapV3TWAP.getOldestObservationSecondsAgo(address(youngPool));
        assertEq(available, 1, "la pool jeune n'offre qu'une seconde d'historique");

        // Le « TWAP » calculé sur cette fenêtre raccourcie est EXACTEMENT le
        // tick manipulé — aucune protection, juste un autre nom pour le spot.
        assertEq(UniswapV3TWAP.consult(address(youngPool), available), PUMP_TICK);
    }

    // ═══════════════════ 3. Comportement fail-closed ════════════════════

    function test_FailClosed_PriceRevertsWhenHistoryTooShort() public {
        _configure();
        pool.setHistorySeconds(rmht.TWAP_WINDOW() - 1);

        vm.expectRevert(bytes("RMHT: TWAP history too short"));
        rmht.getRMHTPriceInETH();
    }

    function test_FailClosed_PriceAcceptsExactlyTheFullWindow() public {
        _configure();
        pool.setHistorySeconds(rmht.TWAP_WINDOW());
        assertGt(rmht.getRMHTPriceInETH(), 0);
    }

    /// @notice pokeMilestone() garde son contrat « no-op silencieux » : elle
    ///         ne doit PAS propager le revert de l'oracle, sinon n'importe
    ///         quel appelant qui la compose se retrouverait cassé.
    function test_FailClosed_PokeIsSilentNoOpWhenHistoryTooShort() public {
        _configure();
        pool.setHistorySeconds(rmht.TWAP_WINDOW() - 1);

        rmht.pokeMilestone(); // ne doit pas revert
        assertFalse(rmht.milestoneArmed());
        assertEq(rmht.milestonesReached(), 0);
    }

    function test_IsTwapReady_ReflectsAvailableHistory() public {
        assertFalse(rmht.isTwapReady(), "pool non configuree => pas pret");
        assertEq(rmht.twapHistoryAvailable(), 0);

        _configure();
        assertTrue(rmht.isTwapReady());

        pool.setHistorySeconds(rmht.TWAP_WINDOW() - 1);
        assertFalse(rmht.isTwapReady());
        assertEq(rmht.twapHistoryAvailable(), rmht.TWAP_WINDOW() - 1);

        pool.setHistorySeconds(rmht.TWAP_WINDOW());
        assertTrue(rmht.isTwapReady());
    }

    // ═════════════ 4. Garde-fou de cardinalité dans setConfig ═════════════

    function test_RevertSetConfig_ObservationCardinalityTooLow() public {
        pool.setObservationState(0, 1, rmht.MIN_OBSERVATION_CARDINALITY() - 1);

        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Pool observation cardinality too low"));
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
    }

    /// @notice Le plancher est bien `observationCardinalityNext` (la valeur
    ///         qu'increaseObservationCardinalityNext() fixe immédiatement) et
    ///         PAS `observationCardinality` (qui ne rattrape qu'au fil des
    ///         swaps) — sinon la configuration serait impossible à faire
    ///         passer sur une pool fraîchement dimensionnée.
    function test_SetConfig_AcceptsExactMinimumOnCardinalityNext() public {
        pool.setObservationState(0, 1, rmht.MIN_OBSERVATION_CARDINALITY());

        vm.prank(owner);
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
        assertEq(rmht.uniswapV3Pool(), address(pool));
    }

    /// @notice Justification du dimensionnement : le buffer doit couvrir la
    ///         fenêtre entière MÊME si un attaquant fait tourner le ring
    ///         buffer en swappant à chaque seconde (une pool Uniswap v3
    ///         n'écrit qu'une observation par seconde au maximum). D'où
    ///         TWAP_WINDOW + 1 slots, et pas une valeur symbolique.
    function test_MinCardinality_CoversFullWindowAgainstBufferSpam() public view {
        assertEq(uint256(rmht.MIN_OBSERVATION_CARDINALITY()), uint256(rmht.TWAP_WINDOW()) + 1);
    }

    // ═════════════════ 5. Cohérence avec le reste du calcul ═════════════════

    /// @notice L'aval du calcul de prix (carré, format Q128, inversion
    ///         token0/token1) est inchangé : à tick 0 sur une pool 1:1, on
    ///         retrouve 1e18 dans les DEUX orientations, comme avant le TWAP.
    function test_PriceUnchangedAtParity_BothOrientations() public {
        MockUniswapV3Pool p0 = new MockUniswapV3Pool(address(rmht), address(0xBEEF), uint160(2 ** 96));
        vm.prank(owner);
        rmht.setConfig(address(p0), address(ethUsdFeed), address(sequencerFeed));
        assertTrue(rmht.poolIsToken0());
        assertEq(rmht.getRMHTPriceInETH(), 1e18);

        vm.prank(owner);
        RMHT rmht2 = new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);
        MockUniswapV3Pool p1 = new MockUniswapV3Pool(address(0xBEEF), address(rmht2), uint160(2 ** 96));
        vm.prank(owner);
        rmht2.setConfig(address(p1), address(ethUsdFeed), address(sequencerFeed));
        assertFalse(rmht2.poolIsToken0());
        assertEq(rmht2.getRMHTPriceInETH(), 1e18);
    }

    /// @notice Le check `unlocked` (read-only reentrancy) reste évalué AVANT
    ///         toute lecture de l'oracle — il n'a pas été rendu inutile par
    ///         le TWAP, il en est la défense en profondeur.
    function test_LockedPoolStillRevertsBeforeReadingObservations() public {
        _configure();
        pool.setUnlocked(false);
        vm.expectRevert(bytes("RMHT: Pool locked mid-swap"));
        rmht.getRMHTPriceInETH();
    }
}
