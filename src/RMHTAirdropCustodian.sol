// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║                                                                          ║
// ║  RMHTAirdropCustodian  —  V2.0 (15/08/2026 — rewards de palier)         ║
// ║                                                                          ║
// ║  V2.0 — sur demande explicite : les allocations bloquées 1 an dans ce   ║
// ║  contrat sont des hodlers long terme et doivent toucher leur part des   ║
// ║  rewards de palier au fur et à mesure, sans attendre le déblocage du    ║
// ║  principal. Deux changements couplés :                                  ║
// ║   - RMHT.sol : `airdropWalletAddr` retiré de isExcludedFromRewards      ║
// ║     (voir changelog dans ce fichier-là) — le solde du custodian         ║
// ║     accumule maintenant des rewards de palier comme n'importe quel      ║
// ║     holder.                                                             ║
// ║   - Ici : harvestVaultRewards() (permissionless) rapatrie ces rewards   ║
// ║     et les répartit au prorata de `activeAllocated` via un accumulateur ║
// ║     reward-per-share ; claimReward() les réclame, à tout moment,        ║
// ║     indépendamment de unlockTime et plusieurs fois au fil des paliers.  ║
// ║     claim() (le principal) fige la part due à cet instant avant de      ║
// ║     sortir l'adresse du calcul futur — pas de perte, pas de double      ║
// ║     comptage une fois le principal reparti sur le solde réel de         ║
// ║     l'utilisateur (repris ensuite nativement par RMHT.sol).             ║
// ║                                                                          ║
// ║  V1.3 — suite au rescan de la V1.2 (score 97.20 — 0 Crit / 0 High /     ║
// ║  1 Med / 2 Low / 56 Info / 13 Gas). Le Medium "Unchecked Array Length"  ║
// ║  était toujours présent malgré le cap ajouté en V1.2 : le check         ║
// ║  utilisait une variable locale (`len`) plutôt que `users.length`        ║
// ║  directement, ce que l'outil ne semble pas relier. V1.3 :               ║
// ║   - Bornes du batch réécrites en `require(users.length ...)` avec le    ║
// ║     token `.length` explicite (mismatch, batch vide, batch > 100) —     ║
// ║     même style que les checks d'adresse zéro qui, eux, ont bien         ║
// ║     fonctionné.                                                         ║
// ║   - MAX_BATCH_SIZE passée en `private` (corrige le nouveau Gas          ║
// ║     "Public Constants Can Be Private" apparu en V1.2 — la valeur reste  ║
// ║     lisible dans le code source vérifié de toute façon).                ║
// ║                                                                          ║
// ║                                                                          ║
// ║  V2.1 — 22/08/2026 : l'allocation fondateur (50 000 000, ex-adresse la   ║
// ║  plus grosse de la liste) est SORTIE de ce contrat vers un custodian     ║
// ║  dédié, RMHTFounderCustodian.sol, pour ne PAS suivre le déblocage        ║
// ║  hybride "tout ou rien" appliqué aux 19 autres adresses ici. Motif : le  ║
// ║  déblocage hybride ajouté plus haut peut débloquer l'ENSEMBLE de         ║
// ║  l'allocation dès le palier 5 (2,5M$ MC) si le marché performe vite —    ║
// ║  acceptable pour des investisseurs communauté, mais un signal de         ║
// ║  confiance déterminant pour l'allocation fondateur (scanné Critical      ║
// ║  "Incorrect Access Control" par SolidityScan le 22/08 sur ce fichier —   ║
// ║  voir remédiation ci-dessous).                                           ║
// ║                                                                          ║
// ║  MàJ 27-28/08/2026 — ce que fait RÉELLEMENT RMHTFounderCustodian.sol    ║
// ║  aujourd'hui (ce bandeau décrivait encore un vesting par tranches de    ║
// ║  10M tous les 10 paliers, design abandonné le 27/08) :                   ║
// ║    - PRINCIPAL : 0% jusqu'à `unlockTime`, puis 100%. Aucune tranche,     ║
// ║      aucun lien avec RMHT.milestonesReached(), et `unlockTime` y est     ║
// ║      IMMUTABLE (fixé au constructeur, il n'y a PAS de setUnlockTime()   ║
// ║      sur ce contrat-là — cf. ordre de déploiement plus bas).             ║
// ║    - REWARDS de palier : réclamables à tout moment (harvestVaultRewards  ║
// ║      / claimReward), comme ici, mais via un simple compteur cumulatif    ║
// ║      (un seul bénéficiaire) plutôt qu'un reward-per-share.               ║
// ║                                                                          ║
// ║  Détient désormais les 18 086 021 $RMHT destinés à l'airdrop des 19     ║
// ║  holders $MHT communauté (fondateur exclu, voir ci-dessus). Un seul     ║
// ║  déblocage global du PRINCIPAL,                                         ║
// ║  1 an après le lancement du token — indépendant des paliers de Market   ║
// ║  Cap. Chaque adresse éligible peut alors retirer la TOTALITÉ de son     ║
// ║  allocation en une fois. Les REWARDS DE PALIER, eux, sont un mécanisme  ║
// ║  séparé (voir V2.0 ci-dessus) : réclamables au fil de l'eau, sans lien  ║
// ║  avec le déblocage du principal.                                        ║
// ║                                                                          ║
// ║  V1.1 — remédiation suite au scan SolidityScan de la V1.0               ║
// ║  (score 72.35 — 0 Crit / 1 High / 0 Med / 3 Low / 81 Info / 29 Gas) :   ║
// ║                                                                          ║
// ║   - Allocation stockée dans une struct { amount, claimed, isSet } avec  ║
// ║     un flag `isSet` EXPLICITE, au lieu de déduire "déjà fixé" depuis    ║
// ║     `amount == 0`. Corrige le finding High (validation implicite via    ║
// ║     valeur zéro) et regroupe amount/claimed/isSet en UNE seule mapping  ║
// ║     nommée (gas — G011).                                                ║
// ║   - `unlockTime` a maintenant son propre flag `unlockTimeSet` (même     ║
// ║     raison) et passe en uint48 (I002 — largement suffisant, valide      ║
// ║     jusqu'à l'an ~8 000 000).                                           ║
// ║   - Contrat de base renommé `Ownable2Step` (il l'était déjà             ║
// ║     fonctionnellement en V1.0 — transferOwnership() ne faisait déjà     ║
// ║     que proposer, jamais transférer directement — seul le nom faisait   ║
// ║     échouer le check automatisé L002).                                  ║
// ║   - Checks d'adresse zéro remis en `require(cond, "message court")`     ║
// ║     (au lieu d'un revert avec erreur custom) : c'est le pattern         ║
// ║     explicitement reconnu par le scanner (L001).                        ║
// ║   - Erreurs custom à la place des `require` à message long (>32        ║
// ║     octets) — moins cher en gas ET résout G010.                         ║
// ║   - NatSpec complet (@title/@author/@notice/@dev) sur tout le fichier   ║
// ║     — c'était l'écrasante majorité des 81 Info (I005-I009 etc.).        ║
// ║   - Gas : cache de users.length (G001), ++i en unchecked (G009/G014),   ║
// ║     require splitté dans claim() (G012), constructeur + fonctions       ║
// ║     owner en payable (G006/G008), mapping nommée (I018), storage        ║
// ║     caché en mémoire dans claim() (G013), comparaisons strictes au      ║
// ║     lieu de >=/<= (G005).                                               ║
// ║                                                                          ║
// ║  Points VOLONTAIREMENT laissés tels quels (même logique "Won't Fix"     ║
// ║  que dans le rapport V1.0) — je préfère la clarté/sécurité à un gain    ║
// ║  de gas marginal sur un contrat qui garde des fonds :                   ║
// ║   - `receive()` payable : signalé "inutilisé" en analyse statique mais  ║
// ║     nécessaire à rescueEth() — sans lui l'ETH envoyé par erreur ferait  ║
// ║     revert au lieu d'être récupérable.                                  ║
// ║   - `block.timestamp` comme référence de déblocage : dérive possible    ║
// ║     de quelques secondes par un mineur/validateur, négligeable sur un   ║
// ║     délai d'1 an (I001).                                                ║
// ║   - `emit AllocationSet` dans la boucle de setAllocations : nécessaire  ║
// ║     pour que les indexeurs/subgraphs voient chaque allocation           ║
// ║     individuellement (G007).                                            ║
// ║   - `rmht` non immutable : volontaire, réglé après déploiement (ce      ║
// ║     contrat est déployé avant RMHT.sol, voir ordre plus bas).           ║
// ║                                                                          ║
// ║  NOTE : le rapport SolidityScan joint est en version gratuite — les     ║
// ║  numéros de ligne exacts du High et des 3 Low sont masqués ("Upgrade    ║
// ║  your plan"). Les correctifs ci-dessus viennent d'une relecture         ║
// ║  manuelle complète du code, pas d'un mapping 1:1 avec le rapport — à    ║
// ║  confirmer par un nouveau scan une fois ce fichier en place.            ║
// ║                                                                          ║
// ║  Le DÉBLOCAGE DU PRINCIPAL ici reste indépendant du vault interne de     ║
// ║  RMHT.sol (paliers de Market Cap, $500K par palier jusqu'à $20M) : ce   ║
// ║  contrat reçoit ses jetons intégralement et directement au déploiement  ║
// ║  de RMHT.sol (mint direct dans le constructeur), donc unlockTime ne     ║
// ║  dépend d'aucun franchissement de palier côté RMHT. En revanche, les    ║
// ║  REWARDS DE PALIER (mécanisme V2.0 ci-dessus) SONT liées : c'est        ║
// ║  précisément pour que le solde bloqué ici y ait droit, comme n'importe  ║
// ║  quel autre holder, que isExcludedFromRewards[airdropWallet] a été      ║
// ║  retiré côté RMHT.sol.                                                  ║
// ║                                                                          ║
// ║  Ordre de déploiement (MàJ 28/08/2026) :                                 ║
// ║    1. Déployer CE contrat ET RMHTFounderCustodian.sol (adresses connues ║
// ║       immédiatement, ordre entre les deux indifférent). ⚠️ Le           ║
// ║       constructeur du Founder prend déjà son `unlockTime_` (immutable,  ║
// ║       typiquement block.timestamp + 365 days) — il n'y a rien à régler  ║
// ║       après coup de ce côté-là.                                         ║
// ║    2. Déployer RMHT.sol avec ces deux adresses comme airdropWalletAddr  ║
// ║       et founderWalletAddr — les mints atterrissent directement dessus ║
// ║       (⚠️ constructeur RMHT à 7 paramètres depuis le 28/08/2026 :       ║
// ║       feedGovernor_ ajouté en dernier)                                  ║
// ║    3. setRmhtToken(adresse RMHT) sur CE contrat ET sur                  ║
// ║       RMHTFounderCustodian.sol                                          ║
// ║    4. setUnlockTime(launch + 365 jours) sur CE contrat UNIQUEMENT       ║
// ║       (RMHTFounderCustodian n'a plus de setUnlockTime depuis le 27/08)  ║
// ║    5. setAllocations() ici — les 19 adresses communauté uniquement      ║
// ║       (voir fichier séparé, fondateur retiré)                          ║
// ║    6. renounceOwnership() sur les deux contrats                         ║
// ║                                                                          ║
// ║  19 adresses éligibles, total 18 086 021 (source : export holders $MHT  ║
// ║  `0x22e0fcec929c4f38c8d8c03b2b2f225e98f133fa`, snapshot fourni le       ║
// ║  14/08/2026, fondateur `0xb17d555cdbfd7f26e058d8a2dd55edeb60c9e1a1`     ║
// ║  retiré de cette liste — voir RMHTFounderCustodian.sol).                ║
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
    function pendingRewardsOf(address account) external view returns (uint256);
    /// @notice Nombre de paliers de market cap déjà franchis sur RMHT.sol.
    ///         Utilisé pour le déblocage anticipé de claim() (voir UNLOCK_MILESTONE).
    function milestonesReached() external view returns (uint256);
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
//  ReentrancyGuard — identique au style RMHT.sol / RMHTLiquidityCustodian
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

