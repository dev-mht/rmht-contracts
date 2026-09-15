
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

// ═══════════════════════════════════════════════════════════════════════════
//  Harness Echidna pour RMHT.sol — v2, enrichi.
//
//  CE QUI A CHANGÉ PAR RAPPORT AU BROUILLON INITIAL :
//  La v1 ne déclarait AUCUNE fonction d'état à fuzzer — seulement 4 fonctions
//  echidna_* en `view`. Résultat : sur toute une campagne (50 000 calls),
//  Echidna n'avait rien à appeler du tout (Gas/s: 0 dans le résumé), et les
//  "4/4 passing" ne vérifiaient que l'état juste après le constructeur, pas
//  un état exploré par fuzzing. Cette v2 corrige ça : elle déploie des mocks
//  (feed ETH/USD, feed séquenceur, pool Uniswap) pour activer la logique de
//  milestone, configure le contrat, fournit 3 acteurs fuzzables, et expose
//  des wrappers qui appellent réellement les fonctions d'état de RMHT.sol.
//
//  Usage (depuis la racine du projet Foundry) :
//    echidna echidna/RMHTEchidnaInvariants.sol --contract RMHTEchidnaInvariants --config echidna/echidna.yaml
// ═══════════════════════════════════════════════════════════════════════════
// MAJ 28/08/2026 : pointe desormais sur LA source, pas sur une copie.
// Il existait ici un echidna/RMHT.sol duplique, fige avant le passage au TWAP
// (1020 lignes contre 1164) — Echidna fuzzait donc une version obsolete du
// contrat pendant que Foundry en testait une autre. Copie supprimee.
import "../src/RMHT.sol";
import {MockAggregatorV3} from "../test/mocks/MockAggregatorV3.sol";
import {MockUniswapV3Pool} from "../test/mocks/MockUniswapV3Pool.sol";

interface IHevm {
    function prank(address) external;
    function warp(uint256) external;
}

