// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║                                                                          ║
// ║  RMHTFounderCustodian  —  V1.0 (22/08/2026)                             ║
// ║                                                                          ║
// ║  Détient les 50 000 000 $RMHT alloués au fondateur                      ║
// ║  (`0xb17d555cdbfd7f26e058d8a2dd55edeb60c9e1a1`), sortis de               ║
// ║  RMHTAirdropCustodian.sol le 22/08/2026 pour recevoir une règle de       ║
// ║  déblocage distincte de celle des 19 autres adresses éligibles.         ║
// ║                                                                          ║
// ║  MOTIF : RMHTAirdropCustodian.sol applique depuis le 22/08 un           ║
// ║  déblocage hybride "tout ou rien" — 100% de l'allocation dès que        ║
// ║  RMHT.milestonesReached() atteint 10 (5M$ de market cap) OU 1 an après  ║
// ║  le lancement, premier des deux atteint. `pokeMilestone()` étant        ║
// ║  permissionless côté RMHT.sol, n'importe qui peut faire franchir ce     ║
// ║  palier — un design assumé pour rassurer les investisseurs communauté   ║
// ║  qui ne veulent pas d'un blocage ferme d'un an. Mais appliqué tel quel  ║
// ║  à l'allocation fondateur, ça permettrait un retrait total des 50M      ║
// ║  dès 5M$ de market cap, ce qui a été scanné Critical "Incorrect Access  ║
// ║  Control" par SolidityScan le 22/08 sur RMHTAirdropCustodian.sol — le   ║
// ║  contrôle sur QUAND les fonds deviennent réclamables échappait à        ║
// ║  l'owner dès lors que n'importe qui pouvait pousser le market cap.      ║
// ║                                                                          ║
// ║  DESIGN — REFONTE 27/08/2026 : verrou temporel unique, plus de          ║
// ║  déblocage partiel.                                                     ║
// ║    - AVANT : vesting par tranches de 10M débloquées tous les 10         ║
// ║      paliers de market cap franchis, OU 100% à `unlockTime`.            ║
// ║    - MAINTENANT : 0% jusqu'à `unlockTime`, puis 100%. Aucune tranche,   ║
// ║      aucun lien avec `RMHT.milestonesReached()`.                        ║
// ║                                                                          ║
// ║  POURQUOI (décision produit du 27/08/2026) :                            ║
// ║    - Le déblocage par tranches faisait dépendre le calendrier de        ║
// ║      libération du fondateur d'une fonction PERMISSIONLESS              ║
// ║      (`RMHT.pokeMilestone()`) — n'importe qui pouvait accélérer le      ║
// ║      vesting fondateur en poussant le market cap. C'est exactement le   ║
// ║      motif qui avait valu un Critical "Incorrect Access Control" à      ║
// ║      RMHTAirdropCustodian.sol le 22/08, et que ce contrat était censé   ║
// ║      éviter — il le réintroduisait sous une autre forme.                ║
// ║    - Un verrou d'un an, ferme et sans échappatoire, est aussi le        ║
// ║      signal le plus lisible côté communauté : rien ne sort avant la     ║
// ║      date, quoi qu'il arrive au market cap.                             ║
// ║                                                                          ║
// ║  `unlockTime` EST IMMUTABLE — fixé dans le constructeur, dans la même   ║
// ║  transaction que le déploiement. Il n'existe plus de `setUnlockTime()`. ║
// ║  Conséquences voulues :                                                 ║
// ║    - Aucune étape post-déploiement à oublier. Le déblocage étant        ║
// ║      désormais l'UNIQUE chemin de sortie des 50M, un `setUnlockTime()`  ║
// ║      oublié avant `renounceOwnership()` aurait gelé l'allocation        ║
// ║      définitivement.                                                    ║
// ║    - Personne, owner inclus, ne peut déplacer la date après coup.       ║
// ║    - La date est lisible par n'importe qui sur l'explorer dès le        ║
// ║      premier bloc — pas besoin de faire confiance à l'équipe sur le     ║
// ║      fait qu'elle fixera bien un an.                                    ║
// ║    - En contrepartie : une date erronée n'est corrigeable qu'en         ║
// ║      redéployant le custodian, ce qui n'est possible que TANT QUE       ║
// ║      RMHT.sol n'a pas encore minté les 50M dessus (donc avant le        ║
// ║      lancement).                                                        ║
// ║                                                                          ║
// ║  `claim()` reste appelable plusieurs fois sans risque, mais en          ║
// ║  pratique un seul appel suffit désormais (0 avant la date, 100%         ║
// ║  après) — `claimedAmount` est conservé pour que la comptabilité reste   ║
// ║  explicite et qu'un second appel ne puisse rien retirer de plus.        ║
// ║                                                                          ║
// ║  AJOUT 28/08/2026 — harvestVaultRewards() / claimReward() :             ║
// ║  la version V1.0 ci-dessus omettait volontairement tout mécanisme de    ║
// ║  rapatriement des rewards de palier. Confirmé le 28/08 : le verrou      ║
// ║  d'un an sur les 50M de PRINCIPAL reste inchangé (jour du déploiement   ║
// ║  + 365 jours, immutable, aucune exception) — mais les REWARDS de        ║
// ║  palier doivent être réclamables à tout moment, comme pour n'importe    ║
// ║  quel autre détenteur. Or founderWallet (= l'adresse de CE contrat)     ║
// ║  n'est pas exclu des rewards côté RMHT.sol : le solde bloqué ici en     ║
// ║  accumule bien à chaque palier, mais rien ne permettait de les en       ║
// ║  sortir. Ajout de harvestVaultRewards() (permissionless, rapatrie ce    ║
// ║  que RMHT.sol doit à ce contrat) + claimReward() (bénéficiaire          ║
// ║  uniquement, réclame les rewards déjà rapatriées, à tout moment,        ║
// ║  indépendamment de `claim()` et de `unlockTime`).                       ║
// ║                                                                          ║
// ║  Différence volontaire avec RMHTAirdropCustodian.sol : ici un seul      ║
// ║  bénéficiaire (pas 19), donc pas d'accumulateur reward-per-share — un   ║
// ║  simple compteur cumulatif (totalHarvestedRewards / claimedRewards)     ║
// ║  suffit et reste plus simple à auditer. Aucun impact sur claim(),       ║
// ║  unlockedAmount() ou unlockTime : le principal reste exactement le      ║
// ║  même verrou d'un an, intégral, sans exception.                         ║
// ║                                                                          ║
// ║  Ordre de déploiement : voir RMHTAirdropCustodian.sol (les deux         ║
// ║  custodians sont déployés avant RMHT.sol, dans un ordre indifférent     ║
// ║  entre eux).                                                            ║
// ║                                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