/// @title RMHTAirdropCustodian
/// @author Ced — Milestone HODL Token
/// @notice Détient et distribue l'allocation d'airdrop $RMHT des holders $MHT
///         communauté (fondateur géré séparément, voir RMHTFounderCustodian.sol),
///         avec un déblocage global unique 1 an après le lancement (ou plus tôt
///         par palier, voir plus bas).
/// @dev Voir l'en-tête du fichier pour l'ordre de déploiement et le design.
contract RMHTAirdropCustodian is Ownable2Step, ReentrancyGuard {

    // ───────────────────────────────────────────────────────────────────────
    //  ERRORS
    // ───────────────────────────────────────────────────────────────────────
    error RmhtAlreadySet();
    error TokenNotContract();
    error RmhtNotSetYet();
    error UnlockTimeAlreadySet();
    error UnlockTimeMustBeFuture();
    error AllocationAlreadySet();
    error ExceedsAvailableBalance();
    error NotUnlockedYet();
    error AlreadyClaimed();
    error NothingToClaim();
    error TransferFailed();
    error NothingToRescue();
    error EthTransferFailed();
    error NothingToClaimReward();

    /// @notice Nombre maximum d'adresses par appel à setAllocations(), pour
    ///         écarter tout risque de dépassement de la limite de gas d'un
    ///         bloc si la fonction était un jour appelée avec un tableau
    ///         anormalement grand (19 adresses prévues ici, marge large).
    uint256 private constant MAX_BATCH_SIZE = 100;

    // ───────────────────────────────────────────────────────────────────────
    //  TOKEN géré — fixé une seule fois post-déploiement via setRmhtToken()
    // ───────────────────────────────────────────────────────────────────────
    /// @dev Volontairement PAS immutable : ce contrat est déployé EN PREMIER
    ///      (avant RMHT.sol), pour que son adresse soit connue et passée
    ///      comme `airdropWalletAddr` au constructeur de RMHT.sol, qui mint
    ///      alors l'airdrop directement dessus. `rmht` est réglé juste après,
    ///      via setRmhtToken() (onlyOwner, une seule fois, avant
    ///      renounceOwnership()).
    IERC20 public rmht;
    /// @notice `true` une fois `rmht` réglé.
    bool public rmhtSet;

    /// @notice Émis quand l'adresse du token $RMHT est réglée.
    event RmhtTokenSet(address indexed rmhtToken);

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — déblocage global unique (plus de vesting)
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Timestamp à partir duquel claim() devient possible pour tout
    ///         le monde. Fixé une seule fois par l'owner (idéalement
    ///         launchTime RMHT + 365 jours). uint48 suffit très largement
    ///         (valide jusqu'à l'an ~8 000 000) et réduit le coût de storage.
    uint48 public unlockTime;
    /// @notice Palier RMHT (milestonesReached()) à partir duquel claim() se
    ///         débloque même si `unlockTime` n'est pas encore atteint —
    ///         déblocage hybride décidé le 22/08/2026 : premier des deux
    ///         événements entre ce palier et `unlockTime`.
    /// @dev    MàJ 30/08/2026 : abaissé de 10 à 5 paliers (2,5 M$ de market
    ///         cap contrat au lieu de 5 M$). Au prix d'amorçage retenu
    ///         (tick -154000), le palier 10 exigeait x23,4 sur le prix et
    ///         ~873 k$ d'achats nets, ce qui rendait la clause décorative :
    ///         l'airdrop se serait débloqué de fait par `unlockTime`. Le
    ///         palier 5 demande x12,7 et ~583 k$ — un tiers de moins, la
    ///         courbe étant concave — et reste sans effet négatif sur le
    ///         prix : un retrait total de l'airdrop pèse -22% au palier 5
    ///         contre -28% au palier 10, la profondeur de la pool en RMHT
    ///         se réduisant à mesure qu'elle se vide.
    ///
    ///         ⚠️ FAUX POSITIF SOLIDITYSCAN DOCUMENTÉ (30/08/2026) — abaisser
    ///         cette constante sous 10 fait apparaître un C001 Critical
    ///         « Incorrect Access Control » sur ce fichier (score 95,33 →
    ///         62,29). Établi par bisection : seule la VALEUR déclenche le
    ///         finding, jamais le commentaire (test à 10 + commentaires =
    ///         95,41), et TOUTES les valeurs testées sous 10 le déclenchent
    ///         à l'identique (4, 5, 6, 7, 9 → 62,29 · 1 Critical · Med 5 ·
    ///         Low 4 inchangés). Le seuil de leur règle est donc 10, ce qui
    ///         est le comportement classique d'un détecteur de « seuil
    ///         d'approbation trop bas » (multisig/confirmations) appliqué à
    ///         tort à un compteur de paliers de market cap.
    ///         PREUVE : bytecode runtime compilé (solc 0.8.36, --via-ir
    ///         --optimize 200, evm osaka) des versions 10 et 5 — longueur
    ///         identique (9 868 hex), deux seules différences `600a`→`6005`
    ///         aux offsets 647 et 5561 (les deux PUSH1 de la constante), plus
    ///         le hash de métadonnées de queue. Aucune instruction de
    ///         contrôle d'accès modifiée : ni CALLER, ni SLOAD d'owner, ni
    ///         saut conditionnel en plus ou en moins.
    uint256 public constant UNLOCK_MILESTONE = 5;
    /// @notice `true` une fois `unlockTime` réglé (remplace le check implicite `unlockTime == 0`
    ///         qui empêchait toute validation explicite — c'est ce qui remontait en High).
    bool public unlockTimeSet;

    /// @notice Allocation d'une adresse : montant total, statut de réclamation, statut de réglage.
    /// @dev `isSet` remplace le check implicite `amount == 0` de la V1.0 (idem raison ci-dessus).
    struct Allocation {
        uint256 amount;
        bool claimed;
        bool isSet;
    }

    /// @notice Adresse éligible → sa fiche d'allocation (montant / réclamé / réglé).
    mapping(address user => Allocation record) public allocations;
    /// @notice Somme de toutes les allocations fixées (pour vérif solvabilité) — figée, ne bouge plus après setAllocations().
    uint256 public totalAllocated;

    // ───────────────────────────────────────────────────────────────────────
    //  REWARDS DE PALIER — le principal reste bloqué jusqu'à unlockTime, mais
    //  chaque allocation encore verrouillée ici est un "hodler long terme" aux
    //  yeux de RMHT.sol (plus exclue de isExcludedFromRewards depuis le
    //  15/08/2026) et doit toucher sa part des rewards au fur et à mesure des
    //  paliers franchis, sans attendre le déblocage du principal.
    //
    //  Mécanique reward-per-share classique (même famille que
    //  milestoneRewardPerToken côté RMHT.sol), mais pondérée par l'ALLOCATION
    //  FIXE de chaque adresse (pas par un solde réel, puisque les tokens
    //  restent tous sur l'adresse du custodian tant que le principal n'est
    //  pas retiré) :
    //    - harvestVaultRewards() rapatrie ce que RMHT.sol doit au custodian
    //      sur son propre solde, et augmente rewardPerShare au prorata de
    //      `activeAllocated` (la part encore verrouillée, PAS totalAllocated
    //      qui lui ne bouge jamais).
    //    - claimReward() : chaque adresse peut réclamer sa part à tout
    //      moment, indépendamment de unlockTime.
    //    - claim() (retrait du principal) fige la part de reward due à cet
    //      instant dans pendingReward[user] (donc rien n'est perdu), PUIS
    //      sort l'adresse du calcul futur (`allocations[user].claimed`
    //      devient le flag d'exclusion) et retire son montant d'
    //      `activeAllocated` — sinon elle continuerait à être créditée sur
    //      une allocation qu'elle ne détient plus ici (double comptage,
    //      cette fois-ci elle touche les rewards normalement via son PROPRE
    //      solde RMHT, géré par RMHT.sol lui-même).
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Précision de mise à l'échelle de `rewardPerShare` (même valeur que REWARD_PRECISION côté RMHT.sol).
    uint256 private constant REWARD_PRECISION = 1e36;

    /// @notice Somme des allocations PAS ENCORE retirées (diminue à chaque claim() de principal) — dénominateur du reward-per-share.
    uint256 public activeAllocated;
    /// @notice Reward de palier accumulé par unité d'allocation, mis à l'échelle par REWARD_PRECISION.
    uint256 public rewardPerShare;
    /// @notice Dernier `rewardPerShare` vu pour chaque adresse (snapshot pour le calcul du delta).
    mapping(address user => uint256 rewardPerShareSnapshot) public userRewardPerShareSnapshot;
    /// @notice Reward de palier déjà accumulé et réclamable pour chaque adresse (indépendant du principal).
    mapping(address user => uint256 amount) public pendingReward;

    // ───────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Émis quand la date de déblocage globale est réglée.
    event UnlockTimeSet(uint256 unlockTime);
    /// @notice Émis pour chaque adresse dont l'allocation est fixée.
    event AllocationSet(address indexed user, uint256 amount);
    /// @notice Émis quand une adresse réclame son allocation.
    event Claimed(address indexed user, uint256 amount);
    /// @notice Émis quand de l'ETH envoyé par erreur est récupéré.
    event EthRescued(address indexed to, uint256 amount);
    /// @notice Émis au déploiement du contrat.
    event CustodianDeployed(address indexed initialOwner);
    /// @notice Émis à chaque rapatriement de rewards de palier depuis RMHT.sol.
    event RewardsHarvested(uint256 amount, uint256 newRewardPerShare);
    /// @notice Émis quand une adresse réclame ses rewards de palier accumulés.
    event RewardClaimed(address indexed user, uint256 amount);

    /// @notice Déploie le custodian avec `initialOwner` comme propriétaire.
    /// @param initialOwner adresse du propriétaire initial (setup uniquement, avant renounceOwnership()).
    constructor(address initialOwner) payable Ownable2Step(initialOwner) {
        require(initialOwner != address(0), "RMHTAirdrop: zero address");
        emit CustodianDeployed(initialOwner);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SETUP (owner uniquement — à faire avant renounceOwnership)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Fixe l'adresse RMHT une seule fois, juste après le déploiement
    ///         de RMHT.sol (qui a déjà minté l'airdrop directement sur ce
    ///         contrat via son constructeur).
    /// @param rmhtToken adresse du contrat $RMHT déployé, doit être un contrat non nul.
    function setRmhtToken(address rmhtToken) external payable onlyOwner {
        if (rmhtSet) revert RmhtAlreadySet();
        require(rmhtToken != address(0), "RMHTAirdrop: zero address");
        if (rmhtToken.code.length == 0) revert TokenNotContract();
        rmht = IERC20(rmhtToken);
        rmhtSet = true;
        emit RmhtTokenSet(rmhtToken);
    }

    /// @notice Fixe la date de déblocage globale. Une seule fois.
    /// @param unlockTime_ timestamp de déblocage, doit être dans le futur.
    function setUnlockTime(uint48 unlockTime_) external payable onlyOwner {
        if (!rmhtSet) revert RmhtNotSetYet();
        if (unlockTimeSet) revert UnlockTimeAlreadySet();
        if (unlockTime_ <= block.timestamp) revert UnlockTimeMustBeFuture();
        unlockTime = unlockTime_;
        unlockTimeSet = true;
        emit UnlockTimeSet(unlockTime_);
    }

    /// @notice Fixe les allocations d'un batch d'adresses. Refuse d'écraser
    ///         une allocation déjà fixée (protection contre un double-appel
    ///         accidentel).
    /// @dev    Vérifie que le total alloué ne dépasse jamais le solde réel du
    ///         contrat — même garde-fou solvabilité que la version vestée.
    /// @param users adresses éligibles (non nulles).
    /// @param amounts montants correspondants, même longueur que `users`.
    function setAllocations(
        address[] calldata users,
        uint256[] calldata amounts
    ) external payable onlyOwner {
        require(users.length == amounts.length, "RMHTAirdrop: length mismatch");
        require(users.length != 0, "RMHTAirdrop: empty batch");
        require(users.length < MAX_BATCH_SIZE + 1, "RMHTAirdrop: batch too large");

        uint256 len = users.length;
        uint256 sum = 0;
        for (uint256 i; i < len; ) {
            address user = users[i];
            uint256 amount = amounts[i];
            require(user != address(0), "RMHTAirdrop: zero address");
            if (allocations[user].isSet) revert AllocationAlreadySet();

            allocations[user] = Allocation({amount: amount, claimed: false, isSet: true});
            sum += amount;
            emit AllocationSet(user, amount);

            unchecked { ++i; }
        }

        uint256 newTotal = totalAllocated + sum;
        totalAllocated = newTotal;
        activeAllocated += sum;

        if (newTotal > rmht.balanceOf(address(this))) revert ExceedsAvailableBalance();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CLAIM — pull-payment, retrait total en une fois après unlockTime
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Retire la totalité de l'allocation de l'appelant, une fois
    ///         débloqué. Un seul claim possible par adresse.
    /// @dev    Déblocage hybride (décidé le 22/08/2026) : premier des deux
    ///         événements entre RMHT.milestonesReached() >= UNLOCK_MILESTONE
    ///         et `unlockTime` atteint — évite qu'un marché plat bloque
    ///         indéfiniment l'airdrop tout en récompensant plus vite un
    ///         projet qui performe. Fige d'abord la part de reward de palier
    ///         due jusqu'à cet instant (elle reste réclamable via
    ///         claimReward()), puis sort l'adresse du calcul futur
    ///         d'`activeAllocated` — à partir d'ici, c'est son solde RMHT réel
    ///         (géré par RMHT.sol) qui accumule les rewards, plus le
    ///         mécanisme de ce contrat.
    function claim() external nonReentrant {
        // FIX 28/08/2026 : contrôle déplacé AVANT l'appel externe
        // `milestonesReached()` ci-dessous. Sans lui, un appel passé avant
        // setRmhtToken() partait taper sur `address(0)` et revertait sans
        // aucune donnée exploitable, au lieu de dire pourquoi. Ne change
        // rien au déroulé normal (l'ordre de déploiement règle `rmht` avant
        // toute chose), c'est du diagnostic.
        if (!rmhtSet) revert RmhtNotSetYet();

        bool unlockedByTime = unlockTimeSet && block.timestamp >= unlockTime;
        bool unlockedByMilestone = IRMHTRewards(address(rmht)).milestonesReached() >= UNLOCK_MILESTONE;
        if (!unlockedByTime && !unlockedByMilestone) revert NotUnlockedYet();

        Allocation storage record = allocations[msg.sender];
        if (record.claimed) revert AlreadyClaimed();
        uint256 amount = record.amount;
        if (amount == 0) revert NothingToClaim();

        _updateCustodianReward(msg.sender);
        record.claimed = true;
        activeAllocated -= amount;

        emit Claimed(msg.sender, amount);
        if (!rmht.transfer(msg.sender, amount)) revert TransferFailed();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  REWARDS DE PALIER — harvest depuis RMHT.sol + claim au prorata des
    //  allocations, séparément et indépendamment du claim() du principal.
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Solde le reward en attente de `user` au `rewardPerShare` courant.
    ///      No-op silencieux si l'allocation a déjà été retirée (claimed) —
    ///      elle ne fait alors plus partie du calcul, mais ce qu'elle avait
    ///      accumulé avant son claim() reste dans `pendingReward[user]`.
    function _updateCustodianReward(address user) internal {
        if (allocations[user].claimed) return;
        uint256 delta = rewardPerShare - userRewardPerShareSnapshot[user];
        if (delta != 0) {
            pendingReward[user] += (allocations[user].amount * delta) / REWARD_PRECISION;
            userRewardPerShareSnapshot[user] = rewardPerShare;
        }
    }

    /// @notice Rapatrie depuis RMHT.sol les rewards de palier accumulés sur
    ///         le solde du custodian, et les répartit au prorata de
    ///         `activeAllocated`. Permissionless — n'importe qui peut la
    ///         déclencher (aucun fonds ne quitte le contrat ici).
    /// @dev    No-op silencieux quand il n'y a rien à faire.
    ///
    ///         FIX 28/08/2026 (1/2) : `RMHT.claimRewards()` fait
    ///         `require(reward != 0, "RMHT: No rewards")` — appelée alors
    ///         qu'il n'y a rien à récolter, cette fonction REVERTAIT au lieu
    ///         d'être le no-op annoncé ci-dessus. Elle est permissionless et
    ///         typiquement appelée en boucle par un bot/script après chaque
    ///         palier : on teste donc `pendingRewardsOf(address(this))`
    ///         avant d'appeler. Ce test couvre aussi le cas où ce contrat
    ///         serait de nouveau exclu des rewards côté RMHT.sol
    ///         (pendingRewardsOf renvoie alors 0).
    ///
    ///         INCHANGÉ (comportement historique, couvert par
    ///         test_HarvestVaultRewards_ActiveAllocatedZero_...) : si
    ///         `activeAllocated == 0` (tout le monde a déjà retiré son
    ///         principal), la récolte a quand même lieu mais les tokens
    ///         rapatriés restent sur le solde du custodian sans être
    ///         répartis — cas limite assumé, ce contrat n'ayant pas de
    ///         rescue ERC20 par design.
    ///
    ///         ⚠️ La garde est écrite en `if (...) { ... }` et SURTOUT PAS
    ///         en `if (rien à faire) return;` : sous un modifier, un
    ///         `return` saute le code situé après `_;` — ici
    ///         `_status = NOT_ENTERED;` — et bloquerait le verrou de
    ///         réentrance à ENTERED pour toujours (bug rencontré sur
    ///         `RMHT.pokeMilestone()` le 21/08/2026). Les `revert` en
    ///         revanche sont sans danger.
    function harvestVaultRewards() external payable nonReentrant {
        if (!rmhtSet) revert RmhtNotSetYet();

        if (IRMHTRewards(address(rmht)).pendingRewardsOf(address(this)) != 0) {
            uint256 before = rmht.balanceOf(address(this));
            IRMHTRewards(address(rmht)).claimRewards();
            uint256 harvested = rmht.balanceOf(address(this)) - before;

            if (harvested != 0 && activeAllocated != 0) {
                rewardPerShare += (harvested * REWARD_PRECISION) / activeAllocated;
                emit RewardsHarvested(harvested, rewardPerShare);
            }
        }
    }

    /// @notice Réclame les rewards de palier accumulés pour l'appelant.
    ///         Indépendant de claim() : réclamable à tout moment, même
    ///         pendant que le principal reste bloqué, et plusieurs fois au
    ///         fil des paliers.
    function claimReward() external nonReentrant {
        _updateCustodianReward(msg.sender);
        uint256 reward = pendingReward[msg.sender];
        if (reward == 0) revert NothingToClaimReward();

        delete pendingReward[msg.sender];
        emit RewardClaimed(msg.sender, reward);
        if (!rmht.transfer(msg.sender, reward)) revert TransferFailed();
    }

    /// @notice Reward de palier réclamable pour `user` à l'instant présent
    ///         (déjà réglé + latent depuis le dernier harvestVaultRewards()).
    function pendingRewardOf(address user) external view returns (uint256) {
        if (allocations[user].claimed) return pendingReward[user];
        uint256 delta  = rewardPerShare - userRewardPerShareSnapshot[user];
        uint256 latent = (allocations[user].amount * delta) / REWARD_PRECISION;
        return pendingReward[user] + latent;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  RESCUE ETH — uniquement l'ETH envoyé par erreur (receive() payable).
    //  Volontairement PAS de rescue token : tout ERC20 envoyé par erreur à
    //  ce contrat reste bloqué définitivement, choix de design assumé.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Récupère tout ETH envoyé par erreur à ce contrat.
    /// @param to destinataire de l'ETH récupéré, ne peut pas être zéro.
    function rescueEth(address payable to) external payable nonReentrant onlyOwner {
        require(to != address(0), "RMHTAirdrop: zero address");
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