contract RMHTEchidnaInvariants {
    IHevm internal constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    RMHT internal rmht;
    MockAggregatorV3 internal ethUsdFeed;
    MockAggregatorV3 internal sequencerFeed;
    MockUniswapV3Pool internal pool;

    address internal constant AIRDROP_WALLET = address(0x1111);
    address internal constant MARKET_WALLET  = address(0x2222);
    address internal constant FOUNDER_WALLET = address(0x3333);
    // AJOUT 28/08/2026 : 7e paramètre du constructeur RMHT (feedGovernor_).
    address internal constant FEED_GOVERNOR  = address(0x4444);
    address internal constant WETH_PLACEHOLDER = address(0x9999);
    // MAJ 22/08/2026 : l'ancien AIRDROP_AMOUNT (68_086_021, snapshot 20 wallets
    // + fondateur) est scindé — la part fondateur (50M) va désormais à un
    // RMHTFounderCustodian dédié, celle-ci ne couvre plus que les 19 wallets
    // communauté (troncature par adresse, aucun arrondi sup.).
    uint256 internal constant AIRDROP_AMOUNT = 18_086_021 * 1e18; // snapshot 19 wallets communauté uniquement
    uint256 internal constant FOUNDER_AMOUNT = 50_000_000 * 1e18; // RMHTFounderCustodian.FOUNDER_ALLOCATION
    uint256 internal constant MARKET_AMOUNT  = 431_913_979 * 1e18; // TOTAL_SUPPLY - VAULT - AIRDROP - FOUNDER

    address[3] internal actors = [address(0xA11CE), address(0xB0B), address(0xC0FFEE)];

    // Ghost state — pour vérifier la monotonie entre deux appels successifs
    // de l'invariant (Echidna ne compare pas nativement deux états sans ça).
    uint256 internal lastVaultBalance;
    uint256 internal lastMilestonesReached;

    constructor() {
        rmht = new RMHT(AIRDROP_WALLET, AIRDROP_AMOUNT, MARKET_WALLET, MARKET_AMOUNT, FOUNDER_WALLET, FOUNDER_AMOUNT, FEED_GOVERNOR);

        // Distribue des soldes de départ aux 3 acteurs fuzzables, depuis les
        // deux wallets qui ont reçu le mint initial. _update() n'applique
        // plus aucune restriction de type verrou-lancement/anti-sandwich
        // (retirés de RMHT.sol le 14/08/2026) — transferts toujours libres.
        hevm.prank(AIRDROP_WALLET);
        rmht.transfer(actors[0], 1_000_000 * 1e18);
        hevm.prank(AIRDROP_WALLET);
        rmht.transfer(actors[1], 1_000_000 * 1e18);
        hevm.prank(MARKET_WALLET);
        rmht.transfer(actors[2], 1_000_000 * 1e18);

        // Mocks — pour activer getMarketCap()/pokeMilestone(), inertes dans
        // le brouillon v1 faute de config.
        ethUsdFeed     = new MockAggregatorV3(8);
        sequencerFeed  = new MockAggregatorV3(0);
        pool           = new MockUniswapV3Pool(address(rmht), WETH_PLACEHOLDER, uint160(2 ** 96)); // ratio 1:1 de départ

        // Offsets figés une fois pour toutes (voir commentaire "autoFresh"
        // dans MockAggregatorV3) — restent valides quel que soit le warp
        // ultérieur, pas besoin de rafraîchir à chaque appel.
        ethUsdFeed.setRoundData(3_000 * 1e8, block.timestamp, block.timestamp);           // ETH/USD = $3000, toujours "frais"
        sequencerFeed.setRoundData(0, block.timestamp - 2 hours, block.timestamp);        // up, grace period (1h) toujours dépassée

        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
        // (setAutomationRegistry() retiré le 20/08/2026 — palier désormais
        // auto-déclenché via pokeMilestone(), permissionless, plus de
        // dépendance à un registry externe type Chainlink Automation/CRE.)

        // Snapshot initial du ghost state, sur l'état réel post-déploiement
        // (vaultBalance == VAULT_SUPPLY, milestonesReached == 0) — sinon la
        // propriété échouerait dès le premier appel (0 par défaut < vault réel).
        lastVaultBalance      = rmht.vaultBalance();
        lastMilestonesReached = rmht.milestonesReached();
    }

    // ─────────────────────────────────────────────────────────────────────
    //  WRAPPERS FUZZABLES
    // ─────────────────────────────────────────────────────────────────────

    function transferBetweenActors(uint8 fromSeed, uint8 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to   = actors[toSeed % actors.length];
        uint256 bal  = rmht.balanceOf(from);
        if (bal == 0) return;
        amount = amount % (bal + 1);

        hevm.prank(from);
        try rmht.transfer(to, amount) {} catch {}
    }

    function claimFor(uint8 seed) public {
        address who = actors[seed % actors.length];
        if (rmht.pendingRewardsOf(who) == 0) return;

        hevm.prank(who);
        try rmht.claimRewards() {} catch {}
    }

    /// @notice Avance le temps (1h à 49h) puis appelle pokeMilestone() — seule
    ///         façon d'atteindre la logique de milestone/vault release depuis
    ///         le retrait de Chainlink Automation/CRE (20/08/2026). Un seul
    ///         poke par appel : la machine à états interne (armement puis
    ///         MILESTONE_CONFIRMATIONS_REQUIRED confirmations espacées de
    ///         MILESTONE_CONFIRM_INTERVAL, dans la fenêtre
    ///         MILESTONE_CONFIRM_WINDOW) s'accumule naturellement au fil des
    ///         appels successifs de cette fonction par le fuzzer, comme côté
    ///         Foundry (RMHTHandler.warpAndPoke). Le ghost state
    ///         (lastVaultBalance/lastMilestonesReached) est mis à jour ICI,
    ///         juste après l'appel, pas dans une propriété echidna_ séparée,
    ///         car Echidna n'appelle pas les propriétés dans un ordre garanti
    ///         par rapport aux transactions (leçon déjà tirée sur
    ///         RMHTAirdropCustodian).
    function warpAndPokeMilestone(uint256 jump) public {
        hevm.warp(block.timestamp + 1 hours + (jump % 48 hours));
        try rmht.pokeMilestone() {
            lastVaultBalance      = rmht.vaultBalance();
            lastMilestonesReached = rmht.milestonesReached();
        } catch {}
    }

    /// @notice Fait varier le prix ETH/USD du mock ($1 à ~$1M), pour que
    ///         getMarketCap() explore différents ordres de grandeur et que
    ///         les seuils de milestone soient atteignables par le fuzzing.
    function setEthUsdPrice(uint256 raw) public {
        uint256 usd = 1 + (raw % 999_999);
        try ethUsdFeed.setRoundData(int256(usd * 1e8), block.timestamp, block.timestamp) {} catch {}
    }

    /// @notice Fait varier le prix spot de la pool mockée, même objectif que
    ///         ci-dessus côté jambe Uniswap du calcul de market cap.
    function setPoolPrice(uint256 raw) public {
        uint160 sqrtPriceX96 = uint160(1 + (raw % (type(uint160).max - 1)));
        pool.setSqrtPriceX96(sqrtPriceX96);
    }

    function excludeToggle(uint8 seed, bool status) public {
        address who = actors[seed % actors.length];
        try rmht.excludeFromRewards(who, status) {} catch {}
    }

    // (delayLaunchWrapper retiré le 14/08/2026 — launchTime/delayLaunch
    // n'existent plus dans RMHT.sol, verrou de lancement supprimé)

    // ─────────────────────────────────────────────────────────────────────
    //  INVARIANTS
    // ─────────────────────────────────────────────────────────────────────

    function echidna_total_supply_constant() public view returns (bool) {
        return rmht.totalSupply() == rmht.TOTAL_SUPPLY();
    }

    function echidna_vault_never_exceeds_initial() public view returns (bool) {
        return rmht.vaultBalance() <= rmht.VAULT_SUPPLY();
    }

    function echidna_contract_balance_covers_vault() public view returns (bool) {
        return rmht.balanceOf(address(rmht)) >= rmht.vaultBalance();
    }

    function echidna_next_milestone_monotonic() public view returns (bool) {
        return rmht.nextMilestoneUSD() >= rmht.MILESTONE_STEP_USD();
    }

    /// @notice Le vault ne doit jamais RE-augmenter d'un appel à l'autre, et
    ///         milestonesReached ne doit jamais redescendre. Propriété
    ///         purement view : ne fait que comparer l'état actuel au dernier
    ///         snapshot ghost pris dans warpAndCheckUpkeep — aucune mutation
    ///         ici, pour rester déterministe peu importe l'ordre d'appel.
    function echidna_milestone_progress_consistent() public view returns (bool) {
        return rmht.vaultBalance() <= lastVaultBalance
            && rmht.milestonesReached() >= lastMilestonesReached;
    }
}

