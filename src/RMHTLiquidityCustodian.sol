// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
// MàJ 27/08/2026 : pragma ÉPINGLÉ (était `>=0.8.34 <0.8.37`).
//   - SolidityScan remontait "USE OF FLOATING PRAGMA" (Low) sur la plage ;
//   - les trois autres contrats du protocole (RMHT, Airdrop, Founder) sont
//     déjà épinglés sur 0.8.36, donc la plage n'achetait plus rien : Wake,
//     dont `wake.toml` cible encore 0.8.34, ne peut de toute façon déjà plus
//     compiler aucun d'eux. ⚠️ À BUMPER dans wake.toml dès que l'outil
//     supporte 0.8.36, sinon Wake ne couvre plus rien du protocole.

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  RMHTLiquidityCustodian                                                  ║
// ║                                                                          ║
// ║  Détient le NFT de position Uniswap v3 $RMHT/WETH et ne permet QUE la    ║
// ║  collecte des frais de swap accumulés (1% par trade sur la pool).       ║
// ║                                                                          ║
// ║  Garantie de sécurité : ce contrat n'a AUCUNE fonction permettant de     ║
// ║  réduire la liquidité (`decreaseLiquidity`) ni de faire sortir le NFT    ║
// ║  du contrat une fois déposé (pas de `transferFrom` sortant, pas de       ║
// ║  `selfdestruct`, pas de proxy upgradeable). La liquidité est donc        ║
// ║  vérifiable comme "unruggable" par lecture directe du bytecode/code     ║
// ║  source, pas seulement par engagement déclaratif de l'équipe.           ║
// ║                                                                          ║
// ║  Le owner ne peut QUE :                                                 ║
// ║    - appeler collect() (permissionless de toute façon, voir plus bas)   ║
// ║    - changer feeRecipient (destinataire des frais collectés)            ║
// ║    - renoncer à l'ownership                                             ║
// ║  Le owner NE PEUT PAS retirer la position elle-même, quel que soit son  ║
// ║  pouvoir — cette fonction n'existe simplement pas dans ce contrat.       ║
// ║                                                                          ║
// ║  CHANGELOG 14/08/2026 — passe de correctifs sur le rapport SolidityScan     ║
// ║  du 14/08/2026 (voir RMHT.sol pour le détail complet) :                     ║
// ║    • [FIX] Ownable2 → deux-temps (propose/accept)                 [L003]   ║
// ║    • [FIX] check zero-address explicite sur initialOwner/from     [L002]   ║
// ║                                                                          ║
// ║  TRIAGE 28/08/2026 :                                                     ║
// ║    • [FAUX POSITIF, documenté] collect() sans onlyOwner          [C001]  ║
// ║      Scanner : "Incorrect Access Control" (Critical). collect() est     ║
// ║      volontairement permissionless — n'importe qui peut déclencher      ║
// ║      la collecte (comme hood.fun/Robinlaunch), mais `recipient` est     ║
// ║      TOUJOURS lu depuis `feeRecipient` (state, owner-only via          ║
// ║      setFeeRecipient), jamais depuis msg.sender ni un argument          ║
// ║      d'appel : aucune redirection de fonds n'est possible pour un      ║
// ║      tiers. Vérifié empiriquement : ajouter onlyOwner à collect()       ║
// ║      fait passer le score SolidityScan de 62,27 (1 Critical) à          ║
// ║      96,35 (0 Critical) sans aucun autre changement — confirme que      ║
// ║      C001 vise bien cette fonction. Non appliqué : casserait le         ║
// ║      design voulu (collecte ouverte à tous, destination verrouillée)    ║
// ║      pour fermer un finding qui ne lit pas cette nuance. Classé         ║
// ║      faux positif plutôt que corrigé — même traitement que L004.        ║
// ║                                                                          ║
// ║  ⚠️  NON AUDITÉ — revue indépendante requise avant tout dépôt réel.     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

interface INonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

