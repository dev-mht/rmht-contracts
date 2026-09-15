// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../src/RMHT.sol";
import "./mocks/MockAggregatorV3.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MaliciousReentrantOwner.sol";
import "./mocks/MockSimpleToken.sol";

/// @notice Contrat sans receive()/fallback() — utilisé pour tester la branche
///         "RMHT: ETH transfer failed" de rescueTokens() (envoi bas niveau qui
///         échoue parce que le destinataire ne peut pas recevoir d'ETH).
contract NonPayableReceiver {}

contract RMHTTest is Test {
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
    address holder1 = address(0x1111);
    address holder2 = address(0x2222);

    uint256 constant VAULT = 500_000_000 ether;
    uint256 constant AIRDROP = 65_000_000 ether;
    uint256 constant FOUNDER = 50_000_000 ether;
    uint256 constant MARKET = 385_000_000 ether; // 500M - AIRDROP - FOUNDER

    function setUp() public {
        vm.warp(1_700_000_000); // timestamp réaliste, évite l'underflow des soustractions d'heures

        vm.prank(owner);
        rmht = new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);

        ethUsdFeed = new MockAggregatorV3(8);
        sequencerFeed = new MockAggregatorV3(0);

        // Pool où RMHT est token0, sqrtPriceX96 = 2^96 <=> prix 1:1 avec WETH
        pool = new MockUniswapV3Pool(address(rmht), address(0xBEEF), uint160(2 ** 96));

        // Séquenceur "up" depuis longtemps (status = 0, startedAt loin dans le passé)
        sequencerFeed.setRoundData(0, block.timestamp - 2 hours, block.timestamp);
        // ETH/USD = 3000$ avec 8 décimales
        ethUsdFeed.setRoundData(3000 * 1e8, block.timestamp, block.timestamp);
    }

    function _configurePool() internal {
        vm.prank(owner);
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
    }

    function _fullyConfigureAndUnlock() internal {
        _configurePool();
        vm.startPrank(owner);
        rmht.lockConfig();
        vm.stopPrank();
    }

    /// @notice Fait passer le palier armé → confirmé, en simulant les
    ///         MILESTONE_CONFIRMATIONS_REQUIRED confirmations requises,
    ///         chacune espacée d'au moins MILESTONE_CONFIRM_INTERVAL.
    ///         Le premier pokeMilestone() arme ET compte comme confirmation
    ///         #1 ; il faut donc (required - 1) pokes supplémentaires.
    function _reachMilestone() internal {
        rmht.pokeMilestone(); // armement = confirmation #1
        uint8 required = rmht.MILESTONE_CONFIRMATIONS_REQUIRED();
        for (uint8 i = 1; i < required; i++) {
            vm.warp(block.timestamp + rmht.MILESTONE_CONFIRM_INTERVAL() + 1);
            rmht.pokeMilestone();
        }
    }

    // ───────────────────────── Constructor ─────────────────────────

    function test_RevertConstructor_BadAllocationSum() public {
        vm.expectRevert(bytes("RMHT: Allocation must sum to TOTAL_SUPPLY"));
        new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET - 1, founderWallet, FOUNDER, feedGovernor);
    }

    function test_RevertConstructor_ZeroAirdropWallet() public {
        vm.expectRevert(bytes("RMHT: Invalid airdrop wallet"));
        new RMHT(address(0), AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);
    }

    function test_RevertConstructor_ZeroMarketWallet() public {
        vm.expectRevert(bytes("RMHT: Invalid market wallet"));
        new RMHT(airdropWallet, AIRDROP, address(0), MARKET, founderWallet, FOUNDER, feedGovernor);
    }

    function test_RevertConstructor_ZeroFounderWallet() public {
        vm.expectRevert(bytes("RMHT: Invalid founder wallet"));
        new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, address(0), FOUNDER, feedGovernor);
    }

    function test_Constructor_MintsCorrectAllocations() public view {
        assertEq(rmht.totalSupply(), 1_000_000_000 ether);
        assertEq(rmht.balanceOf(address(rmht)), VAULT);
        assertEq(rmht.balanceOf(airdropWallet), AIRDROP);
        assertEq(rmht.balanceOf(marketWallet), MARKET);
        assertEq(rmht.balanceOf(founderWallet), FOUNDER);
        assertEq(rmht.vaultBalance(), VAULT);
    }

    function test_Constructor_DefaultExclusions() public view {
        assertTrue(rmht.isExcludedFromRewards(address(rmht)));
        assertTrue(rmht.isExcludedFromRewards(rmht.BURN_ADDRESS()));
        assertTrue(rmht.isExcludedFromRewards(marketWallet));
        assertFalse(rmht.isExcludedFromRewards(airdropWallet));
        // founderWallet (RMHTFounderCustodian) suit la même logique qu'airdropWallet
        // depuis le 22/08/2026 : hodler long terme, PAS exclu des rewards de palier.
        assertFalse(rmht.isExcludedFromRewards(founderWallet));
    }

    // ───────────────────────── setConfig / lockConfig / renounce ─────────────────────────

    function test_SetConfig_OnlyOwner() public {
        vm.expectRevert();
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
    }

    function test_SetConfig_DetectsPoolIsToken0() public {
        _configurePool();
        assertTrue(rmht.poolIsToken0());
        assertTrue(rmht.isExcludedFromRewards(address(pool)));
    }

    function test_RevertSetConfig_AfterLocked() public {
        _configurePool();
        vm.startPrank(owner);
        rmht.lockConfig();
        vm.expectRevert(bytes("RMHT: Config already locked"));
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
        vm.stopPrank();
    }

    /// @dev NOUVEAU — les 3 checks zero-address de setConfig() n'étaient
    ///      jamais déclenchés.
    function test_RevertSetConfig_ZeroPool() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Invalid pool"));
        rmht.setConfig(address(0), address(ethUsdFeed), address(sequencerFeed));
    }

    function test_RevertSetConfig_ZeroEthUsdFeed() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Invalid ETH/USD feed"));
        rmht.setConfig(address(pool), address(0), address(sequencerFeed));
    }

    /// @dev 29/08/2026 — INVERSION ASSUMÉE de l'ancien
    ///      test_RevertSetConfig_ZeroSequencerFeed. address(0) est désormais
    ///      une valeur VALIDE pour le feed séquenceur et signifie "check
    ///      désactivé" : Chainlink n'a jamais publié de L2 Sequencer Uptime
    ///      Feed pour Robinhood Chain et a annoncé ne plus en déployer sur de
    ///      nouveaux réseaux. Exiger un feed aurait gelé tous les paliers.
    function test_SetConfig_ZeroSequencerFeedIsAllowed() public {
        vm.prank(owner);
        rmht.setConfig(address(pool), address(ethUsdFeed), address(0));

        assertEq(address(rmht.sequencerUptimeFeed()), address(0));
        assertEq(address(rmht.ethUsdFeed()), address(ethUsdFeed));
        assertEq(rmht.uniswapV3Pool(), address(pool));

        // Et la lecture de prix fonctionne : c'est tout l'objet du changement.
        (uint256 price, ) = rmht.getETHPriceUSD();
        assertGt(price, 0);
    }

    function test_RevertLockConfig_BeforePoolSet() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Set config first"));
        rmht.lockConfig();
    }

    function test_RevertRenounce_BeforeConfigLocked() public {
        _configurePool();
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Lock config first"));
        rmht.renounceOwnership();
    }

    function test_Renounce_SucceedsWhenFullyConfigured() public {
        _fullyConfigureAndUnlock();
        vm.prank(owner);
        rmht.renounceOwnership();
        assertEq(rmht.owner(), address(0));
    }

    // ───────────────────────── Ownership : transfer en 2 temps (NOUVEAU) ─────────────────────────
    // transferOwnership()/acceptOwnership() n'étaient jusqu'ici JAMAIS
    // réellement exercés — voir la correction de
    // test_RescueTokens_ETH_ReentrancyGuardBlocksReentry plus bas, qui
    // dépendait silencieusement de ce trou.

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        rmht.transferOwnership(holder1);
    }

    function test_TransferOwnership_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        rmht.transferOwnership(address(0));
    }

    function test_TransferOwnership_SetsPendingOwner() public {
        vm.prank(owner);
        rmht.transferOwnership(holder1);

        // L'ownership ne change PAS tant que acceptOwnership() n'a pas été appelé.
        assertEq(rmht.owner(), owner);
        assertEq(rmht.pendingOwner(), holder1);
    }

    function test_AcceptOwnership_RevertsIfNotPending() public {
        vm.prank(owner);
        rmht.transferOwnership(holder1);

        vm.prank(holder2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder2));
        rmht.acceptOwnership();
    }

    function test_AcceptOwnership_Success() public {
        vm.prank(owner);
        rmht.transferOwnership(holder1);

        vm.prank(holder1);
        rmht.acceptOwnership();

        assertEq(rmht.owner(), holder1);
        assertEq(rmht.pendingOwner(), address(0));

        // L'ancien owner a bien perdu tout pouvoir onlyOwner.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        rmht.excludeFromRewards(holder2, true);
    }

    // ───────────────────────── Prix / MCap ─────────────────────────

    function test_GetRMHTPriceInETH_OneToOne() public {
        _configurePool();
        assertEq(rmht.getRMHTPriceInETH(), 1e18);
    }

    function test_RevertPrice_SequencerDown() public {
        _configurePool();
        sequencerFeed.setRoundData(1, block.timestamp, block.timestamp); // status != 0 = down
        vm.expectRevert(bytes("RMHT: Sequencer down"));
        rmht.getETHPriceUSD();
    }

    function test_RevertPrice_GracePeriodNotOver() public {
        _configurePool();
        sequencerFeed.setRoundData(0, block.timestamp, block.timestamp); // vient de remonter à l'instant
        vm.expectRevert(bytes("RMHT: Grace period not over"));
        rmht.getETHPriceUSD();
    }

    function test_GetMarketCap_Computation() public {
        _configurePool();
        uint256 mcap = rmht.getMarketCap();
        assertGt(mcap, 0);
    }

    /// @dev NOUVEAU — require(answeredInRound >= roundId) côté séquenceur
    ///      n'était jamais atteint : le mock renvoyait toujours
    ///      answeredInRound == roundId par défaut.
    function test_RevertPrice_StaleSequencerRound() public {
        _configurePool();
        sequencerFeed.setForceStaleRound(true);
        vm.expectRevert(bytes("RMHT: Stale sequencer round"));
        rmht.getETHPriceUSD();
    }

    /// @dev NOUVEAU — même check côté feed ETH/USD.
    function test_RevertPrice_StalePriceRound() public {
        _configurePool();
        ethUsdFeed.setForceStaleRound(true);
        vm.expectRevert(bytes("RMHT: Stale price round"));
        rmht.getETHPriceUSD();
    }

    /// @dev NOUVEAU — require(answer > 0) jamais déclenché.
    function test_RevertPrice_InvalidETHPrice() public {
        _configurePool();
        ethUsdFeed.setRoundData(0, block.timestamp, block.timestamp);
        vm.expectRevert(bytes("RMHT: Invalid ETH price"));
        rmht.getETHPriceUSD();
    }

    /// @dev NOUVEAU — require(updatedAt != 0). Le mock ne renvoie 0 que si
    ///      on fixe updatedAt=0 ET qu'on lit dans le même bloc (l'offset
    ///      recalculé donne alors exactement 0).
    function test_RevertPrice_RoundNotComplete() public {
        _configurePool();
        ethUsdFeed.setRoundData(3000 * 1e8, block.timestamp, 0);
        vm.expectRevert(bytes("RMHT: Round not complete"));
        rmht.getETHPriceUSD();
    }

    /// @dev NOUVEAU — require(block.timestamp - updatedAt <= HEARTBEAT).
    ///      Le mock rejoue un écart CONSTANT (fixé à l'appel de
    ///      setRoundData) sur block.timestamp, donc il suffit de fixer un
    ///      écart initial supérieur au heartbeat, pas besoin de warp.
    /// @dev MàJ 28/08/2026 : le test warpait de 2 heures en dur, ce qui ne
    ///      dépasse plus ETH_USD_HEARTBEAT depuis son passage de 1 h à 26 h
    ///      (heartbeat réel du feed ETH/USD de Robinhood Chain Mainnet :
    ///      86 400 s). Il lit désormais la constante au lieu de la
    ///      re-supposer — il restera juste si elle bouge encore.
    function test_RevertPrice_ETHFeedStale() public {
        _configurePool();
        uint256 tooOld = rmht.ETH_USD_HEARTBEAT() + 1;
        ethUsdFeed.setRoundData(3000 * 1e8, block.timestamp - tooOld, block.timestamp - tooOld);
        vm.expectRevert(bytes("RMHT: ETH price feed stale"));
        rmht.getETHPriceUSD();
    }

    /// @dev L'autre bord du même seuil : un prix vieux de EXACTEMENT
    ///      ETH_USD_HEARTBEAT doit encore passer (le require est un `<=`).
    ///      C'est ce test qui aurait attrape le vrai probleme : avec
    ///      l'ancienne valeur de 1 h et le heartbeat reel de 24 h du feed
    ///      mainnet, getETHPriceUSD() reverait en permanence et aucun palier
    ///      n'aurait jamais pu se declencher.
    function test_GetETHPrice_AtExactlyHeartbeatStillValid() public {
        _configurePool();
        uint256 atLimit = rmht.ETH_USD_HEARTBEAT();
        ethUsdFeed.setRoundData(3000 * 1e8, block.timestamp - atLimit, block.timestamp - atLimit);

        (uint256 price, uint8 dec) = rmht.getETHPriceUSD();
        assertEq(price, 3000 * 1e8);
        assertEq(dec, 8);
    }

    /// @dev Non-regression sur le cas reellement observe le 28/08/2026 sur le
    ///      feed mainnet : dernier round vieux d'environ 1 h 40. Avec
    ///      ETH_USD_HEARTBEAT = 1 hours, cet appel revertait ; il doit passer.
    function test_GetETHPrice_RealMainnetFreshnessObserved() public {
        _configurePool();
        ethUsdFeed.setRoundData(2501 * 1e8, block.timestamp - 100 minutes, block.timestamp - 100 minutes);

        (uint256 price, ) = rmht.getETHPriceUSD();
        assertEq(price, 2501 * 1e8);
    }

    /// @dev NOUVEAU — require(uniswapV3Pool != address(0)) jamais déclenché.
    function test_RevertPrice_PoolNotSet() public {
        vm.expectRevert(bytes("RMHT: Pool not set"));
        rmht.getRMHTPriceInETH();
    }

    /// @dev NOUVEAU — require(unlocked) jamais déclenché (pool mid-swap).
    function test_RevertPrice_PoolLockedMidSwap() public {
        _configurePool();
        pool.setUnlocked(false);
        vm.expectRevert(bytes("RMHT: Pool locked mid-swap"));
        rmht.getRMHTPriceInETH();
    }

    /// @dev NOUVEAU — branche poolIsToken0 == false jamais exercée (le pool
    ///      par défaut du setUp a toujours RMHT comme token0). Prix 1:1
    ///      symétrique, donc même résultat attendu (1e18) pour vérifier
    ///      l'inversion de ratio plutôt qu'une coïncidence de calcul.
    function test_GetRMHTPriceInETH_Token1Orientation() public {
        MockUniswapV3Pool reversedPool = new MockUniswapV3Pool(address(0xBEEF), address(rmht), uint160(2 ** 96));
        vm.prank(owner);
        rmht.setConfig(address(reversedPool), address(ethUsdFeed), address(sequencerFeed));

        assertFalse(rmht.poolIsToken0());
        assertEq(rmht.getRMHTPriceInETH(), 1e18);
    }

    /// @dev RÉÉCRIT 27/08/2026 (passage au TWAP). Ce test attendait
    ///      auparavant le revert "RMHT: Invalid pool price" en injectant un
    ///      sqrtPriceX96 spot égal à 0. Ce n'est PLUS atteignable : la source
    ///      de sqrtPriceX96 n'est plus slot0() mais
    ///      UniswapV3TWAP.getSqrtRatioAtTick(meanTick), qui est bornée par
    ///      construction à MIN_SQRT_RATIO (4295128739) — jamais 0. Le
    ///      `require(ratioX128 != 0)` de getRMHTPriceInETH() devient donc du
    ///      code défensif STRUCTURELLEMENT MORT (il apparaîtra comme branche
    ///      non couverte dans lcov — c'est attendu, pas un trou de test).
    ///
    ///      Ce test vérifie désormais ce qui est réellement vrai : même au
    ///      tick minimal absolu, l'orientation token1 produit un prix fini,
    ///      non nul, sans revert ni division par zéro.
    function test_MinTickPrice_Token1Orientation_NeverDividesByZero() public {
        MockUniswapV3Pool zeroPricePool = new MockUniswapV3Pool(address(0xBEEF), address(rmht), 0);
        vm.prank(owner);
        rmht.setConfig(address(zeroPricePool), address(ethUsdFeed), address(sequencerFeed));

        assertFalse(rmht.poolIsToken0());
        // Le mock clampe un sqrtPriceX96 nul au tick minimal ; le TWAP le
        // reconvertit en MIN_SQRT_RATIO, donc ratioX128 >= 1.
        uint256 price = rmht.getRMHTPriceInETH();
        assertGt(price, 0);
    }

    // ───────────────────────── pokeMilestone ─────────────────────────

    function test_PokeMilestone_NoOpIfPoolNotSet() public {
        rmht.pokeMilestone();
        assertFalse(rmht.milestoneArmed());
    }

    function test_PokeMilestone_ArmsWhenThresholdReached() public {
        _fullyConfigureAndUnlock();
        rmht.pokeMilestone();
        assertTrue(rmht.milestoneArmed());
        assertEq(rmht.milestoneConfirmations(), 1); // l'armement vaut confirmation #1
        assertEq(rmht.milestoneArmedAt(), block.timestamp);
    }

    /// @dev NOUVEAU — branche IDLE avec mcap < nextMilestoneUSD (le seuil
    ///      n'est jamais franchi) : le if-armement ne doit pas s'exécuter.
    ///      Prix effondré artificiellement (même facteur que le test de
    ///      désarmement existant) AVANT le tout premier poke.
    function test_PokeMilestone_NoOpIfBelowThreshold() public {
        _fullyConfigureAndUnlock();
        pool.setSqrtPriceX96(uint160(2 ** 96) / 100_000);

        rmht.pokeMilestone();

        assertFalse(rmht.milestoneArmed());
        assertEq(rmht.milestonesReached(), 0);
    }

    /// @dev NOUVEAU — check `!unlocked` DIRECTEMENT dans _pokeMilestone
    ///      (distinct du même check dans getRMHTPriceInETH() : ici on
    ///      prouve le no-op silencieux, pas un revert).
    function test_PokeMilestone_NoOpIfPoolLockedMidSwap() public {
        _fullyConfigureAndUnlock();
        pool.setUnlocked(false);

        rmht.pokeMilestone();

        assertFalse(rmht.milestoneArmed());
    }

    function test_PokeMilestone_NoOpIfTooSoonSinceLastConfirmation() public {
        _fullyConfigureAndUnlock();
        rmht.pokeMilestone(); // armement = confirmation #1
        rmht.pokeMilestone(); // même bloc, écart minimum pas écoulé → rien ne se passe
        assertEq(rmht.milestoneConfirmations(), 1);
        assertEq(rmht.milestonesReached(), 0);
    }

    function test_PokeMilestone_RequiresAllConfirmationsBeforeExecuting() public {
        _fullyConfigureAndUnlock();
        uint8 required = rmht.MILESTONE_CONFIRMATIONS_REQUIRED();
        rmht.pokeMilestone(); // confirmation #1 (armement)

        // Toutes les confirmations sauf la dernière : le palier ne doit
        // toujours pas être exécuté.
        for (uint8 i = 1; i < required - 1; i++) {
            vm.warp(block.timestamp + rmht.MILESTONE_CONFIRM_INTERVAL() + 1);
            rmht.pokeMilestone();
            assertTrue(rmht.milestoneArmed());
            assertEq(rmht.milestonesReached(), 0);
        }
    }

    function test_PokeMilestone_ReleasesCorrectAmountAndAdvancesMilestone() public {
        _fullyConfigureAndUnlock();

        uint256 vaultBefore = rmht.vaultBalance();
        _reachMilestone();

        uint256 expectedRelease = (vaultBefore * 150) / 10_000; // RELEASE_BPS = 1.5%
        assertEq(rmht.vaultBalance(), vaultBefore - expectedRelease);
        assertEq(rmht.milestonesReached(), 1);
        assertEq(rmht.nextMilestoneUSD(), 500_000 + 500_000);
        assertFalse(rmht.milestoneArmed()); // retour à IDLE après confirmation
        assertEq(rmht.milestoneConfirmations(), 0);
    }

    function test_PokeMilestone_DisarmsIfPriceDropsBeforeConfirmation() public {
        _fullyConfigureAndUnlock();
        rmht.pokeMilestone(); // armement = confirmation #1
        assertTrue(rmht.milestoneArmed());

        // Le prix redescend sous le seuil avant la confirmation suivante.
        // NB: avec un prix 1:1 initial, le mcap de départ est de l'ordre de
        // 1 500 milliards $ (supply en circulation × 3000$/RMHT) — diviser
        // le prix par 4 ne suffit pas à repasser sous le premier palier
        // (500 000$). Il faut une chute bien plus importante.
        pool.setSqrtPriceX96(uint160(2 ** 96) / 100_000);
        vm.warp(block.timestamp + rmht.MILESTONE_CONFIRM_INTERVAL() + 1);
        rmht.pokeMilestone(); // désarmement immédiat, pas d'exécution

        assertFalse(rmht.milestoneArmed());
        assertEq(rmht.milestoneConfirmations(), 0);
        assertEq(rmht.milestonesReached(), 0);
    }

    function test_PokeMilestone_SafetyNet_ExpiresAfterConfirmWindow() public {
        _fullyConfigureAndUnlock();
        rmht.pokeMilestone(); // armement = confirmation #1, prix reste au-dessus du seuil

        // La fenêtre totale s'écoule sans qu'on aille chercher les
        // confirmations restantes → filet de sécurité, désarmement.
        vm.warp(block.timestamp + rmht.MILESTONE_CONFIRM_WINDOW() + 1);
        rmht.pokeMilestone();

        assertFalse(rmht.milestoneArmed());
        assertEq(rmht.milestoneConfirmations(), 0);
        assertEq(rmht.milestonesReached(), 0);
    }

    function test_PokeMilestone_CooldownActive_StaysArmedUntilCooldownClears() public {
        _fullyConfigureAndUnlock();
        _reachMilestone(); // palier 1

        // Palier 2 : re-franchissement immédiat, séquence de confirmations
        // complète, mais cooldown 24h pas écoulé → reste armé.
        _reachMilestone();
        assertTrue(rmht.milestoneArmed());
        assertEq(rmht.milestonesReached(), 1);
    }

    function test_PokeMilestone_WorksAfterCooldown() public {
        _fullyConfigureAndUnlock();
        _reachMilestone();

        vm.warp(block.timestamp + 24 hours + 1);
        _reachMilestone();

        assertEq(rmht.milestonesReached(), 2);
    }

    // ───────────────────────── Rewards ─────────────────────────

    function test_RewardAccrualAndClaim() public {
        _fullyConfigureAndUnlock();

        // Sortir des tokens du marketWallet (exclu) vers deux holders standards
        vm.prank(marketWallet);
        rmht.transfer(holder1, 10_000_000 ether);
        vm.prank(marketWallet);
        rmht.transfer(holder2, 10_000_000 ether);

        _reachMilestone();

        uint256 pending1 = rmht.pendingRewardsOf(holder1);
        uint256 pending2 = rmht.pendingRewardsOf(holder2);
        assertEq(pending1, pending2); // parts égales => reward égal
        assertGt(pending1, 0);

        uint256 balBefore = rmht.balanceOf(holder1);
        vm.prank(holder1);
        rmht.claimRewards();
        assertEq(rmht.balanceOf(holder1), balBefore + pending1);
        assertEq(rmht.pendingRewardsOf(holder1), 0);
    }

    function test_RevertClaim_NoRewards() public {
        vm.prank(holder1);
        vm.expectRevert(bytes("RMHT: No rewards"));
        rmht.claimRewards();
    }

    function test_RevertClaim_Excluded() public {
        vm.prank(owner);
        rmht.excludeFromRewards(holder1, true);

        vm.prank(holder1);
        vm.expectRevert(bytes("RMHT: Excluded from rewards"));
        rmht.claimRewards();
    }

    function test_ExcludeFromRewards_OnlyOwner() public {
        vm.expectRevert();
        rmht.excludeFromRewards(holder1, true);
    }

    /// @dev NOUVEAU — branche isExcludedFromRewards[account] de
    ///      pendingRewardsOf() jamais exercée : marketWallet est exclu par
    ///      défaut, donc pendingRewardsOf() doit retourner 0 même après un
    ///      palier franchi, sans jamais toucher au calcul latent.
    function test_PendingRewardsOf_ReturnsZeroForExcludedAccount() public {
        _reachMilestone();
        assertEq(rmht.pendingRewardsOf(marketWallet), 0);
    }

    /// @dev NOUVEAU — require(addr != address(0)) jamais déclenché.
    function test_RevertExclude_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Zero address"));
        rmht.excludeFromRewards(address(0), true);
    }

    /// @dev NOUVEAU — require(isExcludedFromRewards[addr] != status) jamais
    ///      déclenché (holder1 n'est pas exclu par défaut, statut inchangé
    ///      si on repasse false → false).
    function test_RevertExclude_StatusUnchanged() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Status unchanged"));
        rmht.excludeFromRewards(holder1, false);
    }

    /// @dev NOUVEAU — branche status == false (ré-inclusion) jamais exercée.
    ///      Vérifie que userRewardPerTokenPaid est resynchronisé sur le taux
    ///      courant pour éviter de créditer rétroactivement les rewards
    ///      accumulés pendant l'exclusion.
    function test_ExcludeFromRewards_ReincludeResyncsSnapshot() public {
        vm.prank(marketWallet);
        rmht.transfer(holder1, 10_000_000 ether);

        vm.prank(owner);
        rmht.excludeFromRewards(holder1, true);

        _fullyConfigureAndUnlock();
        _reachMilestone(); // un palier passe pendant que holder1 est exclu

        vm.prank(owner);
        rmht.excludeFromRewards(holder1, false);

        // Aucun reward rétroactif crédité pour le palier manqué pendant l'exclusion.
        assertEq(rmht.pendingRewardsOf(holder1), 0);
        assertFalse(rmht.isExcludedFromRewards(holder1));
    }

    function test_RevertExclude_CannotModifyContractOrBurn() public {
        address burnAddr = rmht.BURN_ADDRESS();

        vm.startPrank(owner);
        vm.expectRevert(bytes("RMHT: Cannot modify contract exclusion"));
        rmht.excludeFromRewards(address(rmht), false);

        vm.expectRevert(bytes("RMHT: Cannot modify burn exclusion"));
        rmht.excludeFromRewards(burnAddr, false);
        vm.stopPrank();
    }

    // ───────────────────────── rescueTokens : jamais le vault ─────────────────────────

    function test_RescueTokens_CannotTouchVault() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Cannot withdraw tracked RMHT"));
        rmht.rescueTokens(address(rmht), 1);
    }

    function test_RescueTokens_CanWithdrawExcessSelfBalance() public {
        // RMHT envoyés par erreur au contrat lui-même, au-delà du vault
        vm.prank(marketWallet);
        rmht.transfer(address(rmht), 1_000 ether);

        vm.prank(owner);
        rmht.rescueTokens(address(rmht), 1_000 ether);
        assertEq(rmht.balanceOf(owner), 1_000 ether);
    }

    function test_RescueTokens_OnlyOwner() public {
        vm.expectRevert();
        rmht.rescueTokens(address(rmht), 0);
    }

    /// @notice Régression : un palier atteint libère des rewards (vaultBalance
    ///         baisse) mais ne transfère RIEN tant que personne n'a appelé
    ///         claimRewards() — ces tokens restent physiquement sur le contrat.
    ///         Avant fix, rescueTokens() les traitait comme un "excédent"
    ///         rescuable par l'owner alors qu'ils sont dus aux holders.
    function test_RescueTokens_CannotTouchUnclaimedReleasedRewards() public {
        _fullyConfigureAndUnlock();
        _reachMilestone();

        uint256 released = VAULT - rmht.vaultBalance();
        assertGt(released, 0);

        // Personne n'a encore claim : tout le "released" est encore sur le
        // contrat et doit rester intouchable par rescueTokens().
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Cannot withdraw tracked RMHT"));
        rmht.rescueTokens(address(rmht), released);
    }

    /// @notice Une fois les rewards effectivement réclamés (claimRewards),
    ///         unclaimedReleased redescend d'autant : rescueTokens() peut à
    ///         nouveau considérer ce montant comme normalement absent du
    ///         solde du contrat (il est parti chez le holder), sans ouvrir
    ///         de brèche sur les rewards encore en attente des autres holders.
    function test_RescueTokens_UnclaimedReleasedDecreasesAfterClaim() public {
        _fullyConfigureAndUnlock();

        vm.prank(marketWallet);
        rmht.transfer(holder1, 100_000_000 ether); // holder1 devient éligible aux rewards

        _reachMilestone();
        uint256 releasedBefore = rmht.unclaimedReleased();
        assertGt(releasedBefore, 0);

        vm.prank(holder1);
        rmht.claimRewards();

        uint256 claimed = rmht.pendingRewardsOf(holder1); // 0 après claim, juste pour lisibilité
        assertEq(claimed, 0);
        assertLt(rmht.unclaimedReleased(), releasedBefore);
    }

    // ───────────────────────── rescueTokens : branche ETH (NOUVEAU) ─────────────────────────

    function test_RescueTokens_ETH_Success() public {
        vm.deal(address(this), 10 ether);
        (bool sent,) = address(rmht).call{value: 2 ether}("");
        require(sent, "setup: funding failed");

        uint256 ownerBalBefore = owner.balance;
        vm.prank(owner);
        rmht.rescueTokens(address(0), 2 ether);
        assertEq(owner.balance, ownerBalBefore + 2 ether);
    }

    /// @dev NOUVEAU — require(amount <= address(this).balance) jamais déclenché.
    function test_RevertRescueTokens_ETH_InsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Insufficient ETH"));
        rmht.rescueTokens(address(0), 1 ether);
    }

    /// @dev NOUVEAU — require(sent) jamais déclenché pour la VRAIE raison
    ///      (destinataire qui refuse l'ETH), par opposition au test de
    ///      reentrancy ci-dessous qui échoue pour une autre raison interne.
    function test_RevertRescueTokens_ETH_TransferFailed() public {
        NonPayableReceiver badRecipient = new NonPayableReceiver();

        vm.prank(owner);
        rmht.transferOwnership(address(badRecipient));
        vm.prank(address(badRecipient));
        rmht.acceptOwnership();

        vm.deal(address(this), 10 ether);
        (bool sent,) = address(rmht).call{value: 2 ether}("");
        require(sent, "setup: funding failed");

        vm.prank(address(badRecipient));
        vm.expectRevert(bytes("RMHT: ETH transfer failed"));
        rmht.rescueTokens(address(0), 1 ether);
    }

    // ───────────────────────── rescueTokens : branche token externe (NOUVEAU) ─────────────────────────

    function test_RevertRescueTokens_Token_NotAContract() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Not a contract"));
        rmht.rescueTokens(holder1, 1); // holder1 est un EOA, pas un contrat
    }

    function test_RevertRescueTokens_Token_TransferFailed() public {
        MockSimpleToken badToken = new MockSimpleToken(address(rmht), 1_000 ether);
        badToken.setTransfersSucceed(false);

        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Token transfer failed"));
        rmht.rescueTokens(address(badToken), 500 ether);
    }

    function test_RescueTokens_Token_Success() public {
        MockSimpleToken foreignToken = new MockSimpleToken(address(rmht), 1_000 ether);

        vm.prank(owner);
        rmht.rescueTokens(address(foreignToken), 500 ether);

        assertEq(foreignToken.balanceOf(owner), 500 ether);
    }

    // ───────────────────────── Reentrancy ─────────────────────────
    // rescueTokens() est le seul endroit du contrat qui envoie de l'ETH via un
    // appel bas niveau (.call). On vérifie ici que le ReentrancyGuard bloque
    // bien toute tentative de ré-entrance pendant cet envoi.

    /// @dev CORRIGÉ 24/08/2026 — ce test ne testait PAS réellement la
    ///      reentrancy : transferOwnership() ne fait que PROPOSER un nouveau
    ///      owner (two-step), acceptOwnership() n'était jamais appelé, donc
    ///      `attacker` n'était jamais réellement owner. attacker.rescue()
    ///      revertait avec OwnableUnauthorizedAccount — une raison totalement
    ///      différente de celle annoncée par le nom du test — et
    ///      vm.expectRevert() générique masquait le problème puisqu'il
    ///      accepte n'importe quel revert.
    ///      Fix : (1) acceptOwnership() explicite pour que l'attacker soit
    ///      VRAIMENT owner ; (2) le mock a aussi été corrigé (try/catch sur
    ///      la tentative de reentrance) — sans ça, le revert interne
    ///      remontait et annulait jusqu'à l'écriture de `reentered = true`,
    ///      rendant impossible de prouver après coup qu'une tentative avait
    ///      eu lieu. Avec le catch, l'appel externe rescueTokens() RÉUSSIT
    ///      (1 ether transféré une seule fois) ET on peut prouver que la
    ///      tentative de double-retrait imbriquée a bien été bloquée par le
    ///      ReentrancyGuard.
    function test_RescueTokens_ETH_ReentrancyGuardBlocksReentry() public {
        MaliciousReentrantOwner attacker = new MaliciousReentrantOwner(rmht);

        vm.prank(owner);
        rmht.transferOwnership(address(attacker));
        vm.prank(address(attacker));
        rmht.acceptOwnership();
        assertEq(rmht.owner(), address(attacker)); // attacker est maintenant VRAIMENT owner

        // Donner de l'ETH au contrat pour qu'il y ait quelque chose à "rescue"
        vm.deal(address(this), 10 ether);
        (bool sent,) = address(rmht).call{value: 2 ether}("");
        require(sent, "setup: funding failed");

        // L'appel externe réussit (le receive() de l'attacker catch le
        // revert de sa propre tentative de reentrance) — c'est justement la
        // preuve à chercher : le guard bloque le RETRAIT IMBRIQUÉ, pas
        // l'opération légitime elle-même.
        vm.prank(address(attacker));
        attacker.rescue(1 ether);

        assertTrue(attacker.reentered(), "l'attacker n'a jamais tente de reentrer");
        assertTrue(attacker.reentrancyReverted(), "la tentative de reentrance n'a pas ete bloquee");
        // Un seul ether est réellement sorti du contrat : la reentrance
        // n'a pas permis de retirer deux fois.
        assertEq(address(rmht).balance, 1 ether);
    }

    // ───────────────────────── Fuzzing ─────────────────────────

    function testFuzz_TransferPreservesTotalSupply(uint256 amount) public {
        amount = bound(amount, 0, MARKET);
        vm.prank(marketWallet);
        rmht.transfer(holder1, amount);
        assertEq(rmht.totalSupply(), 1_000_000_000 ether);
    }

    function testFuzz_TransferNeverExceedsBalance(uint256 amount) public {
        uint256 bal = rmht.balanceOf(marketWallet);
        vm.assume(amount > bal);
        vm.prank(marketWallet);
        vm.expectRevert();
        rmht.transfer(holder1, amount);
    }

    function testFuzz_MultipleMilestones_NeverExceedVault(uint8 rounds) public {
        _fullyConfigureAndUnlock();
        uint256 n = bound(rounds, 1, 20);
        for (uint256 i = 0; i < n; i++) {
            vm.warp(block.timestamp + 25 hours);
            if (rmht.getMarketCap() < rmht.nextMilestoneUSD()) break;

            uint256 before = rmht.vaultBalance();
            uint256 reachedBefore = rmht.milestonesReached();
            _reachMilestone();
            if (rmht.milestonesReached() == reachedBefore) break; // vault vide ou palier non confirmé

            assertLe(rmht.vaultBalance(), before); // ne fait jamais qu'augmenter
            assertLe(rmht.vaultBalance(), VAULT);  // jamais au-dessus du départ
        }
    }

    function testFuzz_RewardsProportionalToBalance(uint256 bal1, uint256 bal2) public {
        bal1 = bound(bal1, 1 ether, 50_000_000 ether);
        bal2 = bound(bal2, 1 ether, 50_000_000 ether);

        vm.prank(marketWallet);
        rmht.transfer(holder1, bal1);
        vm.prank(marketWallet);
        rmht.transfer(holder2, bal2);

        _fullyConfigureAndUnlock();
        _reachMilestone();

        uint256 pending1 = rmht.pendingRewardsOf(holder1);
        uint256 pending2 = rmht.pendingRewardsOf(holder2);

        // Les rewards doivent rester proportionnels aux soldes respectifs
        // (à l'arrondi entier près) : pending1 * bal2 ≈ pending2 * bal1
        assertApproxEqRel(pending1 * bal2, pending2 * bal1, 1e14); // tolérance 0.01%
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  AJOUT 25/08/2026 — fonctions ERC20 de base jamais exercées
    //
    //  Le rapport de couverture (`forge coverage --ir-minimum`) signalait
    //  aussi comme "uncovered" plusieurs lignes DÉJÀ exercées par des tests
    //  existants (ex. super.renounceOwnership() ligne 634, alors que
    //  test_Renounce_SucceedsWhenFullyConfigured() l'appelle avec succès ;
    //  getETHPriceUSD() ligne 655, alors que sept tests l'appellent
    //  directement). C'est un artefact documenté de `--ir-minimum` (le
    //  warning de forge lui-même : "can result in inaccurate source
    //  mappings") — confirmé aussi sur RMHTLiquidityCustodian.sol, dont
    //  CHAQUE branche require() est testée dans les deux sens mais qui
    //  ressort à 0% de couverture de branches. Ces lignes-là ne sont pas
    //  de vrais trous et n'ont pas été ré-adressées ici ; seules les
    //  fonctions confirmées comme JAMAIS appelées nulle part dans test/
    //  (grep sur tout le dossier) sont couvertes ci-dessous.
    // ═══════════════════════════════════════════════════════════════════════

    // ───────────────────────── Metadata ERC20 ─────────────────────────

    function test_Name() public view {
        assertEq(rmht.name(), "Robinhood Milestone HODL Token");
    }

    function test_Symbol() public view {
        assertEq(rmht.symbol(), "RMHT");
    }

    function test_Decimals() public view {
        assertEq(rmht.decimals(), 18);
    }

    // ───────────────────────── approve / allowance ─────────────────────────

    function test_Approve_SetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(marketWallet, holder1, 1000 ether);
        vm.prank(marketWallet);
        assertTrue(rmht.approve(holder1, 1000 ether));
        assertEq(rmht.allowance(marketWallet, holder1), 1000 ether);
    }

    function test_RevertApprove_ZeroSpender() public {
        vm.prank(marketWallet);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        rmht.approve(address(0), 1000 ether);
    }

    function test_Allowance_DefaultsToZero() public view {
        assertEq(rmht.allowance(marketWallet, holder1), 0);
    }

    // ───────────────────────── increaseAllowance / decreaseAllowance ─────────

    function test_IncreaseAllowance() public {
        vm.startPrank(marketWallet);
        rmht.approve(holder1, 100 ether);
        assertTrue(rmht.increaseAllowance(holder1, 50 ether));
        vm.stopPrank();
        assertEq(rmht.allowance(marketWallet, holder1), 150 ether);
    }

    function test_DecreaseAllowance_Success() public {
        vm.startPrank(marketWallet);
        rmht.approve(holder1, 100 ether);
        assertTrue(rmht.decreaseAllowance(holder1, 40 ether));
        vm.stopPrank();
        assertEq(rmht.allowance(marketWallet, holder1), 60 ether);
    }

    function test_RevertDecreaseAllowance_BelowZero() public {
        vm.startPrank(marketWallet);
        rmht.approve(holder1, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder1, 10 ether, 20 ether)
        );
        rmht.decreaseAllowance(holder1, 20 ether);
        vm.stopPrank();
    }

    // ───────────────────────── transferFrom ─────────────────────────

    function test_TransferFrom_Success() public {
        vm.prank(marketWallet);
        rmht.approve(holder1, 500 ether);

        vm.prank(holder1);
        assertTrue(rmht.transferFrom(marketWallet, holder2, 200 ether));

        assertEq(rmht.balanceOf(holder2), 200 ether);
        assertEq(rmht.allowance(marketWallet, holder1), 300 ether);
    }

    function test_TransferFrom_UnlimitedAllowanceNeverDecrements() public {
        vm.prank(marketWallet);
        rmht.approve(holder1, type(uint256).max);

        vm.prank(holder1);
        rmht.transferFrom(marketWallet, holder2, 1_000 ether);

        assertEq(rmht.allowance(marketWallet, holder1), type(uint256).max);
    }

    function test_RevertTransferFrom_InsufficientAllowance() public {
        vm.prank(marketWallet);
        rmht.approve(holder1, 10 ether);

        vm.prank(holder1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder1, 10 ether, 20 ether)
        );
        rmht.transferFrom(marketWallet, holder2, 20 ether);
    }

    // ───────────────────────── View helpers jamais appelés ─────────────────

    function test_MilestoneStatus_BeforeAnyMilestone() public {
        _fullyConfigureAndUnlock();
        (
            bool armed,
            uint8 confirmations,
            uint8 confirmationsRequired,
            uint256 windowExpiresAt,
            uint256 mcapAtArm,
            uint256 currentMcap
        ) = rmht.milestoneStatus();

        assertFalse(armed);
        assertEq(confirmations, 0);
        assertEq(confirmationsRequired, rmht.MILESTONE_CONFIRMATIONS_REQUIRED());
        assertEq(windowExpiresAt, 0);
        assertEq(mcapAtArm, 0);
        assertGt(currentMcap, 0);
    }

    function test_MilestoneStatus_WhileArmed() public {
        _fullyConfigureAndUnlock();
        rmht.pokeMilestone(); // armement = confirmation #1

        (bool armed, uint8 confirmations, , uint256 windowExpiresAt, uint256 mcapAtArm,) = rmht.milestoneStatus();

        assertTrue(armed);
        assertEq(confirmations, 1);
        assertEq(windowExpiresAt, block.timestamp + rmht.MILESTONE_CONFIRM_WINDOW());
        assertGt(mcapAtArm, 0);
    }

    function test_GetCirculatingSupply_ExcludesContractAndBurnBalances() public {
        // Au départ, VAULT_SUPPLY (500M) est déjà détenu par le contrat lui-même
        // (mint fait dans le constructeur) ; rien n'est encore détenu par
        // BURN_ADDRESS : la circulante = TOTAL_SUPPLY - VAULT_SUPPLY.
        assertEq(rmht.getCirculatingSupply(), rmht.TOTAL_SUPPLY() - VAULT);

        // BURN_ADDRESS() résolu AVANT le prank : sinon ce STATICCALL
        // intermédiaire (évalué par Solidity comme argument de transfer())
        // consomme le prank, et transfer() s'exécute avec le mauvais sender.
        address burnAddr = rmht.BURN_ADDRESS();
        vm.prank(marketWallet);
        rmht.transfer(burnAddr, 1_000 ether);

        assertEq(rmht.getCirculatingSupply(), rmht.TOTAL_SUPPLY() - VAULT - 1_000 ether);
    }

    function test_GetEligibleSupply_MatchesInternalHelper() public {
        _configurePool();
        assertEq(
            rmht.getEligibleSupply(),
            rmht.TOTAL_SUPPLY() - rmht.balanceOf(address(rmht)) - rmht.balanceOf(address(pool))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FEED GOVERNOR (AJOUT 28/08/2026)
    //
    //  Ce rôle existe pour UNE raison : pouvoir migrer proprement si Chainlink
    //  change ses feeds, y compris longtemps après renounceOwnership() —
    //  leçon $MHT V2 sur BSC. Les tests ci-dessous couvrent donc les deux
    //  moitiés du contrat implicite :
    //    1. il PEUT corriger les feeds, même config verrouillée et ownership
    //       renoncée (sinon le rôle ne sert à rien) ;
    //    2. il ne peut RIEN d'autre (sinon c'est un owner déguisé).
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Nouveau feed ETH/USD valide (répond aux sanity checks
    ///      d'updatePriceFeeds : decimals() + latestRoundData() avec answer > 0).
    function _freshValidEthUsdFeed() internal returns (MockAggregatorV3 feed) {
        feed = new MockAggregatorV3(8);
        feed.setRoundData(4000 * 1e8, block.timestamp, block.timestamp);
    }

    /// @dev Nouveau feed séquenceur valide : il doit seulement RÉPONDRE
    ///      (convention Chainlink : answer == 0 signifie "up", ce n'est pas
    ///      un prix — aucune contrainte de valeur côté updatePriceFeeds).
    function _freshValidSequencerFeed() internal returns (MockAggregatorV3 feed) {
        feed = new MockAggregatorV3(0);
        feed.setRoundData(0, block.timestamp - 2 hours, block.timestamp);
    }

    function test_Constructor_SetsFeedGovernor() public view {
        assertEq(rmht.feedGovernor(), feedGovernor);
        assertEq(rmht.pendingFeedGovernor(), address(0));
    }

    function test_Constructor_EmitsFeedGovernorTransferredFromZero() public {
        vm.expectEmit(true, true, false, true);
        emit RMHT.FeedGovernorTransferred(address(0), feedGovernor);
        new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);
    }

    function test_RevertConstructor_ZeroFeedGovernor() public {
        vm.expectRevert(bytes("RMHT: Invalid feed governor"));
        new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, address(0));
    }

    function test_UpdatePriceFeeds_SwapsBothFeeds() public {
        _configurePool();
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(newSeq));

        assertEq(address(rmht.ethUsdFeed()), address(newEth));
        assertEq(address(rmht.sequencerUptimeFeed()), address(newSeq));

        // Le nouveau feed est réellement celui qui sert au calcul de prix.
        (uint256 price, uint8 dec) = rmht.getETHPriceUSD();
        assertEq(price, 4000 * 1e8);
        assertEq(dec, 8);
    }

    function test_UpdatePriceFeeds_EmitsEvent() public {
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        vm.expectEmit(true, true, false, true);
        emit RMHT.PriceFeedsUpdated(address(newEth), address(newSeq));
        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(newSeq));
    }

    function test_RevertUpdatePriceFeeds_NotFeedGovernor() public {
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        // Même l'owner ne peut pas : le rôle est entièrement séparé d'Ownable.
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.updatePriceFeeds(address(newEth), address(newSeq));

        vm.prank(holder1);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.updatePriceFeeds(address(newEth), address(newSeq));
    }

    function test_RevertUpdatePriceFeeds_ZeroAddresses() public {
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();

        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: Invalid ETH/USD feed"));
        rmht.updatePriceFeeds(address(0), address(newSeq));

        // 29/08/2026 : address(0) cote sequenceur n'est PLUS un revert —
        // c'est la desactivation explicite du check (voir
        // test_UpdatePriceFeeds_SequencerCanBeDisabledThenReenabled).
        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(0));
        assertEq(address(rmht.sequencerUptimeFeed()), address(0));
    }

    /// @dev Le scénario complet du check optionnel, dans les deux sens :
    ///      désactivation (état de déploiement mainnet), puis activation le
    ///      jour où un feed séquenceur existerait, puis re-désactivation si ce
    ///      feed venait à être déprécié. C'est cette dernière possibilité qui
    ///      évite de rejouer $MHT V2 (oracle cassé = supply gelée à vie).
    function test_UpdatePriceFeeds_SequencerCanBeDisabledThenReenabled() public {
        _configurePool();
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();

        // 1. désactivation : les lectures de prix continuent de fonctionner
        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(0));
        assertEq(address(rmht.sequencerUptimeFeed()), address(0));
        (uint256 p1, ) = rmht.getETHPriceUSD();
        assertGt(p1, 0);

        // 2. activation : le check redevient effectif
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();
        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(newSeq));
        assertEq(address(rmht.sequencerUptimeFeed()), address(newSeq));
        newSeq.setRoundData(1, block.timestamp - 2 hours, block.timestamp); // down
        vm.expectRevert(bytes("RMHT: Sequencer down"));
        rmht.getETHPriceUSD();

        // 3. re-désactivation : la lecture de prix repart malgré un feed KO
        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(0));
        (uint256 p2, ) = rmht.getETHPriceUSD();
        assertGt(p2, 0);
    }

    /// @dev Un feed séquenceur désactivé ne doit rien faire du tout : aucun
    ///      appel externe, donc aucun revert possible depuis
    ///      _requireSequencerUp(). Vérifié via un feed volontairement "down"
    ///      qui n'est simplement plus branché.
    function test_GetETHPrice_WorksWithSequencerCheckDisabled() public {
        _configurePool();
        sequencerFeed.setRoundData(1, block.timestamp, block.timestamp); // down
        vm.expectRevert(bytes("RMHT: Sequencer down"));
        rmht.getETHPriceUSD();

        MockAggregatorV3 sameEth = _freshValidEthUsdFeed();
        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(sameEth), address(0));

        (uint256 price, uint8 dec) = rmht.getETHPriceUSD();
        assertGt(price, 0);
        assertEq(dec, sameEth.decimals());
    }

    /// @dev Le cas d'erreur le plus probable en pratique : une adresse EOA
    ///      collée à la place d'une adresse de contrat.
    function test_RevertUpdatePriceFeeds_NotAContract() public {
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();
        address eoa = address(0xE0A1);

        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: ETH/USD feed not a contract"));
        rmht.updatePriceFeeds(eoa, address(newSeq));

        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: Sequencer feed not a contract"));
        rmht.updatePriceFeeds(address(newEth), eoa);
    }

    /// @dev Sanity check : un contrat qui répond à l'interface mais renvoie un
    ///      prix nul (feed pas encore initialisé) est refusé tout de suite,
    ///      plutôt qu'au prochain pokeMilestone().
    function test_RevertUpdatePriceFeeds_EthUsdSanityCheckFails() public {
        MockAggregatorV3 uninitialized = new MockAggregatorV3(8); // answer == 0
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: ETH/USD feed sanity check failed"));
        rmht.updatePriceFeeds(address(uninitialized), address(newSeq));
    }

    /// @notice LE test qui justifie l'existence du rôle : après lockConfig()
    ///         ET renounceOwnership(), plus personne ne peut toucher à quoi
    ///         que ce soit — sauf feedGovernor, sur les deux feeds.
    function test_UpdatePriceFeeds_WorksAfterLockConfigAndRenounceOwnership() public {
        _fullyConfigureAndUnlock();
        vm.prank(owner);
        rmht.renounceOwnership();
        assertEq(rmht.owner(), address(0));

        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(newSeq));

        assertEq(address(rmht.ethUsdFeed()), address(newEth));
        assertEq(address(rmht.sequencerUptimeFeed()), address(newSeq));
    }

    /// @notice L'autre moitié du contrat implicite : le rôle ne donne AUCUN
    ///         autre pouvoir. La pool reste figée, et toutes les fonctions
    ///         onlyOwner restent hors de portée.
    function test_FeedGovernor_HasNoOtherPower() public {
        _fullyConfigureAndUnlock();
        address poolBefore = rmht.uniswapV3Pool();

        vm.startPrank(feedGovernor);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, feedGovernor));
        rmht.setConfig(address(0xDEAD), address(ethUsdFeed), address(sequencerFeed));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, feedGovernor));
        rmht.rescueTokens(address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, feedGovernor));
        rmht.excludeFromRewards(holder1, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, feedGovernor));
        rmht.renounceOwnership();

        vm.stopPrank();

        assertEq(rmht.uniswapV3Pool(), poolBefore); // pool toujours figée
    }

    /// @dev updatePriceFeeds() ne touche NI la pool NI configLocked.
    function test_UpdatePriceFeeds_DoesNotTouchPoolOrConfigLock() public {
        _fullyConfigureAndUnlock();
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        vm.prank(feedGovernor);
        rmht.updatePriceFeeds(address(newEth), address(newSeq));

        assertEq(rmht.uniswapV3Pool(), address(pool));
        assertTrue(rmht.configLocked());
        assertTrue(rmht.poolIsToken0());
    }

    // ───────────────── transfert du rôle en deux étapes ─────────────────

    function test_TransferFeedGovernor_SetsPendingOnly() public {
        address multisig = address(0x115516);

        vm.expectEmit(true, true, false, true);
        emit RMHT.FeedGovernorTransferStarted(feedGovernor, multisig);
        vm.prank(feedGovernor);
        rmht.transferFeedGovernor(multisig);

        assertEq(rmht.pendingFeedGovernor(), multisig);
        assertEq(rmht.feedGovernor(), feedGovernor); // pas encore transféré
    }

    function test_AcceptFeedGovernor_CompletesTransfer() public {
        address multisig = address(0x115516);
        vm.prank(feedGovernor);
        rmht.transferFeedGovernor(multisig);

        vm.expectEmit(true, true, false, true);
        emit RMHT.FeedGovernorTransferred(feedGovernor, multisig);
        vm.prank(multisig);
        rmht.acceptFeedGovernor();

        assertEq(rmht.feedGovernor(), multisig);
        assertEq(rmht.pendingFeedGovernor(), address(0));

        // L'ancien gouverneur n'a plus aucun pouvoir, le nouveau en a.
        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();
        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.updatePriceFeeds(address(newEth), address(newSeq));

        vm.prank(multisig);
        rmht.updatePriceFeeds(address(newEth), address(newSeq));
        assertEq(address(rmht.ethUsdFeed()), address(newEth));
    }

    function test_RevertTransferFeedGovernor_NotGovernor() public {
        vm.prank(holder1);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.transferFeedGovernor(holder1);
    }

    function test_RevertTransferFeedGovernor_ZeroAddress() public {
        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: Invalid feed governor"));
        rmht.transferFeedGovernor(address(0));
    }

    function test_RevertAcceptFeedGovernor_NotPending() public {
        vm.prank(feedGovernor);
        rmht.transferFeedGovernor(address(0x115516));

        vm.prank(holder1);
        vm.expectRevert(bytes("RMHT: Not pending feed governor"));
        rmht.acceptFeedGovernor();
    }

    function test_RevertAcceptFeedGovernor_NoPendingAtAll() public {
        vm.prank(holder1);
        vm.expectRevert(bytes("RMHT: Not pending feed governor"));
        rmht.acceptFeedGovernor();
    }

    /// @dev Une proposition peut être remplacée tant qu'elle n'est pas
    ///      acceptée — c'est ce qui rattrape une adresse mal collée.
    function test_TransferFeedGovernor_CanBeReplacedBeforeAccept() public {
        address wrong = address(0xBAD1);
        address right = address(0x600D);

        vm.startPrank(feedGovernor);
        rmht.transferFeedGovernor(wrong);
        rmht.transferFeedGovernor(right);
        vm.stopPrank();

        assertEq(rmht.pendingFeedGovernor(), right);

        vm.prank(wrong);
        vm.expectRevert(bytes("RMHT: Not pending feed governor"));
        rmht.acceptFeedGovernor();
    }

    // ───────────────── extinction définitive du rôle ─────────────────

    /// @notice renounceFeedGovernor() ramène le contrat à zéro pouvoir
    ///         résiduel — l'état "100% figé" que la communauté peut vérifier
    ///         on-chain (feedGovernor() == address(0)).
    function test_RenounceFeedGovernor_DisablesTheRoleForever() public {
        vm.expectEmit(true, true, false, true);
        emit RMHT.FeedGovernorTransferred(feedGovernor, address(0));
        vm.prank(feedGovernor);
        rmht.renounceFeedGovernor();

        assertEq(rmht.feedGovernor(), address(0));

        MockAggregatorV3 newEth = _freshValidEthUsdFeed();
        MockAggregatorV3 newSeq = _freshValidSequencerFeed();

        vm.prank(feedGovernor);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.updatePriceFeeds(address(newEth), address(newSeq));

        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.updatePriceFeeds(address(newEth), address(newSeq));
    }

    /// @dev Un transfert commencé mais pas accepté ne doit pas pouvoir
    ///      ressusciter le rôle après une renonciation.
    function test_RenounceFeedGovernor_ClearsPendingGovernor() public {
        address multisig = address(0x115516);
        vm.startPrank(feedGovernor);
        rmht.transferFeedGovernor(multisig);
        rmht.renounceFeedGovernor();
        vm.stopPrank();

        assertEq(rmht.pendingFeedGovernor(), address(0));

        vm.prank(multisig);
        vm.expectRevert(bytes("RMHT: Not pending feed governor"));
        rmht.acceptFeedGovernor();
    }

    function test_RevertRenounceFeedGovernor_NotGovernor() public {
        vm.prank(owner);
        vm.expectRevert(bytes("RMHT: Not feed governor"));
        rmht.renounceFeedGovernor();
    }

    // ───────────────── séquenceur : round pas démarré ─────────────────

    /// @dev FIX 28/08/2026 : `startedAt == 0` signifie "round pas encore
    ///      démarré" côté Chainlink. Avant ce fix, `block.timestamp - 0`
    ///      valait le timestamp courant, donc la vérification de période de
    ///      grâce passait TOUJOURS sur un feed dans cet état — exactement la
    ///      situation qu'elle est censée attraper.
    function test_RevertGetETHPrice_SequencerRoundNotStarted() public {
        _configurePool();
        // startedAt lu à 0 (offset == block.timestamp)
        sequencerFeed.setRoundData(0, 0, block.timestamp);

        vm.expectRevert(bytes("RMHT: Sequencer round not started"));
        rmht.getETHPriceUSD();
    }

    /// @dev Non-régression : un séquenceur normal (démarré il y a longtemps)
    ///      passe toujours.
    function test_GetETHPrice_SequencerStartedLongAgoStillWorks() public {
        _configurePool();
        sequencerFeed.setRoundData(0, block.timestamp - 3 hours, block.timestamp);

        (uint256 price, ) = rmht.getETHPriceUSD();
        assertEq(price, 3000 * 1e8);
    }
}
