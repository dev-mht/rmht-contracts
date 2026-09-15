// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "./libraries/UniswapV3TWAP.sol";

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║                                                                          ║
// ║  RobinhoodMilestoneHodlToken  —  $RMHT  —  V1.0                         ║
// ║                                                                          ║
// ║  Robinhood Chain (ChainID 4663)                                         ║
// ║  Total Supply : 1,000,000,000 RMHT                                      ║
// ║                                                                          ║
// ║  Fork de MilestoneHodlToken V2.3 (BSC) — changements :                  ║
// ║    • SUPPRIMÉ : blacklist / redirect-to-burn                            ║
// ║    • SUPPRIMÉ : taxes buy/sell (2%/5%)                                  ║
// ║    • SUPPRIMÉ : auto-liquidité + router PancakeSwap                     ║
// ║    • SUPPRIMÉ : flush LP à paliers de prix (spécifique historique V1)   ║
// ║    • SUPPRIMÉ : snapshot V1 hardcodé, wallets marketing/fondateur       ║
// ║    • SUPPRIMÉ : LP progressive 20% par tranches de MCap                 ║
// ║    • GARDÉ    : coffre-fort (vault) à release asymptotique             ║
// ║         → 1,5% du solde restant, tous les 500 000$ de Market Cap        ║
// ║         → 100% de chaque release va aux holders (pas de split autoLP/  ║
// ║           marketing, ces destinations n'existent plus)                  ║
// ║    • REMPLACÉ  : Chainlink Automation/CRE abandonnés (coût + Robinhood  ║
// ║           mainnet non supporté) — palier auto-déclenché via            ║
// ║           pokeMilestone(), permissionless, voir section dédiée         ║
// ║    • ADAPTÉ   : lecture de prix — TWAP Uniswap v3 (fenêtre glissante    ║
// ║           TWAP_WINDOW, cf. UniswapV3TWAP.sol) au lieu du spot           ║
// ║           slot0().sqrtPriceX96, EN PLUS du cooldown 24h existant.       ║
// ║           MàJ 27/08/2026 : la lib officielle Uniswap (OracleLibrary)   ║
// ║           reste figée en Solidity <0.8.0, incompatible avec ce         ║
// ║           contrat — au lieu de l'importer, seules les 2 fonctions      ║
// ║           strictement nécessaires (TickMath.getSqrtRatioAtTick,        ║
// ║           consult) ont été portées en 0.8.36 dans                      ║
// ║           src/libraries/UniswapV3TWAP.sol (constantes magiques         ║
// ║           inchangées, revérifiées contre le code source officiel).     ║
// ║           PRÉREQUIS OPS : la pool doit avoir été dimensionnée avec     ║
// ║           increaseObservationCardinalityNext(>= 1801) AVANT            ║
// ║           setConfig(), qui le vérifie. La lecture de prix est          ║
// ║           FAIL-CLOSED : tant que la pool ne couvre pas les 30 min      ║
// ║           complètes, getRMHTPriceInETH() revert et pokeMilestone()     ║
// ║           est un no-op — aucun palier ne peut se déclencher sur un     ║
// ║           prix insuffisamment moyenné.                                 ║
// ║    • ADAPTÉ   : adresses de feed Chainlink configurables post-deploy,   ║
// ║           PAS hardcodées — conforme à la doc Robinhood : "always read  ║
// ║           addresses from there rather than hardcoding them"            ║
// ║    • ADAPTÉ   : check de l'uptime du séquenceur L2 avant toute lecture  ║
// ║           de prix (recommandation officielle Robinhood Chain)          ║
// ║                                                                          ║
// ║  Tokenomics $RMHT (à finaliser — cf. doc section 4) :                   ║
// ║    • 50% Vault (mécanique ci-dessus)                                    ║
// ║    • ~6,5-6,6% Airdrop (wallet dédié, distribution off-chain ensuite)   ║
// ║    • ~43,4-43,5% Marché (wallet dédié → position LP single-sided)       ║
// ║    Les montants exacts sont des paramètres du constructeur, pas des     ║
// ║    constantes en dur — permet d'ajuster le split 6,5/6,57/6,6% sans     ║
// ║    recompiler le contrat avant déploiement.                            ║
// ║                                                                          ║
// ║  CHANGELOG 14/08/2026 — passe de correctifs sur le rapport SolidityScan     ║
// ║  du 14/08/2026 (score 92.76, 0 Crit, 0 High, 7 Med, 4 Low) :                ║
// ║    • [FIX]      Ownable → Ownable2Step (propose/accept)           [L003]   ║
// ║    • [FIX]      increaseAllowance/decreaseAllowance ajoutées      [M002]   ║
// ║    • [FIX]      getMarketCap : divisions fusionnées en une seule  [M003]   ║
// ║    • [FIX]      milestoneRewardPerToken : précision 1e18 → 1e36   [M003]   ║
// ║    • [FIX]      event PoolTokenOrderSet ajouté dans setConfig()   [L001]   ║
// ║    • [DOCUMENTÉ, pas réécrit] usage de block.number dans l'anti-           ║
// ║      sandwich même-bloc : lecture en équalité de bloc uniquement,          ║
// ║      pas un calcul de durée — voir commentaire dans _update().             ║
// ║      Le rapport SolidityScan n'a détaillé que 3 des 7 instances Med        ║
// ║      (les 2 précédentes + les autres sans emplacement, palier payant) —    ║
// ║      fixes basés sur une analyse manuelle du code.                         ║
// ║                                                                          ║
// ║  CHANGELOG 14/08/2026 (2e passe) — sur RMHT_V2_14_08_1/2 (score 62→92.4,   ║
// ║  après alignement du pragma d'AutomationReceiver.sol) :                    ║
// ║    • [FIX] rescueTokens() : check token.code.length avant le low-level     ║
// ║      call générique (M001 — Account Existence Check For Low Level Calls)  ║
// ║    • [DOCUMENTÉ, pas réécrit] block.number anti-sandwich (M002) — voir     ║
// ║      commentaire dans _update(), inchangé, toujours justifié              ║
// ║    • [DOCUMENTÉ, pas réécrit] approve()/increaseAllowance()/              ║
// ║      decreaseAllowance() (M003, 3 instances) — le scanner flague les 3    ║
// ║      fonctions de gestion d'allowance elles-mêmes ; approve() ne peut     ║
// ║      pas être retiré (obligatoire pour l'interface ERC20), et les deux    ║
// ║      autres SONT le correctif standard contre le front-running — rien à   ║
// ║      corriger de plus sans casser la compatibilité ERC20                  ║
// ║    • [DOCUMENTÉ, pas réécrit] 5 divisions signalées M004 (précision) —    ║
// ║      chacune déjà revue et justifiée individuellement (getMarketCap :     ║
// ║      divisions déjà fusionnées ; les 4 autres dépendent d'un ordre        ║
// ║      d'opérations contraint par la logique métier, voir commentaires      ║
// ║      sur place) — pas de changement supplémentaire sans risque de         ║
// ║      régression sur la comptabilité des rewards/du vault                  ║
// ║                                                                          ║
// ║  CHANGELOG 14/08/2026 (3e passe) — retrait du verrou de lancement       ║
// ║  (launchTime/LAUNCH_DELAY/delayLaunch/isTradingOpen) et du blocage      ║
// ║  anti-sandwich même-bloc (lastReceivedBlock) dans _update() :           ║
// ║    • Décision alignée sur celle déjà actée pour le template Factory     ║
// ║      (meme coins) : ces protections déclenchaient des faux positifs     ║
// ║      honeypot chez les scanners tiers, sans réel bénéfice sur une L2    ║
// ║      séquencée (Robinhood Chain = Arbitrum Orbit/Nitro) — un bot y      ║
// ║      reste plus rapide qu'un humain de toute façon, et le séquenceur    ║
// ║      ordonne déjà les transactions (contrairement à l'ETH L1 natif,     ║
// ║      seule chaîne où le risque de sandwich via mempool public est réel).║
// ║    • Protection MEV/anti-sandwich désormais gérée hors contrat, via RPC ║
// ║      privé (Flashbots Protect/MEV Blocker) côté --broadcast si besoin.  ║
// ║  CHANGELOG 15/08/2026 (4e passe) — airdropWallet retiré de                ║
// ║  isExcludedFromRewards, sur demande explicite : les allocations           ║
// ║  bloquées 1 an dans RMHTAirdropCustodian sont des hodlers long terme et   ║
// ║  doivent accumuler les rewards de palier comme n'importe quel holder.     ║
// ║  marketWallet reste exclu (wallet transitoire, pas un lock long terme).   ║
// ║  Contrepartie côté RMHTAirdropCustodian.sol : nouveau mécanisme           ║
// ║  harvestVaultRewards()/claimReward() pour rapatrier et répartir ces       ║
// ║  rewards au prorata des allocations fixes, sans attendre le déblocage     ║
// ║  du principal — voir ce fichier pour le détail.                          ║
// ║                                                                          ║
// ║  CHANGELOG 28/08/2026 (5e passe) — rôle `feedGovernor` :                  ║
// ║    • [AJOUT] feedGovernor + pendingFeedGovernor, updatePriceFeeds(),      ║
// ║      transferFeedGovernor()/acceptFeedGovernor(),                         ║
// ║      renounceFeedGovernor(). Rôle SÉPARÉ d'Ownable, qui survit à          ║
// ║      renounceOwnership() et ne peut corriger QUE les deux adresses de     ║
// ║      feed Chainlink. Motivation : $MHT V2 sur BSC — Chainlink             ║
// ║      Automation mis en pause, contrat déjà renoncé, ~76% de la supply     ║
// ║      gelée définitivement, faute de tout moyen de migrer. Ici la pool     ║
// ║      Uniswap reste figée pour toujours (lockConfig), seuls les feeds      ║
// ║      restent corrigibles. Périmètre exact du pouvoir résiduel et ses      ║
// ║      limites : voir le bloc @dev sur `feedGovernor` (section STATE) —     ║
// ║      à reprendre tel quel dans la doc publique du protocole.              ║
// ║    • [FIX H001 SolidityScan] `nonReentrant` sur updatePriceFeeds()        ║
// ║      (2 appels externes vers les adresses candidates avant écriture       ║
// ║      d'état).                                                             ║
// ║    • [FIX] _requireSequencerUp() rejette désormais `startedAt == 0`       ║
// ║      (round pas démarré) — sans ça la période de grâce passait            ║
// ║      toujours sur un feed dans cet état.                                  ║
// ║    • [CONSTRUCTEUR] 7 paramètres au lieu de 6 (feedGovernor_ ajouté       ║
// ║      après founderAmount) — scripts de déploiement et tests à jour.       ║
// ║                                                                          ║
// ║  CHANGELOG 29/08/2026 (6e passe) — check séquenceur OPTIONNEL :           ║
// ║    • [MODIF] _requireSequencerUp() ne vérifie plus rien tant que          ║
// ║      sequencerUptimeFeed == address(0). Chainlink a annoncé ne plus       ║
// ║      étendre les L2 Sequencer Uptime Feeds à de nouveaux réseaux :        ║
// ║      Robinhood Chain n'en aura donc JAMAIS. Avec le check rendu           ║
// ║      obligatoire, aucun palier n'aurait jamais pu se déclencher.          ║
// ║      setConfig() et updatePriceFeeds() acceptent désormais                ║
// ║      address(0) comme valeur valide ; feedGovernor pourra activer         ║
// ║      le check plus tard si un feed apparaît un jour.                      ║
// ║                                                                           ║
// ║  MÉTHODOLOGIE DE REVUE (pas d'audit tiers payant) :                     ║
// ║    • 8 outils statiques/dynamiques : Slither, Solhint, Mythril, Foundry ║
// ║      (SMTChecker), Ackee Wake, Echidna, Aderyn, Sūrya                  ║
// ║    • 131 tests Foundry (unitaires + fuzz + invariants sur 128k appels)  ║
// ║    • Déploiement + tests fonctionnels complets sur Robinhood Chain      ║
// ║      testnet (46630), y compris franchissement de plusieurs paliers    ║
// ║      de vault (harvest + claim de rewards vérifiés)                    ║
// ║                                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// ═══════════════════════════════════════════════════════════════════════════
//  IERC20 — OpenZeppelin v5.5.0 style (identique au contrat original)
// ═══════════════════════════════════════════════════════════════════════════
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IERC20Errors {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ERC20 — minimal impl (OZ v5 style) — identique au contrat original
// ═══════════════════════════════════════════════════════════════════════════
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string  private _name;
    string  private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name()        public view virtual returns (string memory) { return _name; }
    function symbol()      public view virtual returns (string memory) { return _symbol; }
    function decimals()    public view virtual returns (uint8)         { return 18; }
    function totalSupply() public view virtual returns (uint256)       { return _totalSupply; }
    function balanceOf(address account) public view virtual returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 value) public virtual returns (bool) {
        _transfer(_msgSender(), to, value);
        return true;
    }

    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) public virtual returns (bool) {
        _approve(_msgSender(), spender, value);
        return true;
    }

    /// @dev Audit fix (M002 — Approve Front-Running Attack): safe alternatives to
    ///      approve() that adjust the allowance by a delta instead of overwriting
    ///      it. Removes the need for the racy "approve(0) then approve(newValue)"
    ///      two-step dance, which otherwise leaves a window where a front-running
    ///      spender could spend both the old and the new allowance. approve()
    ///      itself is kept unchanged (required by the ERC20 standard interface).
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < subtractedValue) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, subtractedValue);
        }
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to   == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
            unchecked { _balances[from] = fromBalance - value; }
        }
        if (to == address(0)) {
            unchecked { _totalSupply -= value; }
        } else {
            unchecked { _balances[to] += value; }
        }
        emit Transfer(from, to, value);
    }

    function _mint(address account, uint256 value) internal {
        if (account == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(address(0), account, value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner   == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        if (emitEvent) emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            unchecked { _approve(owner, spender, currentAllowance - value, false); }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Ownable — simple, renounceable — identique au contrat original
// ═══════════════════════════════════════════════════════════════════════════
/// @dev Audit fix (L003 — Use Ownable2Step): ownership transfer is now a two-step
///      handshake (propose → accept), same pattern as OZ's Ownable2Step, instead
///      of an instant single-call transfer. Protects the vault-unlock powers
///      gated by onlyOwner from being sent to an unreachable or mistyped
///      address — the new owner must actively call acceptOwnership() to
///      complete the transfer. renounceOwnership() is untouched (renouncing has
///      no "new owner" to confirm, so a two-step doesn't apply there).
abstract contract Ownable is Context {
    address private _owner;
    address private _pendingOwner;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(initialOwner);
    }

    modifier onlyOwner() {
        if (owner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        _;
    }

    function owner() public view virtual returns (address) { return _owner; }

    function pendingOwner() public view virtual returns (address) { return _pendingOwner; }

    function renounceOwnership() public virtual onlyOwner {
        delete _pendingOwner;
        _transferOwnership(address(0));
    }

    /// @notice Step 1/2 — proposes newOwner. Ownership does NOT change yet.
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /// @notice Step 2/2 — the pending owner confirms and takes ownership.
    function acceptOwnership() public virtual {
        address sender = _msgSender();
        if (pendingOwner() != sender) revert OwnableUnauthorizedAccount(sender);
        _transferOwnership(sender);
    }

    function _transferOwnership(address newOwner) internal virtual {
        delete _pendingOwner;
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ReentrancyGuard — OZ v5 style — identique au contrat original
// ═══════════════════════════════════════════════════════════════════════════
abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED     = 2;
    uint256 private _status;

    error ReentrancyGuardReentrantCall();

    constructor() { _status = NOT_ENTERED; }

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrancyGuardReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  External interfaces — Chainlink + Uniswap v3 (remplace Chainlink BNB feed
//  + IPancakePair/IPancakeRouter02 du contrat original)
// ═══════════════════════════════════════════════════════════════════════════
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
}

interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24   tick,
        uint16  observationIndex,
        uint16  observationCardinality,
        uint16  observationCardinalityNext,
        uint8   feeProtocol,
        bool    unlocked
    );
}

// ═══════════════════════════════════════════════════════════════════════════
//
//                       RobinhoodMilestoneHodlToken — $RMHT
//
// ═══════════════════════════════════════════════════════════════════════════

/// @title  Robinhood Milestone HODL Token
/// @notice ERC-20 sur Robinhood Chain. Coffre-fort à release asymptotique piloté
///         par le Market Cap (TWAP Uniswap v3 × Chainlink ETH/USD). Pas de taxe,
///         pas de blacklist, pas d'auto-liquidité — la liquidité de marché est
///         déposée manuellement en position Uniswap v3 hors de ce contrat.
/// @dev    NON AUDITÉ. Voir bandeau d'avertissement en tête de fichier.
contract RMHT is
    ERC20,
    Ownable,
    ReentrancyGuard
{
    // ───────────────────────────────────────────────────────────────────────
    //  CONSTANTS — Supply
    // ───────────────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant VAULT_SUPPLY =   500_000_000 * 1e18;  // 50%
    // Les ~50% restants (airdrop + marché) sont des PARAMÈTRES du constructeur,
    // pas des constantes — le split exact (6,5% / 6,57% / 6,6%) se décide au
    // déploiement, sans recompiler. require() ci-dessous garantit la somme.

    // ───────────────────────────────────────────────────────────────────────
    //  CONSTANTS — Vault (mécanique doc section 4 : 1,5% / 500 000$ MCap)
    // ───────────────────────────────────────────────────────────────────────
    uint256 public constant MILESTONE_STEP_USD  = 500_000;  // pas de $500k, exprimé en unités "1 dollar"
    uint256 public constant RELEASE_BPS         = 150;      // 1,5% en BPS
    uint256 public constant BPS_DENOM           = 10_000;
    uint256 public constant MILESTONE_COOLDOWN  = 24 hours; // anti-manipulation, ajustable en discussion si besoin

    /// @notice Audit fix (SolidityScan M003 — Precision loss during division by
    ///         large numbers, instance 2): scaling factor for milestoneRewardPerToken.
    ///         Bumped from 1e18 to 1e36 to shrink the rounding lost each time
    ///         `release` is divided by `eligible` (which can be large, up to
    ///         ~1e27). Safe from overflow: for any holder, balanceOf(holder) is
    ///         structurally <= eligible (eligible only excludes burn/contract/
    ///         pool balances, so every other holder's balance is already counted
    ///         in it) — so balanceOf(account) * delta <= release * REWARD_PRECISION
    ///         per milestone. Even summed across all 19 possible milestones at
    ///         their respective maximum release, the total stays orders of
    ///         magnitude under uint256's ~1.15e77 ceiling.
    uint256 public constant REWARD_PRECISION    = 1e36;

    // ───────────────────────────────────────────────────────────────────────
    //  CONSTANTS — anti-manipulation
    //  MàJ 27/08/2026 : prix désormais lu en TWAP (cf. UniswapV3TWAP.sol),
    //  EN PLUS du cooldown 24h existant — les deux mitigations se cumulent :
    //  le TWAP rend coûteuse une manipulation instantanée (il faut tenir le
    //  prix manipulé sur toute la fenêtre TWAP_WINDOW, pas juste au moment de
    //  la lecture), le cooldown 24h protège contre une manipulation multi-
    //  blocs qui viserait à déclencher un milestone prématurément. Les
    //  chemins protégés par ce cooldown restent exposés entre deux
    //  milestones — à documenter clairement en public.
    // ───────────────────────────────────────────────────────────────────────
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @notice Fenêtre TWAP cible pour la lecture de prix (cf.
    ///         getRMHTPriceInETH). 30 min = compromis standard entre
    ///         résistance à la manipulation (plus long = plus cher à
    ///         manipuler) et réactivité (plus long = latence plus grande à
    ///         refléter un vrai mouvement de marché). À RE-VALIDER contre la
    ///         profondeur/liquidité réelle de la pool RMHT/WETH avant
    ///         mainnet — sur une pool peu liquide, une fenêtre plus longue
    ///         peut être préférable.
    ///
    ///         FIX 27/08/2026 (fail-closed) : cette fenêtre n'est JAMAIS
    ///         raccourcie automatiquement. La première version de ce
    ///         changement plafonnait la fenêtre demandée à l'historique
    ///         réellement disponible (`window = min(TWAP_WINDOW,
    ///         oldestAvailable)`) pour ne pas revert sur une pool jeune —
    ///         mais ce repli ne « réduisait » pas la protection, il
    ///         l'ANNULAIT : avec observationCardinality == 1 (défaut d'une
    ///         pool Uniswap v3 fraîchement créée), la plus ancienne
    ///         observation est celle du dernier swap, donc la fenêtre
    ///         retombait à l'écart entre deux blocs (~1 s sur une L2) et le
    ///         « TWAP » redevenait EXACTEMENT le prix spot. Un attaquant
    ///         pompait le prix au bloc N puis appelait pokeMilestone() au
    ///         bloc N+1, sans jamais avoir à tenir le prix. Le contrat
    ///         refuse désormais de produire un prix tant que la pool ne
    ///         couvre pas la fenêtre entière (cf. isTwapReady()).
    uint32 public constant TWAP_WINDOW = 1800; // 30 minutes

    /// @notice Cardinalité d'observations minimale exigée de la pool par
    ///         setConfig() (sur `observationCardinalityNext`, la valeur que
    ///         `increaseObservationCardinalityNext()` fixe immédiatement —
    ///         `observationCardinality` elle-même ne rattrape ce plafond que
    ///         progressivement, au fil des swaps).
    ///
    ///         Pourquoi TWAP_WINDOW + 1 et pas une valeur symbolique : une
    ///         pool Uniswap v3 écrit AU PLUS une observation par seconde
    ///         (les observations sont indexées par `block.timestamp`). Un
    ///         ring buffer de N slots ne garantit donc que N-1 secondes
    ///         d'historique dans le pire cas — celui d'un attaquant qui
    ///         swappe à chaque seconde pour faire tourner le buffer et
    ///         maintenir l'historique en dessous de TWAP_WINDOW. Sans cette
    ///         marge, ce spam suffirait à bloquer indéfiniment
    ///         getRMHTPriceInETH() (donc pokeMilestone(), donc toute
    ///         libération du vault) : un DoS bon marché sur ~50% de la supply.
    ///
    ///         Coût opérationnel : increaseObservationCardinalityNext(1801)
    ///         paie ~1801 SSTORE d'initialisation. À faire en PLUSIEURS
    ///         appels successifs (ex. 400, 900, 1400, 1801) pour rester sous
    ///         la limite de gas par transaction — c'est un coût unique, à
    ///         payer AVANT setConfig().
    uint16 public constant MIN_OBSERVATION_CARDINALITY = uint16(TWAP_WINDOW + 1); // 1801

    /// @notice Fraîcheur max acceptée pour le feed ETH/USD avant de considérer
    ///         le prix périmé (audit fix — Slither unused-return sur `updatedAt`).
    ///
    ///         MàJ 28/08/2026 : 1 heure → 26 heures. La valeur d'origine
    ///         reposait sur le heartbeat du feed ETH/USD d'Ethereum mainnet
    ///         (1h) ; ce contrat ne tourne pas là. Le feed ETH/USD réel de
    ///         Robinhood Chain Mainnet
    ///         (0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, Standard Proxy,
    ///         8 décimales) annonce un heartbeat de **86 400 s = 24 heures**
    ///         et un seuil de déviation de 0,5%. Vérifié empiriquement le
    ///         28/08/2026 : `latestRoundData()` renvoyait un `updatedAt`
    ///         vieux d'environ 1 h 40 — donc avec l'ancienne constante,
    ///         `getETHPriceUSD()` aurait REVERT en permanence sur
    ///         "RMHT: ETH price feed stale", et `pokeMilestone()` n'aurait
    ///         jamais pu déclencher le moindre palier. Autrement dit :
    ///         garder 1 h aurait gelé ~50% de la supply, exactement le
    ///         scénario que tout le reste du contrat cherche à éviter.
    ///
    ///         POURQUOI 26 h ET PAS 24 h PILE : un seuil égal au heartbeat
    ///         rejette une mise à jour arrivée avec la moindre gigue (un
    ///         heartbeat Chainlink est un plafond visé, pas une horloge
    ///         atomique). 2 h de marge suffisent à absorber ça sans rendre
    ///         le check décoratif.
    ///
    ///         CE QU'ON PERD, ET POURQUOI C'EST ACCEPTABLE ICI : le prix
    ///         ETH/USD servant à `getMarketCap()` peut désormais avoir
    ///         jusqu'à 26 h. C'est une contrainte du feed, pas un choix —
    ///         aucun seuil sous 24 h n'est utilisable sans casser le
    ///         protocole. L'exposition reste bornée : (1) en pratique le
    ///         seuil de déviation de 0,5% déclenche des mises à jour
    ///         bien plus fréquentes que le heartbeat ; (2) la jambe
    ///         RMHT/ETH, elle, vient d'un TWAP 30 min et n'est pas
    ///         concernée ; (3) un palier exige 3 confirmations espacées
    ///         d'au moins 10 min PLUS un cooldown de 24 h, donc un prix ETH
    ///         figé ne peut pas être exploité en rafale. Le risque résiduel
    ///         est qu'un palier se déclenche (ou pas) sur un ETH/USD daté —
    ///         il décale le calendrier de libération, il ne détourne aucun
    ///         fonds.
    ///
    ///         À RE-VÉRIFIER si le feed change : `updatePriceFeeds()` permet
    ///         de migrer d'adresse, PAS de modifier cette constante, qui est
    ///         figée au déploiement. Un futur feed au heartbeat plus long que
    ///         26 h imposerait un redéploiement.
    uint256 public constant ETH_USD_HEARTBEAT = 26 hours;

    // ───────────────────────────────────────────────────────────────────────
    //  CONSTANTS — Adresse fixe
    // ───────────────────────────────────────────────────────────────────────
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ───────────────────────────────────────────────────────────────────────
    //  IMMUTABLES — wallets de répartition (fixés au déploiement)
    // ───────────────────────────────────────────────────────────────────────
    address public immutable airdropWallet;
    address public immutable marketWallet;
    /// @notice RMHTFounderCustodian dédié — 22/08/2026 : l'allocation fondateur
    ///         (50M) est sortie du pool airdropWallet et reçoit son propre mint
    ///         direct, pour un vesting par tranches indépendant (voir ce contrat).
    address public immutable founderWallet;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — configuration post-deploy (settable UNIQUEMENT avant renounce)
    // ───────────────────────────────────────────────────────────────────────
    address public uniswapV3Pool;                       // pool RMHT/WETH — settable une fois, puis figée pour toujours
    AggregatorV3Interface public ethUsdFeed;             // PAS hardcodé — cf. doc Robinhood Chain
    AggregatorV3Interface public sequencerUptimeFeed;    // PAS hardcodé
    bool    public poolIsToken0;                         // cache : RMHT est-il token0 de la pool ?
    bool    public configLocked;                         // true une fois la pool figée (n'affecte plus les feeds, voir feedGovernor)

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — feedGovernor (AJOUT 28/08/2026), survit à renounceOwnership()
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Adresse autorisée à corriger ethUsdFeed/sequencerUptimeFeed via
    ///         updatePriceFeeds(), à tout moment, SANS délai et SANS dépendre
    ///         de `owner`/`configLocked`. Volontairement séparé du système
    ///         Ownable : `owner` peut être (et est censé être) renoncé pour
    ///         tout le reste (rescueTokens, excludeFromRewards, la pool...),
    ///         mais cette capacité-là ne doit jamais pouvoir être perdue —
    ///         leçon tirée de $MHT V2 sur BSC, où Chainlink Automation a été
    ///         mis en pause et le contrat renoncé n'avait plus aucun moyen de
    ///         s'adapter (~76% de la supply gelée définitivement).
    /// @dev PAS de timelock ici, volontairement : le risque qu'on couvre
    ///      n'est pas "un gouverneur malveillant" mais "Chainlink change
    ///      quelque chose et plus personne ne peut réagir". Un délai
    ///      obligatoire aurait réintroduit exactement ce risque-là. Le
    ///      garde-fou est ailleurs : vérifications de sanité de la nouvelle
    ///      adresse avant acceptation, événement à chaque changement, chemin
    ///      de transfert en deux étapes contre l'erreur de frappe, et
    ///      renounceFeedGovernor() pour éteindre définitivement le rôle une
    ///      fois qu'il n'est plus utile.
    ///
    ///      PÉRIMÈTRE EXACT DU POUVOIR RÉSIDUEL — à documenter publiquement,
    ///      ne pas le minimiser :
    ///        • Ce que feedGovernor NE PEUT PAS faire : toucher la pool
    ///          Uniswap (figée par lockConfig()), déplacer des tokens,
    ///          appeler rescueTokens()/excludeFromRewards(), changer une
    ///          allocation, ni s'attribuer quoi que ce soit — aucune de ces
    ///          fonctions ne passe par ce rôle, et le vault ne verse jamais à
    ///          une adresse choisie, seulement au prorata de tous les
    ///          détenteurs éligibles.
    ///        • Ce qu'il PEUT faire : remplacer le feed ETH/USD par un
    ///          contrat qui répond à l'interface Chainlink avec un prix
    ///          positif arbitraire. Les sanity checks d'updatePriceFeeds()
    ///          (decimals() + answer > 0) attrapent une adresse collée de
    ///          travers, PAS un feed hostile écrit pour passer. Comme
    ///          getMarketCap() multiplie par ce prix, un tel feed permettrait
    ///          de faire franchir les paliers à volonté — donc d'ACCÉLÉRER le
    ///          calendrier de libération du vault (toujours au prorata de
    ///          tous les holders, cooldown 24h et 3 confirmations espacées de
    ///          10 min toujours appliqués), pas de le détourner.
    ///      Autrement dit : ce rôle ne peut pas voler le vault, il peut en
    ///      changer le rythme. C'est le prix assumé de pouvoir migrer
    ///      proprement si Chainlink modifie ses feeds — et c'est
    ///      exactement pourquoi il a vocation à passer à un multisig
    ///      (transferFeedGovernor) puis à être éteint (renounceFeedGovernor)
    ///      quand la question est réglée.
    address public feedGovernor;
    /// @notice Destinataire proposé d'un transfert de feedGovernor, en attente
    ///         d'acceptation (protège contre une adresse mal copiée-collée).
    address public pendingFeedGovernor;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — Vault / tracking
    // ───────────────────────────────────────────────────────────────────────
    uint256 public vaultBalance;
    uint256 public nextMilestoneUSD;      // en "unités dollar" (pas de decimals) — ex. 500_000
    uint256 public milestonesReached;
    uint256 public lastMilestoneTimestamp;
    uint256 public milestoneRewardPerToken;  // scaled REWARD_PRECISION (1e36) — see audit note above

    /// @notice Somme des rewards de palier déjà "libérés" (sortis de vaultBalance
    ///         via _executeMilestone) mais pas encore effectivement transférés
    ///         hors du contrat (i.e. pas encore réclamés via claimRewards()).
    ///         Incrémenté à chaque palier, décrémenté à chaque claim. Sert à
    ///         protéger ces fonds dans rescueTokens() : tant qu'ils n'ont pas
    ///         été réclamés par leurs ayants droit, ils ne sont PAS "en trop"
    ///         sur le solde du contrat, même si vaultBalance a déjà baissé.
    uint256 public unclaimedReleased;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public pendingRewards;
    mapping(address => bool)    public isExcludedFromRewards;

    // ───────────────────────────────────────────────────────────────────────
    //  STATE — palier auto-déclenché (remplace Chainlink Automation/CRE)
    // ───────────────────────────────────────────────────────────────────────
    /// @notice Fenêtre maximale, depuis l'armement, pour réunir toutes les
    ///         confirmations requises. Si ce délai est dépassé sans que la
    ///         séquence soit complète, désarmement automatique (filet de
    ///         sécurité) — se réarmera au prochain re-franchissement.
    uint256 public constant MILESTONE_CONFIRM_WINDOW = 2 hours;

    /// @notice Écart minimum exigé entre deux confirmations successives.
    ///         Empêche de "spammer" plusieurs confirmations dans la même
    ///         transaction ou dans le même bloc pour accélérer artificiellement
    ///         la séquence.
    uint256 public constant MILESTONE_CONFIRM_INTERVAL = 10 minutes;

    /// @notice Nombre de confirmations consécutives (chacune espacée d'au
    ///         moins MILESTONE_CONFIRM_INTERVAL, chacune devant retrouver le
    ///         prix au-dessus du seuil) nécessaires avant l'ouverture réelle
    ///         du palier. Rend une manipulation de prix économiquement
    ///         dissuasive : il faut la tenir à plusieurs reprises, sur une
    ///         fenêtre large, pas juste une fois.
    uint8 public constant MILESTONE_CONFIRMATIONS_REQUIRED = 3;

    bool    public milestoneArmed;
    uint256 public milestoneArmedAt;
    uint256 public milestoneArmedMcap;
    uint8   public milestoneConfirmations;
    uint256 public milestoneLastConfirmedAt;

    // ───────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ───────────────────────────────────────────────────────────────────────
    event MilestoneTriggered(uint256 indexed number, uint256 mcapAtTrigger, uint256 released);
    event RewardClaimed(address indexed user, uint256 amount);
    event MilestoneArmed(uint256 mcapAtArm, uint256 windowExpiresAt);
    event MilestoneConfirmationRecorded(uint8 confirmations, uint8 required, uint256 mcap);
    event MilestoneDisarmed(uint256 mcapAtCheck);
    event RewardExclusionUpdated(address indexed account, bool status);
    event TokensRescued(address indexed token, uint256 amount);
    event ConfigSet(address indexed pool, address ethUsdFeed_, address sequencerFeed_);
    /// @notice Audit fix (SolidityScan L001 — Missing events): poolIsToken0 is a
    ///         state change computed inside setConfig() that wasn't captured by
    ///         any emitted event (ConfigSet only carries the addresses). Anyone
    ///         indexing which side of the pool is RMHT vs WETH needs this.
    event PoolTokenOrderSet(bool poolIsToken0);
    event ConfigLocked();
    /// @notice Émis à chaque correction des flux Chainlink via updatePriceFeeds()
    ///         — voir feedGovernor. Reste possible après renounceOwnership().
    event PriceFeedsUpdated(address indexed ethUsdFeed_, address indexed sequencerFeed_);
    /// @notice Émis quand une proposition de transfert de feedGovernor démarre.
    event FeedGovernorTransferStarted(address indexed previousGovernor, address indexed newGovernor);
    /// @notice Émis quand un transfert de feedGovernor est finalisé (accepté).
    event FeedGovernorTransferred(address indexed previousGovernor, address indexed newGovernor);

    // ───────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ───────────────────────────────────────────────────────────────────────
    /// @param airdropWalletAddr  Wallet recevant la poche airdrop communauté (distribution off-chain ensuite)
    /// @param airdropAmount      Montant exact alloué à l'airdrop communauté (hors fondateur, voir founderAmount)
    /// @param marketWalletAddr   Wallet recevant la poche "marché" (→ position LP single-sided)
    /// @param marketAmount       Montant exact alloué au marché
    /// @param founderWalletAddr  RMHTFounderCustodian dédié (vesting par tranches, voir ce contrat)
    /// @param founderAmount      Montant exact alloué au fondateur (ex. 50 000 000)
    /// @param feedGovernor_      AJOUT 28/08/2026 — adresse initiale autorisée à corriger
    ///                           les flux Chainlink après déploiement, y compris après
    ///                           renounceOwnership() (voir feedGovernor). Typiquement
    ///                           l'adresse du déployeur au lancement, transférable
    ///                           ensuite (ex. vers un multisig) via transferFeedGovernor().
    constructor(
        address airdropWalletAddr,
        uint256 airdropAmount,
        address marketWalletAddr,
        uint256 marketAmount,
        address founderWalletAddr,
        uint256 founderAmount,
        address feedGovernor_
    )
        ERC20("Robinhood Milestone HODL Token", "RMHT")
        Ownable(msg.sender)
    {
        require(airdropWalletAddr != address(0), "RMHT: Invalid airdrop wallet");
        require(marketWalletAddr  != address(0), "RMHT: Invalid market wallet");
        require(founderWalletAddr != address(0), "RMHT: Invalid founder wallet");
        require(feedGovernor_     != address(0), "RMHT: Invalid feed governor");
        require(
            VAULT_SUPPLY + airdropAmount + marketAmount + founderAmount == TOTAL_SUPPLY,
            "RMHT: Allocation must sum to TOTAL_SUPPLY"
        );

        airdropWallet = airdropWalletAddr;
        marketWallet  = marketWalletAddr;
        founderWallet = founderWalletAddr;
        feedGovernor  = feedGovernor_;
        emit FeedGovernorTransferred(address(0), feedGovernor_);

        vaultBalance     = VAULT_SUPPLY;
        nextMilestoneUSD = MILESTONE_STEP_USD;   // premier palier = $500k

        isExcludedFromRewards[address(this)]     = true;
        isExcludedFromRewards[BURN_ADDRESS]      = true;
        // marketWallet reste exclu : c'est un wallet transitoire (liquidité/marché),
        // pas un lock long terme — ses tokens sortent rapidement vers la pool, qui
        // est elle-même déjà exclue via _getEligibleSupply().
        //
        // airdropWallet (RMHTAirdropCustodian) N'EST PLUS exclu (retiré le
        // 15/08/2026, sur demande explicite) : les allocations qui y restent
        // bloquées pendant l'année de lock sont des hodlers long terme à part
        // entière et doivent accumuler les rewards de palier comme n'importe
        // quel autre holder. RMHTAirdropCustodian.sol a son propre mécanisme
        // (harvestVaultRewards() / claimReward()) pour rapatrier ces rewards
        // depuis son solde et les répartir au prorata des allocations fixes,
        // sans attendre le déblocage du principal — voir ce fichier.
        isExcludedFromRewards[marketWalletAddr]  = true;
        //
        // founderWallet (RMHTFounderCustodian) N'EST PAS exclu, par symétrie avec
        // airdropWallet (22/08/2026) : c'est le même hodler long terme qu'avant
        // la séparation des deux custodians, il continue d'accumuler les rewards
        // de palier comme tout autre holder tant que son solde reste bloqué ici.
        // MàJ 28/08/2026 : RMHTFounderCustodian.sol a désormais lui aussi son
        // mécanisme harvestVaultRewards()/claimReward() (ajouté sur le même
        // modèle que RMHTAirdropCustodian.sol) — ces rewards sont réclamables
        // par le fondateur à tout moment, indépendamment du verrou d'un an.

        _mint(address(this),      VAULT_SUPPLY);
        _mint(airdropWalletAddr,  airdropAmount);
        _mint(marketWalletAddr,   marketAmount);
        _mint(founderWalletAddr,  founderAmount);

        require(balanceOf(address(this)) == vaultBalance, "RMHT: Allocation mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CONFIGURATION — appelé UNE FOIS après deploy, avant renounceOwnership()
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Renseigne la pool Uniswap v3 et les feeds Chainlink. À appeler une
    ///         fois la pool créée et les fees Chainlink identifiées sur l'explorer
    ///         Robinhood Chain (NE PAS hardcoder ces adresses dans le code —
    ///         cf. docs.robinhood.com/chain/oracles-and-price-feeds).
    /// @dev AJOUT 28/08/2026 : ceci ne fixe que la valeur INITIALE des deux
    ///      feeds. La pool, elle, est définitivement figée une fois
    ///      lockConfig() + renounceOwnership() passés (voir plus bas) — mais
    ///      les feeds restent corrigibles ensuite, sans limite de temps, via
    ///      updatePriceFeeds() (feedGovernor, complètement séparé de `owner`).
    function setConfig(
        address pool,
        address ethUsdFeedAddr,
        address sequencerFeedAddr
    ) external onlyOwner {
        require(!configLocked,              "RMHT: Config already locked");
        require(pool             != address(0), "RMHT: Invalid pool");
        require(ethUsdFeedAddr   != address(0), "RMHT: Invalid ETH/USD feed");
        // AJOUT 29/08/2026 : `sequencerFeedAddr == address(0)` est une valeur
        // VALIDE et signifie "check séquenceur désactivé". Chainlink a
        // officiellement arrêté d'étendre ses L2 Sequencer Uptime Feeds à de
        // nouveaux réseaux ; Robinhood Chain n'en aura donc jamais. Exiger un
        // feed ici reviendrait à rendre getETHPriceUSD() impossible à
        // satisfaire et à geler définitivement tous les paliers. Le jour où
        // une solution apparaît, feedGovernor l'active via updatePriceFeeds()
        // sans redéployer. Voir _requireSequencerUp().

        uniswapV3Pool      = pool;
        ethUsdFeed         = AggregatorV3Interface(ethUsdFeedAddr);
        sequencerUptimeFeed = AggregatorV3Interface(sequencerFeedAddr);

        // FIX 27/08/2026 : la pool DOIT déjà avoir été dimensionnée pour
        // stocker assez d'observations avant d'être branchée ici, sinon
        // getRMHTPriceInETH() resterait durablement en revert (fail-closed)
        // et aucun palier ne pourrait jamais se déclencher. On vérifie
        // `observationCardinalityNext` et pas `observationCardinality` :
        // c'est la valeur qu'increaseObservationCardinalityNext() fixe
        // immédiatement, la seconde ne rattrapant la première qu'au fil des
        // swaps. Ce require transforme un oubli d'étape ops (silencieux et
        // dangereux) en échec bruyant au moment de la configuration.
        (, , , , uint16 observationCardinalityNext, , ) = IUniswapV3PoolMinimal(pool).slot0();
        require(
            observationCardinalityNext >= MIN_OBSERVATION_CARDINALITY,
            "RMHT: Pool observation cardinality too low"
        );

        address token0 = IUniswapV3PoolMinimal(pool).token0();
        poolIsToken0 = (token0 == address(this));
        emit PoolTokenOrderSet(poolIsToken0);

        isExcludedFromRewards[pool] = true;
        emit RewardExclusionUpdated(pool, true);
        emit ConfigSet(pool, ethUsdFeedAddr, sequencerFeedAddr);
    }

    /// @notice Verrouille la config (empêche tout changement futur de pool/feed
    ///         par l'owner). Optionnel mais recommandé avant renounce pour que
    ///         la communauté n'ait pas à faire confiance à "l'owner ne changera
    ///         pas la pool" — le renounce le rend de toute façon impossible,
    ///         ce verrou est une garantie supplémentaire explicite avant ça.
    function lockConfig() external onlyOwner {
        require(uniswapV3Pool != address(0), "RMHT: Set config first");
        configLocked = true;
        emit ConfigLocked();
    }

    /// @notice Override renounceOwnership — bloque tant que la config n'est pas
    ///         figée. Sans ça, ~50% de la supply (le vault) resterait
    ///         définitivement gelé car aucune fonction ne pourrait plus jamais
    ///         configurer la pool/les feeds nécessaires au déclenchement.
    ///         (Plus de dépendance à un registry externe — le palier
    ///         se déclenche désormais lui-même via pokeMilestone().)
    function renounceOwnership() public override onlyOwner {
        require(configLocked, "RMHT: Lock config first");
        super.renounceOwnership();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FEED GOVERNOR (AJOUT 28/08/2026) — corrige les flux Chainlink à tout
    //  moment, y compris après renounceOwnership(). Totalement indépendant de
    //  `owner`/`configLocked` : ce système ne bloque QUE la pool (voir
    //  setConfig()/lockConfig() plus haut), jamais les feeds. Aucun délai —
    //  voir la justification sur `feedGovernor` dans la section STATE.
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyFeedGovernor() {
        require(msg.sender == feedGovernor, "RMHT: Not feed governor");
        _;
    }

    /// @notice Corrige ethUsdFeed/sequencerUptimeFeed. Callable par
    ///         feedGovernor uniquement, à tout moment (avant ou après
    ///         configLocked, avant ou après renounceOwnership()).
    /// @dev Garde-fous qui ne coûtent rien en réactivité (pas de délai) :
    ///      chaque nouvelle adresse doit être un contrat qui répond
    ///      correctement à l'interface Chainlink utilisée ailleurs dans ce
    ///      contrat (decimals() + latestRoundData() avec un prix positif) —
    ///      attrape une adresse mal collée immédiatement plutôt qu'au
    ///      prochain pokeMilestone(). Ne touche ni la pool, ni configLocked,
    ///      ni aucune autre fonction onlyOwner — cette capacité est
    ///      strictement limitée aux deux adresses de feed.
    ///      nonReentrant ajouté le 28/08/2026 (SolidityScan H001) : cette
    ///      fonction fait 2 appels externes (vers les adresses candidates,
    ///      fournies par feedGovernor donc non fixes par nature) avant
    ///      d'écrire ethUsdFeed/sequencerUptimeFeed — même famille que le
    ///      reste du protocole, verrouillée par cohérence même si
    ///      feedGovernor est un rôle de confiance, pas une entrée publique.
    ///      MAJ 29/08/2026 (L003 SolidityScan, "nonReentrant modifier
    ///      placement") : `nonReentrant` est declare EN PREMIER, avant
    ///      `onlyFeedGovernor`, pour que le verrou de reentrance soit pose
    ///      avant l'execution de tout autre modificateur. Sans consequence
    ///      pratique ici (onlyFeedGovernor ne fait qu'un test sur msg.sender,
    ///      aucun appel externe), mais aligne cette fonction sur toutes les
    ///      autres du protocole (rescueTokens, rescueEth, claim...), qui
    ///      respectaient deja cet ordre.
    function updatePriceFeeds(address newEthUsdFeedAddr, address newSequencerFeedAddr)
        external
        nonReentrant
        onlyFeedGovernor
    {
        require(newEthUsdFeedAddr    != address(0), "RMHT: Invalid ETH/USD feed");
        require(newEthUsdFeedAddr.code.length    > 0, "RMHT: ETH/USD feed not a contract");

        // AJOUT 29/08/2026 : address(0) est une valeur VALIDE pour le feed
        // séquenceur et signifie "check désactivé" (voir setConfig() et
        // _requireSequencerUp()). C'est le seul moyen d'activer le check le
        // jour où un feed existera pour Robinhood Chain, et symétriquement de
        // le rouvrir si ce feed devait être déprécié plus tard : refuser le
        // retour à zéro rejouerait exactement le scénario $MHT V2 (oracle
        // cassé, supply gelée à vie). Les contrôles d'interface ne
        // s'appliquent donc qu'à une adresse non nulle.
        if (newSequencerFeedAddr != address(0)) {
            require(newSequencerFeedAddr.code.length > 0, "RMHT: Sequencer feed not a contract");
        }

        // Sanity check : le nouveau feed ETH/USD doit répondre à l'interface
        // attendue avec une donnée plausible (même check qu'utilisé en
        // production dans getETHPriceUSD() : prix strictement positif).
        AggregatorV3Interface(newEthUsdFeedAddr).decimals();
        (, int256 ethUsdAnswer, , , ) = AggregatorV3Interface(newEthUsdFeedAddr).latestRoundData();
        require(ethUsdAnswer > 0, "RMHT: ETH/USD feed sanity check failed");

        // Le feed séquenceur suit une convention Chainlink différente
        // (answer == 0 signifie "up", pas un prix) — on vérifie seulement
        // qu'il répond, sans contrainte sur la valeur retournée.
        if (newSequencerFeedAddr != address(0)) {
            AggregatorV3Interface(newSequencerFeedAddr).decimals();
            AggregatorV3Interface(newSequencerFeedAddr).latestRoundData();
        }

        ethUsdFeed          = AggregatorV3Interface(newEthUsdFeedAddr);
        sequencerUptimeFeed = AggregatorV3Interface(newSequencerFeedAddr);

        emit PriceFeedsUpdated(newEthUsdFeedAddr, newSequencerFeedAddr);
    }

    /// @notice Étape 1/2 d'un transfert de feedGovernor (ex. vers un multisig
    ///         plus tard, sans redéployer RMHT.sol). Protège contre une
    ///         adresse mal copiée-collée : la nouvelle adresse doit accepter
    ///         explicitement via acceptFeedGovernor() avant que le transfert
    ///         ne prenne effet — même logique que Ownable2Step, appliquée ici
    ///         à un rôle qui ne dépend pas d'Ownable.
    function transferFeedGovernor(address newFeedGovernor) external onlyFeedGovernor {
        require(newFeedGovernor != address(0), "RMHT: Invalid feed governor");
        pendingFeedGovernor = newFeedGovernor;
        emit FeedGovernorTransferStarted(feedGovernor, newFeedGovernor);
    }

    /// @notice Étape 2/2 — finalise le transfert. Doit être appelée par
    ///         `pendingFeedGovernor` lui-même.
    function acceptFeedGovernor() external {
        require(msg.sender == pendingFeedGovernor, "RMHT: Not pending feed governor");
        address previous = feedGovernor;
        feedGovernor = msg.sender;
        delete pendingFeedGovernor;
        emit FeedGovernorTransferred(previous, msg.sender);
    }

    /// @notice Éteint DÉFINITIVEMENT le rôle feedGovernor : plus personne ne
    ///         pourra jamais appeler updatePriceFeeds(). À faire le jour où
    ///         les feeds sont considérés comme définitivement stables — c'est
    ///         le seul moyen de ramener le contrat à un état 100% sans
    ///         pouvoir résiduel, après renounceOwnership().
    /// @dev AJOUT 28/08/2026. Symétrique de renounceOwnership() côté Ownable,
    ///      avec le même compromis assumé : irréversible, et si Chainlink
    ///      casse un feed APRÈS cet appel, le protocole se retrouve
    ///      exactement dans la situation de $MHT V2 sur BSC (vault
    ///      définitivement inatteignable, cf. la note sur `feedGovernor`).
    ///      Ne l'appeler qu'en connaissance de cause. Volontairement PAS en
    ///      deux étapes : il n'y a pas de destinataire à confirmer, et un
    ///      pendingFeedGovernor en attente est effacé au passage pour qu'un
    ///      transfert commencé plus tôt ne puisse pas ressusciter le rôle.
    function renounceFeedGovernor() external onlyFeedGovernor {
        address previous = feedGovernor;
        delete pendingFeedGovernor;
        feedGovernor = address(0);
        emit FeedGovernorTransferred(previous, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PRIX — TWAP Uniswap v3 + Chainlink ETH/USD + check séquenceur
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Vérifie que le séquenceur L2 est up et la donnée pas périmée.
    ///         [Recommandation officielle Robinhood Chain — cf. doc]
    function _requireSequencerUp() internal view {
        // AJOUT 29/08/2026 — CHECK OPTIONNEL, ET POURQUOI.
        // Chainlink ne publie pas de L2 Sequencer Uptime Feed pour Robinhood
        // Chain, et n'en publiera jamais : la page
        // docs.chain.link/data-feeds/l2-sequencer-feeds porte un avis de
        // disponibilité explicite — "Chainlink is no longer expanding L2
        // Sequencer Uptime Feeds to additional networks". Le feed d'Arbitrum
        // One n'est pas un substitut : il est déployé sur la chain 42161 et
        // surveille le séquenceur d'Arbitrum One, pas celui de Robinhood
        // Chain, qui est une Orbit avec son propre séquenceur.
        // Or ce check est sur le chemin critique de CHAQUE lecture de prix :
        // le rendre obligatoire aurait fait revert getETHPriceUSD() à vie et
        // gelé définitivement tous les paliers (≈ 50% de la supply), soit
        // exactement le scénario $MHT V2 sur BSC.
        // Choix retenu : le check est INACTIF tant qu'aucun feed n'est
        // renseigné, et s'active de lui-même dès que feedGovernor en fournit
        // un via updatePriceFeeds(). Aucune ligne à changer ce jour-là.
        // Ce qui reste comme protection en attendant : le contrôle de
        // fraîcheur d'ETH_USD_HEARTBEAT dans getETHPriceUSD() et le TWAP
        // Uniswap côté prix RMHT. C'est plus faible qu'un vrai feed
        // séquenceur — c'est assumé, l'alternative étant un protocole mort.
        if (address(sequencerUptimeFeed) == address(0)) return;

        (uint80 roundId, int256 status, uint256 startedAt, , uint80 answeredInRound) =
            sequencerUptimeFeed.latestRoundData();
        require(status == 0, "RMHT: Sequencer down");
        // FIX 28/08/2026 : `startedAt == 0` signifie "round pas encore
        // démarré" côté Chainlink (cas documenté juste après le déploiement
        // d'un feed séquenceur, ou sur un feed mal initialisé). Sans ce
        // check, `block.timestamp - 0` vaut le timestamp courant, donc la
        // vérification de période de grâce ci-dessous passait TOUJOURS sur
        // un feed dans cet état — exactement la situation qu'elle est censée
        // attraper. Aligné sur l'implémentation de référence Chainlink
        // (docs.chain.link, "L2 Sequencer Uptime Feeds").
        require(startedAt != 0, "RMHT: Sequencer round not started");
        require(block.timestamp - startedAt > SEQUENCER_GRACE_PERIOD, "RMHT: Grace period not over");
        // Audit fix (Slither unused-return): reject a stale round instead of
        // silently discarding roundId/answeredInRound.
        require(answeredInRound >= roundId, "RMHT: Stale sequencer round");
    }

    /// @notice Prix ETH/USD Chainlink, avec check de fraîcheur basique.
    function getETHPriceUSD() public view returns (uint256 price, uint8 feedDecimals) {
        _requireSequencerUp();
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            ethUsdFeed.latestRoundData();
        // NOT changed to "!= 0" (gas finding G003): `answer` is int256 here,
        // and Chainlink can return a negative price on feed malfunction —
        // "> 0" correctly rejects that; "!= 0" would wrongly accept it.
        require(answer > 0,      "RMHT: Invalid ETH price");
        require(updatedAt != 0,  "RMHT: Round not complete"); // gas (G003): equivalent for uint256
        // Audit fix (Slither unused-return): actually check the fields we used
        // to discard — reject a stale round and a price older than the feed's
        // heartbeat instead of trusting whatever latestRoundData() returns.
        require(answeredInRound >= roundId, "RMHT: Stale price round");
        require(block.timestamp - updatedAt <= ETH_USD_HEARTBEAT, "RMHT: ETH price feed stale");
        return (uint256(answer), ethUsdFeed.decimals());
    }

    /// @notice Combien de secondes d'historique d'observations la pool
    ///         configurée stocke réellement à cet instant. 0 si la pool
    ///         n'est pas encore configurée.
    /// @dev Utile côté frontend/bot pour afficher « le TWAP sera disponible
    ///      dans X secondes » plutôt que de se prendre un revert opaque.
    function twapHistoryAvailable() public view returns (uint32) {
        if (uniswapV3Pool == address(0)) return 0;
        return UniswapV3TWAP.getOldestObservationSecondsAgo(uniswapV3Pool);
    }

    /// @notice true si la pool couvre la fenêtre TWAP complète, c'est-à-dire
    ///         si getRMHTPriceInETH() peut produire un prix. Tant que c'est
    ///         false, pokeMilestone() est un no-op silencieux (pas un revert)
    ///         et aucun palier ne peut se déclencher — c'est voulu.
    function isTwapReady() public view returns (bool) {
        return twapHistoryAvailable() >= TWAP_WINDOW;
    }

    /// @notice Prix RMHT en wei d'ETH par token, lu en TWAP sur la fenêtre
    ///         TWAP_WINDOW COMPLÈTE (revert tant que la pool ne couvre pas
    ///         cette fenêtre — cf. isTwapReady() / UniswapV3TWAP.sol).
    /// @dev sqrtPriceX96 est le prix de token1 en token0, sous racine carrée,
    ///      multiplié par 2^96 (format Uniswap v3 standard). On l'élève au
    ///      carré puis on divise par 2^192 pour obtenir le prix réel, avec
    ///      un facteur 1e18 pour garder la précision en entiers. MàJ
    ///      27/08/2026 : sqrtPriceX96 vient maintenant d'un TICK MOYEN
    ///      pondéré dans le temps (UniswapV3TWAP.consult), plus du spot
    ///      instantané slot0().sqrtPriceX96 — tout le reste de ce calcul
    ///      (déjà revu, Checked-Low côté cluster S7) est inchangé.
    function getRMHTPriceInETH() public view returns (uint256 priceInWeiPerToken) {
        require(uniswapV3Pool != address(0), "RMHT: Pool not set");
        // Audit fix (18/08/2026, toujours valable avec le TWAP): `unlocked`
        // ne passe à false que pendant l'exécution d'un swap sur cette pool
        // (reentrancy lock interne à Uniswap v3). Le vérifier avant de lire
        // observe() empêche un appel en plein milieu d'un callback (ex:
        // flash swap) — défense en profondeur en plus du TWAP lui-même.
        (, , , , , , bool unlocked) = IUniswapV3PoolMinimal(uniswapV3Pool).slot0();
        require(unlocked, "RMHT: Pool locked mid-swap");

        // FAIL-CLOSED (fix 27/08/2026) : on exige que la pool couvre la
        // fenêtre ENTIÈRE. Pas de repli sur une fenêtre raccourcie — voir la
        // note détaillée sur TWAP_WINDOW : une fenêtre raccourcie n'est pas
        // « un TWAP moins protecteur », c'est le prix spot avec un nom
        // différent. Tant que la pool n'a pas assez d'historique, ce contrat
        // préfère ne PAS produire de prix du tout (et donc ne libérer aucun
        // palier) plutôt que d'en produire un manipulable au bloc près.
        require(
            UniswapV3TWAP.getOldestObservationSecondsAgo(uniswapV3Pool) >= TWAP_WINDOW,
            "RMHT: TWAP history too short"
        );

        int24 meanTick = UniswapV3TWAP.consult(uniswapV3Pool, TWAP_WINDOW);
        uint160 sqrtPriceX96 = UniswapV3TWAP.getSqrtRatioAtTick(meanTick);

        // ratio = (sqrtPriceX96 / 2^96)^2 = prix de token1 en token0
        // On calcule en deux temps pour éviter l'overflow de uint256 sur le carré direct
        // (sqrtPriceX96 peut atteindre ~2^160, son carré dépasserait 2^256).
        uint256 ratioX128 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (192 - 128);
        // ratioX128 = prix de token1 en token0 (convention Uniswap v3 : price = token1/token0), en Q128 fixed point

        if (poolIsToken0) {
            // token0 = RMHT, token1 = WETH → ratioX128 = WETH par RMHT = EXACTEMENT
            // le prix recherché (wei de WETH pour 1 RMHT). Pas d'inversion : on
            // convertit juste le format Q128 fixed point en entier scalé 1e18.
            priceInWeiPerToken = (ratioX128 * 1e18) >> 128;
        } else {
            // token0 = WETH, token1 = RMHT → ratioX128 = RMHT par WETH = l'INVERSE
            // du prix recherché. Il faut inverser pour obtenir WETH par RMHT.
            // NOTE 27/08/2026 : depuis le passage au TWAP, ce require est du
            // code défensif STRUCTURELLEMENT INATTEIGNABLE — sqrtPriceX96 ne
            // vient plus de slot0() (qui pouvait valoir 0 sur une pool non
            // initialisée) mais de getSqrtRatioAtTick(), bornée par
            // construction à MIN_SQRT_RATIO = 4295128739, ce qui donne
            // ratioX128 >= 1. Conservé quand même (coût nul en pratique,
            // filet en cas d'évolution de la source de prix), mais il
            // apparaîtra comme branche non couverte dans lcov : c'est
            // attendu. Cf. test_MinTickPrice_Token1Orientation_NeverDividesByZero.
            require(ratioX128 != 0, "RMHT: Invalid pool price");
            priceInWeiPerToken = (uint256(1e18) << 128) / ratioX128;
        }
    }

    /// @notice Market cap de la supply éligible, en USD (unités entières, sans decimals).
    function getMarketCap() public view returns (uint256 mcapUSD) {
        uint256 eligible = _getEligibleSupply();
        uint256 priceETHWei = getRMHTPriceInETH();               // prix d'1 RMHT en wei ETH
        (uint256 ethUsd, uint8 feedDec) = getETHPriceUSD();

        // Audit fix (Slither divide-before-multiply, and SolidityScan M003 —
        // Precision loss during division by large numbers): single
        // multiplication followed by a SINGLE division (denominators combined
        // into one product) instead of two sequential /(10**feedDec) then
        // /1e36 divisions, which each truncate and compound rounding error.
        // Safe from overflow: eligible <= 1e27, and even at unrealistic
        // extremes (priceETHWei ~1e18, ethUsd ~1e11) the numerator stays well
        // under uint256's ~1.15e77 ceiling.
        mcapUSD = (eligible * priceETHWei * ethUsd) / (10 ** feedDec * 1e36);
    }

    function _getEligibleSupply() internal view returns (uint256) {
        uint256 supply = TOTAL_SUPPLY;
        supply -= balanceOf(BURN_ADDRESS);
        supply -= balanceOf(address(this));
        if (uniswapV3Pool != address(0)) {
            uint256 poolBal = balanceOf(uniswapV3Pool);
            supply = supply > poolBal ? supply - poolBal : 0;
        }
        return supply;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PALIER AUTO-DÉCLENCHÉ (remplace Chainlink Automation/CRE)
    //
    //  Le prix étant déjà calculable on-chain (getMarketCap), plus besoin
    //  d'automatisation externe. pokeMilestone() est permissionless : n'importe
    //  qui peut l'appeler, n'importe quand (bot perso, holder, autre) —
    //  typiquement juste après un swap qui a fait bouger le prix.
    //
    //  IMPORTANT : ne JAMAIS appeler pokeMilestone() (ni rien qui lise
    //  getMarketCap()) depuis _update()/_transfer() — pendant l'exécution
    //  d'un swap sur uniswapV3Pool, la pool est encore verrouillée
    //  (slot0().unlocked == false), et getRMHTPriceInETH() revert dans cet
    //  état. pokeMilestone() doit rester une transaction séparée, appelée
    //  après que le swap ait relâché le verrou.
    //
    //  Anti flash-loan : un flash loan doit être remboursé dans SA PROPRE
    //  transaction — il ne peut donc jamais "tenir" un prix manipulé sur
    //  plusieurs blocs. En exigeant MILESTONE_CONFIRMATIONS_REQUIRED
    //  confirmations distinctes, espacées d'au moins MILESTONE_CONFIRM_INTERVAL
    //  et réunies dans une fenêtre MILESTONE_CONFIRM_WINDOW, une manipulation
    //  devient économiquement dissuasive : il faudrait tenir le prix manipulé
    //  de façon soutenue sur une large fenêtre, avec du capital immobilisé et
    //  du slippage à chaque instant, pas juste un instant précis.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Fait avancer la machine à états du palier courant. Ne fait
    ///         rien (silencieusement, pas de revert) si la pool n'est pas
    ///         configurée, le vault est vide, ou la pool est verrouillée
    ///         mid-swap — pour ne jamais casser un éventuel appelant qui
    ///         composerait cette fonction dans un chemin plus large.
    ///
    /// @dev FIX 21/08/2026 : la logique était auparavant inline directement
    ///      dans cette fonction externe, sous le modifier `nonReentrant`. En
    ///      Solidity, un modifier n'est pas une fonction séparée : son code
    ///      est inséré textuellement à l'emplacement de `_;`. Un `return;`
    ///      dans le corps de la fonction sort donc de TOUTE la fonction, y
    ///      compris du code du modifier situé après `_;` — ici
    ///      `_status = NOT_ENTERED;` ne s'exécutait donc jamais dès qu'un
    ///      appel empruntait une branche à `return` (armement, désarmement,
    ///      "trop tôt", confirmation intermédiaire — soit la quasi-totalité
    ///      des chemins). Résultat : dès le tout premier appel réel, le
    ///      verrou de réentrance restait bloqué à ENTERED pour toujours,
    ///      et tout appel suivant revertait immédiatement avec
    ///      ReentrancyGuardReentrantCall(), sans jamais toucher à l'oracle
    ///      ni à la pool. Fix : la logique (inchangée) est déplacée dans
    ///      `_pokeMilestone()` (internal, sans modifier) ; ses `return`
    ///      internes ne sortent plus que de cette fonction interne, laissant
    ///      le wrapper externe `nonReentrant` toujours remettre le verrou à
    ///      NOT_ENTERED normalement.
    function pokeMilestone() external nonReentrant {
        _pokeMilestone();
    }

    function _pokeMilestone() internal {
        if (uniswapV3Pool == address(0) || vaultBalance == 0) return;

        (, , , , , , bool unlocked) = IUniswapV3PoolMinimal(uniswapV3Pool).slot0();
        if (!unlocked) return;

        // FIX 27/08/2026 : pool pas encore assez « profonde » en historique
        // d'observations → getRMHTPriceInETH() reverterait. On préserve ici
        // le contrat annoncé de pokeMilestone() (no-op silencieux, jamais de
        // revert) au lieu de laisser remonter le revert de l'oracle.
        if (!isTwapReady()) return;

        uint256 mcap = getMarketCap();

        if (!milestoneArmed) {
            // IDLE → armement si le seuil est franchi. Première confirmation
            // comptée immédiatement (l'armement lui-même vaut confirmation #1).
            if (mcap >= nextMilestoneUSD) {
                milestoneArmed           = true;
                milestoneArmedAt         = block.timestamp;
                milestoneArmedMcap       = mcap;
                milestoneConfirmations   = 1;
                milestoneLastConfirmedAt = block.timestamp;
                emit MilestoneArmed(mcap, block.timestamp + MILESTONE_CONFIRM_WINDOW);
                emit MilestoneConfirmationRecorded(1, MILESTONE_CONFIRMATIONS_REQUIRED, mcap);
            }
            return;
        }

        // ARMED : filet de sécurité — fenêtre totale dépassée sans avoir
        // réuni toutes les confirmations requises → désarmement, retour IDLE.
        if (block.timestamp > milestoneArmedAt + MILESTONE_CONFIRM_WINDOW) {
            milestoneArmed = false;
            milestoneConfirmations = 0;
            emit MilestoneDisarmed(mcap);
            return;
        }

        // Désarmement immédiat si le prix est redescendu sous le seuil, à
        // n'importe quelle vérification — pas seulement à l'échéance.
        if (mcap < nextMilestoneUSD) {
            milestoneArmed = false;
            milestoneConfirmations = 0;
            emit MilestoneDisarmed(mcap);
            return;
        }

        // Toujours au-dessus du seuil, mais trop tôt depuis la dernière
        // confirmation — on attend l'écart minimum avant d'en compter une
        // nouvelle (empêche de précipiter la séquence).
        if (block.timestamp < milestoneLastConfirmedAt + MILESTONE_CONFIRM_INTERVAL) return;

        if (milestoneConfirmations < MILESTONE_CONFIRMATIONS_REQUIRED) {
            milestoneConfirmations   += 1;
            milestoneLastConfirmedAt = block.timestamp;
            emit MilestoneConfirmationRecorded(milestoneConfirmations, MILESTONE_CONFIRMATIONS_REQUIRED, mcap);
        }

        if (milestoneConfirmations < MILESTONE_CONFIRMATIONS_REQUIRED) return;

        // Séquence complète : encore faut-il que le cooldown 24h entre
        // paliers soit écoulé.
        if (block.timestamp >= lastMilestoneTimestamp + MILESTONE_COOLDOWN) {
            milestoneArmed = false;
            milestoneConfirmations = 0;
            _executeMilestone(mcap);
        }
        // Sinon : séquence de confirmations complète mais cooldown pas
        // encore écoulé — reste armé au max de confirmations, sera
        // ré-exécuté au prochain poke une fois le cooldown libéré (à
        // condition de rester dans MILESTONE_CONFIRM_WINDOW, sinon le
        // filet de sécurité ci-dessus réarmera tout depuis zéro).
    }

    /// @notice Lecture pratique de l'état courant pour un frontend/bot,
    ///         sans payer de gas (view).
    function milestoneStatus()
        external
        view
        returns (
            bool armed,
            uint8 confirmations,
            uint8 confirmationsRequired,
            uint256 windowExpiresAt,
            uint256 mcapAtArm,
            uint256 currentMcap
        )
    {
        return (
            milestoneArmed,
            milestoneConfirmations,
            MILESTONE_CONFIRMATIONS_REQUIRED,
            milestoneArmed ? milestoneArmedAt + MILESTONE_CONFIRM_WINDOW : 0,
            milestoneArmedMcap,
            getMarketCap()
        );
    }

    function _executeMilestone(uint256 mcapNow) internal {
        uint256 release  = (vaultBalance * RELEASE_BPS) / BPS_DENOM;
        uint256 eligible = _getEligibleSupply();
        require(eligible != 0, "RMHT: No eligible supply"); // gas (G003): equivalent for uint256
        if (release > vaultBalance) release = vaultBalance;

        vaultBalance -= release;
        unclaimedReleased += release;
        milestonesReached++;
        lastMilestoneTimestamp = block.timestamp;
        nextMilestoneUSD += MILESTONE_STEP_USD;

        // Audit note (Slither divide-before-multiply — intentionally NOT
        // "fixed" here, unlike getMarketCap() above): milestoneRewardPerToken
        // must be derived from the CLAMPED `release` value below, not from a
        // raw recombined formula. If release gets clamped to vaultBalance on
        // the final milestone, using a reordered/unclamped calculation would
        // credit holders with more rewards than the vault actually backs.
        // 100% aux holders — pas de split autoLP/marketing (destinations supprimées)
        milestoneRewardPerToken += (release * REWARD_PRECISION) / eligible;

        emit MilestoneTriggered(milestonesReached, mcapNow, release);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  REWARDS — accrual & claim (mécanique inchangée vs contrat original)
    // ═══════════════════════════════════════════════════════════════════════

    function _updateReward(address account) internal {
        if (account == address(0))          return;
        if (account == address(this))       return;
        if (isExcludedFromRewards[account]) return;
        uint256 delta = milestoneRewardPerToken - userRewardPerTokenPaid[account];
        if (delta != 0) {
            pendingRewards[account] += (balanceOf(account) * delta) / REWARD_PRECISION;
            userRewardPerTokenPaid[account] = milestoneRewardPerToken;
        }
    }

    function pendingRewardsOf(address account) external view returns (uint256) {
        if (isExcludedFromRewards[account]) return 0;
        uint256 delta  = milestoneRewardPerToken - userRewardPerTokenPaid[account];
        uint256 latent = (balanceOf(account) * delta) / REWARD_PRECISION;
        return pendingRewards[account] + latent;
    }

    function claimRewards() external nonReentrant {
        require(!isExcludedFromRewards[msg.sender], "RMHT: Excluded from rewards");
        _updateReward(msg.sender);
        uint256 reward = pendingRewards[msg.sender];
        require(reward != 0, "RMHT: No rewards"); // gas (G003): equivalent for uint256

        delete pendingRewards[msg.sender];
        // reward a nécessairement été comptabilisé via un _executeMilestone
        // antérieur (milestoneRewardPerToken ne peut augmenter que là), donc
        // unclaimedReleased >= reward à cet instant : pas de risque d'underflow.
        unclaimedReleased -= reward;
        super._update(address(this), msg.sender, reward);
        emit RewardClaimed(msg.sender, reward);
    }

    function excludeFromRewards(address addr, bool status) external onlyOwner {
        require(addr != address(0),    "RMHT: Zero address");
        require(addr != address(this), "RMHT: Cannot modify contract exclusion");
        require(addr != BURN_ADDRESS,  "RMHT: Cannot modify burn exclusion");
        require(isExcludedFromRewards[addr] != status, "RMHT: Status unchanged");

        if (status) {
            _updateReward(addr);
            delete pendingRewards[addr];
        } else {
            userRewardPerTokenPaid[addr] = milestoneRewardPerToken;
        }
        isExcludedFromRewards[addr] = status;
        emit RewardExclusionUpdated(addr, status);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  _update OVERRIDE — plus AUCUNE taxe, AUCUNE blacklist. Juste le snapshot
    //  de reward avant transfert, pour que la comptabilité des rewards reste
    //  correcte. Transfert de la valeur exacte, sans déduction.
    //  (Verrou de lancement et anti-sandwich même-bloc retirés le 14/08/2026,
    //  voir changelog en tête de fichier.)
    // ═══════════════════════════════════════════════════════════════════════
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        _updateReward(from);
        _updateReward(to);
        super._update(from, to, value);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  RESCUE — tokens/ETH envoyés par erreur (ne touche jamais vaultBalance
    //  ni unclaimedReleased — voir déclaration de cette dernière plus haut)
    // ═══════════════════════════════════════════════════════════════════════
    /// @dev Audit note (Slither low-level-calls): intentional here — a rescue
    ///      function must work for arbitrary/non-standard ERC20s and for raw
    ///      ETH, so a static IERC20 call or plain transfer() isn't sufficient.
    ///      Already covered by nonReentrant + onlyOwner, and the manual
    ///      ok/data.length check below replicates SafeERC20's behaviour for
    ///      tokens that don't return a bool.
    function rescueTokens(address token, uint256 amount) external nonReentrant onlyOwner {
        if (token == address(this)) {
            uint256 balance   = balanceOf(address(this));
            uint256 reserved  = vaultBalance + unclaimedReleased;
            uint256 available = balance > reserved ? balance - reserved : 0;
            require(amount <= available, "RMHT: Cannot withdraw tracked RMHT");
            super._update(address(this), owner(), amount);
        } else if (token == address(0)) {
            require(amount <= address(this).balance, "RMHT: Insufficient ETH");
            (bool sent, ) = payable(owner()).call{value: amount}("");
            require(sent, "RMHT: ETH transfer failed");
        } else {
            // Audit fix (SolidityScan M001 — Account Existence Check For Low
            // Level Calls): a low-level .call() to an address with no code
            // trivially "succeeds" with empty returndata, which the branch
            // above would otherwise read as data.length == 0 → success. This
            // rejects that case explicitly instead of silently reporting a
            // rescue as done when `token` isn't actually a contract.
            require(token.code.length > 0, "RMHT: Not a contract");
            (bool ok, bytes memory data) = token.call(
                abi.encodeCall(IERC20.transfer, (owner(), amount))
            );
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "RMHT: Token transfer failed");
        }
        emit TokensRescued(token, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════════
    function getCirculatingSupply() external view returns (uint256) {
        uint256 contractBal = balanceOf(address(this));
        uint256 burnedBal   = balanceOf(BURN_ADDRESS);
        if (TOTAL_SUPPLY <= contractBal + burnedBal) return 0;
        return TOTAL_SUPPLY - contractBal - burnedBal;
    }

    function getEligibleSupply() external view returns (uint256) { return _getEligibleSupply(); }

    receive() external payable {}
}