/// @dev Audit fix (L003 — Use Ownable2Step): same two-step propose/accept
///      pattern as RMHT.sol's Ownable — see the note there for the rationale.
abstract contract Ownable2 {
    address private _owner;
    address private _pendingOwner;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    function owner() public view returns (address) { return _owner; }

    function pendingOwner() public view returns (address) { return _pendingOwner; }

    function renounceOwnership() public onlyOwner {
        delete _pendingOwner;
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /// @notice Step 1/2 — proposes newOwner. Ownership does NOT change yet.
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    /// @notice Step 2/2 — the pending owner confirms and takes ownership.
    function acceptOwnership() public {
        if (msg.sender != _pendingOwner) revert OwnableUnauthorizedAccount(msg.sender);
        delete _pendingOwner;
        emit OwnershipTransferred(_owner, msg.sender);
        _owner = msg.sender;
    }
}

contract RMHTLiquidityCustodian is Ownable2, IERC721Receiver {
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Seule adresse autorisée à déposer la position dans ce
    ///         custodian. Fixée AU DÉPLOIEMENT sur `initialOwner`, immutable.
    /// @dev MàJ 27/08/2026 — remplace un `require(from == owner())`. Deux
    ///      raisons, dans cet ordre :
    ///        1. `owner()` est mutable et peut valoir `address(0)` après
    ///           `renounceOwnership()` : valider un dépôt contre une valeur
    ///           qui peut devenir nulle est un motif fragile (et remonté par
    ///           SolidityScan en "IMPROPER VALIDATION IN REQUIRE/ASSERT").
    ///        2. Même philosophie que `unlockTime` sur RMHTFounderCustodian :
    ///           ce qui peut être figé au déploiement et vérifié publiquement
    ///           dès le premier bloc vaut mieux qu'un état modifiable.
    ///      En pratique aucune différence de comportement : c'est déjà le
    ///      déployeur qui détient et transfère le NFT, dans la même
    ///      transaction de script.
    address public immutable depositor;

    /// @notice tokenId de la position détenue. Fixé une seule fois, à la
    ///         réception du NFT — un seul custodian gère une seule position.
    uint256 public tokenId;
    bool    public positionReceived;

    /// @notice Destinataire des frais collectés. Owner-updatable par défaut —
    ///         cf. discussion : figer cette adresse en dur au déploiement
    ///         (immutable) est possible si vous préférez zéro pouvoir résiduel ;
    ///         demandez la variante si vous la voulez, c'est un simple retrait
    ///         du setter ci-dessous.
    address public feeRecipient;

    event PositionReceived(uint256 indexed tokenId, address indexed from);
    event FeesCollected(uint256 amount0, uint256 amount1, address indexed recipient);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    constructor(address positionManagerAddr, address initialOwner, address initialFeeRecipient) Ownable2(initialOwner) {
        // Audit fix (SolidityScan L002 — Missing zero address validation,
        // instance 1): initialOwner is already checked by Ownable2's own
        // constructor (it reverts before this body runs), but that check lives
        // in a separate contract — made explicit here too so a static scan of
        // this contract's constructor body doesn't read as unguarded.
        require(initialOwner != address(0), "Custodian: Invalid owner");
        require(positionManagerAddr != address(0), "Custodian: Invalid position manager");
        require(initialFeeRecipient != address(0), "Custodian: Invalid fee recipient");
        positionManager = INonfungiblePositionManager(positionManagerAddr);
        feeRecipient = initialFeeRecipient;
        // `initialOwner` est déjà garanti non nul par Ownable2 ET par le
        // require ci-dessus : `depositor` ne peut donc jamais valoir zéro.
        depositor = initialOwner;
    }

    /// @notice Reçoit le NFT de position lors du dépôt initial (safeTransferFrom
    ///         depuis le NonfungiblePositionManager). Un seul dépôt possible.
    function onERC721Received(address /*operator*/, address from, uint256 receivedTokenId, bytes calldata /*data*/)
        external override returns (bytes4)
    {
        require(msg.sender == address(positionManager), "Custodian: Only position manager");
        // ═══════════════════════════════════════════════════════════════════
        //  FIX 27/08/2026 — course au dépôt (« first depositor wins »)
        //
        //  AVANT ce require, N'IMPORTE QUI possédant une position Uniswap v3
        //  (même une position poussière à quelques centimes) pouvait, entre le
        //  déploiement de ce custodian et le dépôt de la VRAIE position par
        //  l'équipe, appeler positionManager.safeTransferFrom(lui, custodian,
        //  sonTokenIdBidon). Les checks présents passaient tous
        //  (msg.sender == positionManager ✓, from != 0 ✓, !positionReceived ✓),
        //  `tokenId` se figeait DÉFINITIVEMENT sur la position bidon, et le
        //  dépôt légitime revertait ensuite avec "Position already set".
        //
        //  Conséquence : custodian brické, à redéployer et re-vérifier. Pas de
        //  perte de fonds (le vrai NFT reste chez l'équipe, son transfert
        //  revert), mais un DoS trivial et quasi gratuit sur l'étape la plus
        //  publique du lancement. La fenêtre est courte dans le script de
        //  déploiement tout-en-un, mais elle devient de plusieurs heures/jours
        //  dès qu'on déploie les contrats un jour et qu'on monte la LP le
        //  lendemain — ce qui est le déroulé normal d'un lancement mainnet.
        //
        //  Note : l'argument « pas de mempool public sur une L2 séquencée »
        //  (utilisé à raison pour retirer l'anti-sandwich le 14/08) NE
        //  s'applique PAS ici : l'attaquant n'a pas besoin de voir une
        //  transaction en attente, il lui suffit de voir le custodian déployé
        //  dans un bloc déjà produit.
        //
        //  Le check d'adresse zéro qui précédait (audit fix L002) a été retiré
        //  car il est désormais PROUVABLEMENT redondant : `depositor` est
        //  immutable et garanti non nul au constructeur, donc
        //  `from == depositor` implique `from != address(0)`.
        // ═══════════════════════════════════════════════════════════════════
        require(from == depositor, "Custodian: Only depositor can deposit position");
        require(!positionReceived, "Custodian: Position already set, one position per custodian");
        tokenId = receivedTokenId;
        positionReceived = true;
        emit PositionReceived(receivedTokenId, from);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Verrou anti-réentrance minimal, sans dépendance externe (le
    ///         reste du contrat évite déjà tout import OpenZeppelin).
    ///         Audit fix (Slither reentrancy-events) : collect() ne modifiait
    ///         aucun état après son appel externe (le risque réel était donc
    ///         nul), mais ce verrou ferme le finding en défense en profondeur.
    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "Custodian: Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    /// @notice Collecte les frais accumulés sur la position et les envoie à
    ///         feeRecipient. Permissionless — n'importe qui peut déclencher la
    ///         collecte (comme hood.fun/Robinlaunch), seule la destination
    ///         (feeRecipient) est fixe/contrôlée par le owner.
    /// @dev Triage 28/08/2026 [C001] : SolidityScan classe l'absence de
    ///      modificateur ici en "Incorrect Access Control" (Critical). Faux
    ///      positif documenté, pas corrigé — voir TRIAGE 28/08/2026 en tête
    ///      de fichier pour le raisonnement complet et la preuve empirique
    ///      (score 62,27→96,35 en ajoutant puis retirant onlyOwner ici).
    function collect() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(positionReceived, "Custodian: No position held");
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: feeRecipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(amount0, amount1, feeRecipient);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Custodian: Invalid recipient");
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Lecture de la liquidité actuelle de la position — doit rester
    ///         strictement égale à la liquidité déposée initialement, pour
    ///         toujours, puisqu'aucune fonction de ce contrat ne peut la
    ///         réduire. Utile pour que n'importe qui vérifie ça on-chain.
    function currentLiquidity() external view returns (uint128 liquidity) {
        require(positionReceived, "Custodian: No position held");
        // slither-disable-next-line unused-return
        // Only `liquidity` is needed from this 12-field tuple.
        (, , , , , , , liquidity, , , , ) = positionManager.positions(tokenId);
    }

    // Volontairement ABSENT de ce contrat, pour que ce soit vérifiable par
    // n'importe qui lisant le code : decreaseLiquidity(), burn(), tout
    // transfert sortant du NFT, tout selfdestruct, tout mécanisme de proxy.
}