/// @title IERC20
/// @author Ced — Milestone HODL Token
/// @notice Interface ERC20 minimale utilisée par ce contrat.
interface IERC20 {
    /// @notice Transfère `value` jetons vers `to`.
    function transfer(address to, uint256 value) external returns (bool);
    /// @notice Retourne le solde de jetons de `account`.
    function balanceOf(address account) external view returns (uint256);
}

/// @title IRMHTRewards
/// @author Ced — Milestone HODL Token
/// @notice Sous-ensemble de RMHT.sol nécessaire pour rapatrier les rewards de palier.
interface IRMHTRewards {
    /// @notice Transfère à l'appelant les rewards de palier accumulés sur son solde.
    function claimRewards() external;
    /// @notice Rewards de palier accumulés (non encore réclamés) pour `account`.
    /// @dev AJOUT 28/08/2026 : sert à savoir s'il y a quelque chose à récolter
    ///      AVANT d'appeler claimRewards(), qui revert ("RMHT: No rewards")
    ///      quand le montant est nul — voir harvestVaultRewards().
    function pendingRewardsOf(address account) external view returns (uint256);
}

/// @title Context
/// @author Ced — Milestone HODL Token
/// @notice Expose l'appelant du contexte d'exécution courant.
/// @dev Base commune minimale, reprise du style OpenZeppelin.
abstract contract Context {
    /// @notice Retourne l'adresse ayant appelé la fonction courante.
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Ownable2Step — transfert d'ownership en deux étapes (protège contre une
//  adresse mal copiée-collée pendant la phase de setup, avant
//  renounceOwnership()). renounceOwnership() reste immédiat.
// ═══════════════════════════════════════════════════════════════════════════

/// @title Ownable2Step
/// @author Ced — Milestone HODL Token
/// @notice Contrôle d'accès mono-propriétaire avec transfert en deux étapes.
/// @dev Les checks d'adresse zéro utilisent `require` avec un message court
///      (plutôt qu'une erreur custom) pour rester détectables par les
///      scanners de sécurité automatisés qui pattern-matchent ce style.
abstract contract Ownable2Step is Context {
    address private _owner;
    address private _pendingOwner;

    /// @notice Erreur levée quand l'appelant n'est pas autorisé.
    error OwnableUnauthorizedAccount(address account);

    /// @notice Émis quand l'ownership est transférée (renonciation incluse).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Émis quand une proposition de transfert (étape 1) démarre.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Initialise le propriétaire du contrat.
    /// @param initialOwner_ propriétaire initial, ne peut pas être zéro.
    constructor(address initialOwner_) {
        require(initialOwner_ != address(0), "Ownable: zero address");
        _transferOwnership(initialOwner_);
    }

    /// @notice Restreint l'appel au propriétaire actuel.
    modifier onlyOwner() {
        if (owner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        _;
    }

    /// @notice Retourne le propriétaire actuel.
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /// @notice Retourne le propriétaire en attente d'acceptation, s'il y en a un.
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /// @notice Renonce immédiatement et irréversiblement à l'ownership.
    function renounceOwnership() public virtual onlyOwner {
        delete _pendingOwner;
        _transferOwnership(address(0));
    }

    /// @notice Démarre un transfert d'ownership en deux étapes vers `newOwner_`.
    /// @param newOwner_ propriétaire candidat, ne peut pas être zéro.
    function transferOwnership(address newOwner_) public virtual onlyOwner {
        require(newOwner_ != address(0), "Ownable: zero address");
        _pendingOwner = newOwner_;
        emit OwnershipTransferStarted(owner(), newOwner_);
    }

    /// @notice Termine le transfert d'ownership. Doit être appelé par le propriétaire en attente.
    function acceptOwnership() public virtual {
        if (_msgSender() != _pendingOwner) revert OwnableUnauthorizedAccount(_msgSender());
        _transferOwnership(_msgSender());
    }

    /// @dev Effectue le changement de propriétaire et émet l'événement associé.
    function _transferOwnership(address newOwner_) internal virtual {
        delete _pendingOwner;
        address oldOwner = _owner;
        _owner = newOwner_;
        emit OwnershipTransferred(oldOwner, newOwner_);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ReentrancyGuard — identique au style RMHT.sol / RMHTAirdropCustodian
// ═══════════════════════════════════════════════════════════════════════════

/// @title ReentrancyGuard
/// @author Ced — Milestone HODL Token
/// @notice Empêche la réentrance sur les fonctions marquées `nonReentrant`.
abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    /// @notice Erreur levée en cas de tentative de réentrance.
    error ReentrancyGuardReentrantCall();

    /// @notice Émis à l'initialisation du guard.
    event ReentrancyGuardInitialized();

    /// @notice Initialise le guard à l'état "non entré".
    constructor() {
        _status = NOT_ENTERED;
        emit ReentrancyGuardInitialized();
    }

    /// @notice Empêche tout appel réentrant à la fonction protégée.
    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrancyGuardReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

/// @title RMHTFounderCustodian
/// @author Ced — Milestone HODL Token
/// @notice Détient l'allocation fondateur $RMHT (50M) et libère le PRINCIPAL
///         intégralement, en une fois, à partir de `unlockTime` — date
///         immutable fixée au déploiement, aucun déblocage partiel avant.
///         Les REWARDS de palier accumulées sur ce solde bloqué sont, elles,
///         réclamables à tout moment via harvestVaultRewards()/claimReward(),
///         indépendamment du verrou d'un an sur le principal.
/// @dev Voir l'en-tête du fichier pour le design complet.
contract RMHTFounderCustodian is Ownable2Step, ReentrancyGuard {

    // ───────────────────────────────────────────────────────────────────────
    //  ERRORS
    // ───────────────────────────────────────────────────────────────────────
    error RmhtAlreadySet();
    error TokenNotContract();
    error RmhtNotSetYet();
    /// @notice Levée si la date de déblocage passée au constructeur n'est pas
    ///         dans le futur (seule validation possible sur une valeur immutable).
    error UnlockTimeMustBeFuture();
    error NotBeneficiary();
    error NothingToClaim();
    error NothingToClaimReward();
    error TransferFailed();
    error NothingToRescue();
    error EthTransferFailed();

    // ───────────────────────────────────────────────────────────────────────
    //  CONSTANTS
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Allocation totale fondateur détenue par ce contrat.
    uint256 public constant FOUNDER_ALLOCATION = 50_000_000 * 1e18;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — bénéficiaire
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Adresse fondateur, seule autorisée à réclamer. Fixée au déploiement.
    address public immutable beneficiary;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — token géré, fixé une seule fois post-déploiement
    // ───────────────────────────────────────────────────────────────────────
    /// @dev Volontairement PAS immutable : ce contrat est déployé AVANT RMHT.sol
    ///      (même raison que RMHTAirdropCustodian.sol — son adresse doit être
    ///      connue pour être passée comme founderWalletAddr au constructeur RMHT).
    IERC20 public rmht;
    /// @notice `true` une fois `rmht` réglé.
    bool public rmhtSet;

    // ───────────────────────────────────────────────────────────────────────
    //  IMMUTABLE — déblocage temporel (unique chemin de sortie des 50M)
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Timestamp à partir duquel 100% de l'allocation devient
    ///         réclamable. Avant cette date, `unlockedAmount()` vaut 0.
    /// @dev IMMUTABLE depuis le 27/08/2026 : fixé dans le constructeur, donc
    ///      dans la transaction de déploiement elle-même. Il n'y a plus de
    ///      `setUnlockTime()`. C'est délibéré — depuis le retrait du
    ///      déblocage par tranches, cette date est le SEUL chemin de sortie
    ///      des 50M : un setter oublié avant `renounceOwnership()` aurait
    ///      gelé l'allocation pour toujours. En contrepartie, la date n'est
    ///      plus corrigeable après déploiement (voir en-tête du fichier).
    uint48 public immutable unlockTime;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — suivi des retraits (cumulatif, claim() appelable plusieurs fois)
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Montant déjà retiré à date (cumulatif, pas un flag booléen —
    ///         chaque claim() ne retire que la différence avec le débloqué courant).
    uint256 public claimedAmount;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — rewards de palier (AJOUT 28/08/2026), indépendant du principal
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Total des rewards de palier rapatriées depuis RMHT.sol à date
    ///         (cumulatif). Un seul bénéficiaire ici — pas besoin d'un
    ///         accumulateur reward-per-share comme dans RMHTAirdropCustodian.sol.
    uint256 public totalHarvestedRewards;
    /// @notice Part des rewards rapatriées déjà réclamée par le bénéficiaire (cumulatif).
    uint256 public claimedRewards;

    // ───────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Émis au déploiement du contrat.
    event CustodianDeployed(address indexed initialOwner, address indexed beneficiary);
    /// @notice Émis quand l'adresse du token $RMHT est réglée.
    event RmhtTokenSet(address indexed rmhtToken);
    /// @notice Émis au déploiement, avec la date de déblocage immutable.
    event UnlockTimeSet(uint256 unlockTime);
    /// @notice Émis à chaque retrait (partiel ou total) du bénéficiaire.
    event Claimed(address indexed beneficiary, uint256 amount, uint256 totalClaimedAfter);
    /// @notice Émis quand de l'ETH envoyé par erreur est récupéré.
    event EthRescued(address indexed to, uint256 amount);
    /// @notice Émis quand des rewards de palier sont rapatriées depuis RMHT.sol.
    event RewardsHarvested(uint256 amount, uint256 totalHarvestedRewardsAfter);
    /// @notice Émis quand le bénéficiaire réclame des rewards de palier déjà rapatriées.
    event RewardClaimed(address indexed beneficiary, uint256 amount);

    /// @notice Déploie le custodian avec `initialOwner` comme propriétaire de
    ///         setup, `beneficiary_` comme seule adresse autorisée à réclamer,
    ///         et `unlockTime_` comme date de déblocage définitive.
    /// @param initialOwner   propriétaire initial (setup uniquement, avant renounceOwnership()).
    /// @param beneficiary_   adresse fondateur, immuable, seule autorisée à claim().
    /// @param unlockTime_    timestamp de déblocage total, IMMUTABLE, doit être
    ///                       dans le futur (typiquement block.timestamp + 365 days).
    constructor(address initialOwner, address beneficiary_, uint48 unlockTime_)
        payable
        Ownable2Step(initialOwner)
    {
        require(beneficiary_ != address(0), "RMHTFounder: zero address");
        // Seule validation possible ici : la date doit être dans le futur.
        // On ne borne PAS volontairement le haut (pas de "max 2 ans") — ce
        // serait une contrainte arbitraire, et une date absurde reste
        // corrigeable en redéployant tant que RMHT.sol n'a pas minté dessus.
        if (unlockTime_ <= block.timestamp) revert UnlockTimeMustBeFuture();

        beneficiary = beneficiary_;
        unlockTime = unlockTime_;
        emit CustodianDeployed(initialOwner, beneficiary_);
        emit UnlockTimeSet(unlockTime_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SETUP (owner uniquement — à faire avant renounceOwnership)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Fixe l'adresse RMHT une seule fois, juste après le déploiement
    ///         de RMHT.sol (qui a déjà minté l'allocation fondateur directement
    ///         sur ce contrat via son constructeur).
    /// @param rmhtToken adresse du contrat $RMHT déployé, doit être un contrat non nul.
    function setRmhtToken(address rmhtToken) external payable onlyOwner {
        if (rmhtSet) revert RmhtAlreadySet();
        require(rmhtToken != address(0), "RMHTFounder: zero address");
        if (rmhtToken.code.length == 0) revert TokenNotContract();
        rmht = IERC20(rmhtToken);
        rmhtSet = true;
        emit RmhtTokenSet(rmhtToken);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CLAIM — pull-payment, tout ou rien à partir de `unlockTime`
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Montant total débloqué à l'instant présent : 0 avant
    ///         `unlockTime`, la totalité de l'allocation à partir de cette
    ///         date — avant déduction de ce qui a déjà été réclamé.
    /// @dev REFONTE 27/08/2026 : plus aucune tranche, plus aucun appel externe
    ///      vers RMHT.sol dans ce chemin. La fonction est désormais purement
    ///      déterministe à partir de `block.timestamp` et d'une constante
    ///      immutable — rien qu'un tiers puisse influencer.
    function unlockedAmount() public view returns (uint256) {
        return block.timestamp >= unlockTime ? FOUNDER_ALLOCATION : 0;
    }

    /// @notice Montant actuellement réclamable par le bénéficiaire (débloqué
    ///         moins déjà réclamé).
    function claimableNow() external view returns (uint256) {
        return unlockedAmount() - claimedAmount;
    }

    /// @notice Réclame la part débloquée et pas encore retirée. En pratique un
    ///         seul appel suffit depuis la refonte du 27/08/2026 (0 avant
    ///         `unlockTime`, 100% après) ; la fonction reste néanmoins
    ///         idempotente — un second appel revert avec NothingToClaim.
    ///         Seul `beneficiary` peut l'appeler.
    function claim() external nonReentrant {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (!rmhtSet) revert RmhtNotSetYet();

        uint256 claimable = unlockedAmount() - claimedAmount;
        if (claimable == 0) revert NothingToClaim();

        claimedAmount += claimable;

        emit Claimed(beneficiary, claimable, claimedAmount);
        if (!rmht.transfer(beneficiary, claimable)) revert TransferFailed();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  REWARDS DE PALIER (AJOUT 28/08/2026) — indépendant du verrou d'un an
    //  sur le principal. founderWallet (= ce contrat) n'est pas exclu des
    //  rewards côté RMHT.sol (voir RMHT.sol) : le solde bloqué ici en
    //  accumule à chaque palier, exactement comme n'importe quel détenteur.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Rapatrie depuis RMHT.sol les rewards de palier accumulées sur
    ///         le solde de ce contrat (le principal FOUNDER_ALLOCATION tant
    ///         qu'il n'a pas encore été réclamé). Permissionless — n'importe
    ///         qui peut la déclencher, aucun fonds ne quitte le contrat ici
    ///         (le bénéficiaire seul peut ensuite les réclamer via claimReward()).
    /// @dev Mesure le delta de solde autour de l'appel plutôt que de faire
    ///      confiance à une valeur de retour, même style que RMHTAirdropCustodian.sol.
    ///
    ///      FIX 28/08/2026 : `RMHT.claimRewards()` fait
    ///      `require(reward != 0, "RMHT: No rewards")` — appelé alors qu'il
    ///      n'y a rien à récolter, il REVERT au lieu de ne rien faire. Cette
    ///      fonction étant permissionless (typiquement appelée en boucle par
    ///      un bot ou un script après chaque palier), on teste d'abord
    ///      `pendingRewardsOf(address(this))` et on sort silencieusement s'il
    ///      n'y a rien : appeler à l'aveugle ne coûte plus qu'un peu de gas
    ///      au lieu d'un revert. Ce test couvre aussi le cas où ce contrat
    ///      serait un jour exclu des rewards côté RMHT.sol
    ///      (pendingRewardsOf renvoie alors 0, et claimRewards() reverterait
    ///      avec "RMHT: Excluded from rewards").
    ///
    ///      ⚠️ Le no-op est écrit en `if (...) { ... }` et SURTOUT PAS en
    ///      `if (rien à faire) return;` : sous un modifier, un `return`
    ///      saute le code du modifier situé après `_;` — ici
    ///      `_status = NOT_ENTERED;` — et bloquerait le verrou de réentrance
    ///      à ENTERED pour toujours dès le premier appel à vide. C'est
    ///      exactement le bug rencontré sur `RMHT.pokeMilestone()` le
    ///      21/08/2026 ; ne pas le réintroduire ici. Les `revert` en
    ///      revanche sont sans danger (toute la transaction est annulée,
    ///      verrou compris).
    function harvestVaultRewards() external payable nonReentrant {
        if (!rmhtSet) revert RmhtNotSetYet();

        if (IRMHTRewards(address(rmht)).pendingRewardsOf(address(this)) != 0) {
            uint256 before = rmht.balanceOf(address(this));
            IRMHTRewards(address(rmht)).claimRewards();
            uint256 harvested = rmht.balanceOf(address(this)) - before;

            if (harvested != 0) {
                totalHarvestedRewards += harvested;
                emit RewardsHarvested(harvested, totalHarvestedRewards);
            }
        }
    }

    /// @notice Rewards de palier déjà rapatriées et pas encore réclamées.
    function claimableRewardsNow() external view returns (uint256) {
        return totalHarvestedRewards - claimedRewards;
    }

    /// @notice Réclame les rewards de palier déjà rapatriées et pas encore
    ///         retirées. Indépendant de claim() (le principal) — réclamable
    ///         à tout moment, y compris avant `unlockTime`, et plusieurs fois
    ///         au fil des paliers. Seul `beneficiary` peut l'appeler.
    function claimReward() external nonReentrant {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        uint256 claimable = totalHarvestedRewards - claimedRewards;
        if (claimable == 0) revert NothingToClaimReward();

        claimedRewards += claimable;

        emit RewardClaimed(beneficiary, claimable);
        if (!rmht.transfer(beneficiary, claimable)) revert TransferFailed();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  RESCUE ETH — uniquement l'ETH envoyé par erreur (receive() payable).
    //  Volontairement PAS de rescue token : tout ERC20 envoyé par erreur à
    //  ce contrat reste bloqué définitivement, choix de design assumé (même
    //  logique que RMHTAirdropCustodian.sol).
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Récupère tout ETH envoyé par erreur à ce contrat.
    /// @param to destinataire de l'ETH récupéré, ne peut pas être zéro.
    function rescueEth(address payable to) external payable nonReentrant onlyOwner {
        require(to != address(0), "RMHTFounder: zero address");
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToRescue();
        emit EthRescued(to, amount);
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }

    /// @notice Permet à ce contrat de recevoir de l'ETH (récupérable via rescueEth()).
    /// @dev Signalé "inutilisé" par l'analyse statique mais nécessaire au design :
    ///      sans lui, tout ETH envoyé par erreur ferait revert au lieu d'être récupérable.
    receive() external payable {}
}
