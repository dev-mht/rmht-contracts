// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../src/RMHTLiquidityCustodian.sol";
import "./mocks/MockPositionManager.sol";
import "./mocks/MaliciousReentrantPositionManager.sol";

contract RMHTLiquidityCustodianTest is Test {
    // Redéclaré ici avec la même signature que dans le contrat, uniquement
    // pour que vm.expectEmit puisse matcher le topic — Solidity ne permet
    // pas d'importer un event pour l'emit dans un autre contrat.
    event FeesCollected(uint256 amount0, uint256 amount1, address indexed recipient);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event PositionReceived(uint256 indexed tokenId, address indexed from);

    RMHTLiquidityCustodian custodian;
    MockPositionManager pm;

    address owner = address(0xA11CE);
    address feeRecipient = address(0xFEE);
    address stranger = address(0xBAD);
    address newOwnerCandidate = address(0xCAFE);
    uint256 constant TOKEN_ID = 42;

    function setUp() public {
        pm = new MockPositionManager();
        custodian = new RMHTLiquidityCustodian(address(pm), owner, feeRecipient);
        // AJOUTÉ 27/08/2026 : dans un vrai safeTransferFrom, `from` est le
        // propriétaire du NFT (ici le owner/deployer), pas le position
        // manager — et le custodian n'accepte plus que ce dépôt-là.
        pm.setDepositor(owner);
    }

    // ───────────────────────── Constructor ─────────────────────────

    function test_RevertConstructor_ZeroPositionManager() public {
        vm.expectRevert(bytes("Custodian: Invalid position manager"));
        new RMHTLiquidityCustodian(address(0), owner, feeRecipient);
    }

    function test_RevertConstructor_ZeroFeeRecipient() public {
        vm.expectRevert(bytes("Custodian: Invalid fee recipient"));
        new RMHTLiquidityCustodian(address(pm), owner, address(0));
    }

    /// @dev NOUVEAU — branche jamais exercée : Ownable2's constructor revert
    ///      (OwnableInvalidOwner) quand initialOwner == address(0). Le require
    ///      explicite du contrat vient juste après, mais le constructeur de
    ///      Ownable2 s'exécute et revert en premier.
    function test_RevertConstructor_ZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableInvalidOwner.selector, address(0)));
        new RMHTLiquidityCustodian(address(pm), address(0), feeRecipient);
    }

    // ───────────────────────── Dépôt de la position ─────────────────────────

    function test_RevertOnERC721Received_NotPositionManager() public {
        vm.expectRevert(bytes("Custodian: Only position manager"));
        custodian.onERC721Received(address(0), address(0), TOKEN_ID, "");
    }

    /// @dev RÉÉCRIT 27/08/2026 : le `require(from != address(0))` a été retiré
    ///      parce qu'il est devenu PROUVABLEMENT redondant — `depositor` est
    ///      immutable et garanti non nul, donc `from == depositor` implique
    ///      déjà `from != address(0)`. Le test vérifie donc que `from == 0`
    ///      est toujours rejeté, simplement par le check de dépositaire.
    function test_RevertOnERC721Received_ZeroFrom() public {
        vm.prank(address(pm));
        vm.expectRevert(bytes("Custodian: Only depositor can deposit position"));
        custodian.onERC721Received(address(0), address(0), TOKEN_ID, "");
    }

    /// @notice `depositor` est bien figé au déploiement sur l'owner initial.
    function test_Constructor_SetsImmutableDepositor() public view {
        assertEq(custodian.depositor(), owner);
    }

    function test_OnERC721Received_SetsPosition() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);
        assertEq(custodian.tokenId(), TOKEN_ID);
        assertTrue(custodian.positionReceived());
    }

    /// @dev NOUVEAU — vérifie l'event PositionReceived (jamais vérifié avant).
    function test_OnERC721Received_EmitsPositionReceivedEvent() public {
        vm.expectEmit(true, true, true, true, address(custodian));
        // `from` = owner depuis le 27/08/2026 (cf. setUp) : c'est le
        // propriétaire du NFT qui dépose, pas le position manager.
        emit PositionReceived(TOKEN_ID, owner);
        pm.deliverPosition(address(custodian), TOKEN_ID);
    }

    function test_RevertOnERC721Received_SecondDeposit() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);
        vm.expectRevert(bytes("Custodian: Position already set, one position per custodian"));
        pm.deliverPosition(address(custodian), 99);
    }


    /// @notice FIX 27/08/2026 — course au dépôt. Un tiers qui possède une
    ///         position Uniswap v3 quelconque ne doit PAS pouvoir squatter le
    ///         custodian avec elle avant que l'équipe n'y dépose la vraie.
    ///         Avant le fix, ce dépôt réussissait et figeait `tokenId` sur la
    ///         position bidon pour toujours.
    function test_RevertOnERC721Received_StrangerCannotSquatPosition() public {
        vm.expectRevert(bytes("Custodian: Only depositor can deposit position"));
        pm.deliverPositionFrom(address(custodian), 1337, stranger);

        assertFalse(custodian.positionReceived(), "le custodian ne doit pas etre verrouille");
        assertEq(custodian.tokenId(), 0);
    }

    /// @notice Suite du précédent : après la tentative de squat, le dépôt
    ///         légitime doit toujours fonctionner normalement (le custodian
    ///         n'est pas briqué). C'est la moitié qui prouve que le fix
    ///         corrige le DoS au lieu de juste déplacer le problème.
    function test_OnERC721Received_LegitimateDepositStillWorksAfterSquatAttempt() public {
        vm.expectRevert(bytes("Custodian: Only depositor can deposit position"));
        pm.deliverPositionFrom(address(custodian), 1337, stranger);

        pm.deliverPosition(address(custodian), TOKEN_ID);
        assertTrue(custodian.positionReceived());
        assertEq(custodian.tokenId(), TOKEN_ID);
    }

    /// @notice RÉÉCRIT 27/08/2026 — le contrôle ne suit PLUS le owner courant :
    ///         `depositor` est immutable. Un transfert d'ownership ne déplace
    ///         donc pas le droit de dépôt, et le nouveau owner ne peut pas
    ///         déposer. C'est volontaire : moins de pièces mobiles sur le seul
    ///         chemin qui fige `tokenId` définitivement.
    function test_OnERC721Received_DepositorDoesNotFollowOwnershipTransfer() public {
        vm.prank(owner);
        custodian.transferOwnership(newOwnerCandidate);
        vm.prank(newOwnerCandidate);
        custodian.acceptOwnership();
        assertEq(custodian.owner(), newOwnerCandidate);

        vm.expectRevert(bytes("Custodian: Only depositor can deposit position"));
        pm.deliverPositionFrom(address(custodian), TOKEN_ID, newOwnerCandidate);

        // Le dépositaire d'origine reste le seul habilité.
        pm.deliverPositionFrom(address(custodian), TOKEN_ID, owner);
        assertTrue(custodian.positionReceived());
    }

    /// @notice Corollaire du passage en immutable : le dépôt reste possible
    ///         APRÈS `renounceOwnership()`. Avec l'ancien `from == owner()`,
    ///         renoncer avant d'avoir déposé aurait rendu le custodian
    ///         inutilisable à jamais. Le déployeur garde son droit de dépôt
    ///         quoi qu'il arrive à l'ownership.
    function test_OnERC721Received_StillPossibleAfterRenounce() public {
        vm.prank(owner);
        custodian.renounceOwnership();
        assertEq(custodian.owner(), address(0));

        pm.deliverPosition(address(custodian), TOKEN_ID);
        assertTrue(custodian.positionReceived());
        assertEq(custodian.tokenId(), TOKEN_ID);
    }

    // ───────────────────────── collect() ─────────────────────────
    // Le point clé : collect() est volontairement permissionless (n'importe qui
    // peut l'appeler), MAIS la destination des fonds (feeRecipient) est fixe et
    // contrôlée uniquement par owner. Donc même si un "malin" appelle collect()
    // avant toi, l'argent atterrit quand même chez TOI, jamais chez lui.

    function test_RevertCollect_NoPosition() public {
        vm.expectRevert(bytes("Custodian: No position held"));
        custodian.collect();
    }

    function test_Collect_AlwaysPaysFeeRecipient_RegardlessOfCaller() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);

        // Un "malin" (stranger) déclenche collect() en premier, sans autorisation
        vm.prank(stranger);
        custodian.collect();

        // Peu importe qui a appelé : le destinataire réel côté position manager
        // est TOUJOURS feeRecipient, jamais msg.sender ni le stranger.
        assertEq(pm.lastCollectRecipient(), feeRecipient);
        assertEq(pm.lastCollectCaller(), address(custodian));
        assertEq(pm.collectCallCount(), 1);
    }

    function test_Collect_EmitsFeesCollectedEvent() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);
        vm.expectEmit(true, true, true, true, address(custodian));
        emit FeesCollected(5 ether, 3 ether, feeRecipient);
        custodian.collect();
    }

    /// @dev NOUVEAU — la branche la plus importante à couvrir : le verrou
    ///      nonReentrant sur collect() n'était jusqu'ici jamais réellement
    ///      testé (juste présent dans le code). Ce mock rappelle collect()
    ///      pendant sa propre exécution ; le second appel doit revert.
    function test_Collect_ReentrancyBlocked() public {
        MaliciousReentrantPositionManager evilPm = new MaliciousReentrantPositionManager();
        RMHTLiquidityCustodian evilCustodian =
            new RMHTLiquidityCustodian(address(evilPm), owner, feeRecipient);
        evilPm.setCustodian(address(evilCustodian));
        evilPm.setDepositor(owner);
        evilPm.deliverPosition(address(evilCustodian), TOKEN_ID);

        // Le premier appel doit réussir malgré la tentative de réentrance
        // interne (qui doit échouer silencieusement, catchée par le mock).
        evilCustodian.collect();

        assertTrue(evilPm.reentered(), "le mock n'a pas tente de reentrer");
        assertTrue(evilPm.reentrancyReverted(), "la reentrance n'a pas revert comme attendu");
    }

    // ───────────────────────── feeRecipient ─────────────────────────

    function test_SetFeeRecipient_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, stranger));
        custodian.setFeeRecipient(stranger);
    }

    function test_SetFeeRecipient_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Custodian: Invalid recipient"));
        custodian.setFeeRecipient(address(0));
    }

    function test_SetFeeRecipient_UpdatesAndCollectFollows() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);
        address newRecipient = address(0xF00D);

        vm.prank(owner);
        custodian.setFeeRecipient(newRecipient);

        custodian.collect();
        assertEq(pm.lastCollectRecipient(), newRecipient);
    }

    /// @dev NOUVEAU — vérifie l'event FeeRecipientUpdated (jamais vérifié avant).
    function test_SetFeeRecipient_EmitsEvent() public {
        address newRecipient = address(0xF00D);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(custodian));
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        custodian.setFeeRecipient(newRecipient);
    }

    // ───────────────────────── Ownership : renounce ─────────────────────────

    function test_RenounceOwnership_RemovesOwnerPowers() public {
        vm.prank(owner);
        custodian.renounceOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, owner));
        custodian.setFeeRecipient(stranger);
    }

    /// @dev NOUVEAU — branche jamais exercée : un stranger ne peut pas renoncer
    ///      à la place du owner (onlyOwner sur renounceOwnership).
    function test_RenounceOwnership_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, stranger));
        custodian.renounceOwnership();
    }

    /// @dev NOUVEAU — vérifie l'event OwnershipTransferred(owner, address(0)).
    function test_RenounceOwnership_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(custodian));
        emit OwnershipTransferred(owner, address(0));
        custodian.renounceOwnership();
    }

    function test_Collect_StillWorksForeverAfterRenounce() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);

        vm.prank(owner);
        custodian.renounceOwnership();

        // N'importe qui peut toujours déclencher collect() après le renounce,
        // et les fonds continuent d'aller au feeRecipient figé au moment du renounce.
        vm.prank(stranger);
        custodian.collect();
        assertEq(pm.lastCollectRecipient(), feeRecipient);

        // Et feeRecipient est bien gelé pour toujours : plus personne, même
        // l'ex-owner, ne peut le changer.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, owner));
        custodian.setFeeRecipient(stranger);
    }

    // ───────────────────────── Ownership : transfer en 2 temps (NOUVEAU) ─────────────────────────
    // Tout ce bloc est nouveau : transferOwnership()/acceptOwnership() n'étaient
    // jusqu'ici jamais appelés par aucun test, alors qu'ils représentent 5 des
    // 8 branches manquantes de ce contrat.

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, stranger));
        custodian.transferOwnership(newOwnerCandidate);
    }

    function test_TransferOwnership_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableInvalidOwner.selector, address(0)));
        custodian.transferOwnership(address(0));
    }

    function test_TransferOwnership_SetsPendingOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(custodian));
        emit OwnershipTransferStarted(owner, newOwnerCandidate);
        custodian.transferOwnership(newOwnerCandidate);

        // L'ownership ne change PAS tant que acceptOwnership() n'a pas été
        // appelé — c'est tout l'intérêt du two-step.
        assertEq(custodian.owner(), owner);
        assertEq(custodian.pendingOwner(), newOwnerCandidate);
    }

    function test_AcceptOwnership_RevertsIfNotPending() public {
        vm.prank(owner);
        custodian.transferOwnership(newOwnerCandidate);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, stranger));
        custodian.acceptOwnership();
    }

    function test_AcceptOwnership_Success() public {
        vm.prank(owner);
        custodian.transferOwnership(newOwnerCandidate);

        vm.prank(newOwnerCandidate);
        vm.expectEmit(true, true, true, true, address(custodian));
        emit OwnershipTransferred(owner, newOwnerCandidate);
        custodian.acceptOwnership();

        assertEq(custodian.owner(), newOwnerCandidate);
        assertEq(custodian.pendingOwner(), address(0));

        // L'ancien owner a bien perdu tout pouvoir.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2.OwnableUnauthorizedAccount.selector, owner));
        custodian.setFeeRecipient(stranger);

        // Le nouveau owner peut agir immédiatement.
        vm.prank(newOwnerCandidate);
        custodian.setFeeRecipient(stranger);
        assertEq(custodian.feeRecipient(), stranger);
    }

    // ───────────────────────── currentLiquidity ─────────────────────────

    function test_RevertCurrentLiquidity_NoPosition() public {
        vm.expectRevert(bytes("Custodian: No position held"));
        custodian.currentLiquidity();
    }

    function test_CurrentLiquidity_ReadsFromPositionManager() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);
        pm.setMockLiquidity(777_777);
        assertEq(custodian.currentLiquidity(), 777_777);
    }

    // ───────────────────────── Preuve d'absence de fonctions dangereuses ─────────────────────────
    // Le contrat n'a ni fallback ni receive au-delà de onERC721Received, donc
    // tout appel avec un sélecteur inconnu (decreaseLiquidity, transferFrom du
    // NFT détenu, etc.) doit échouer — c'est vérifiable par ces tests plutôt
    // que par simple lecture du code.

    function test_NoDecreaseLiquiditySelector() public {
        (bool success, ) = address(custodian).call(
            abi.encodeWithSignature(
                "decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))",
                0, 0, 0, 0, 0
            )
        );
        assertFalse(success);
    }

    function test_NoTransferOfHeldNFTOut() public {
        pm.deliverPosition(address(custodian), TOKEN_ID);
        (bool success, ) = address(custodian).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(custodian), stranger, TOKEN_ID)
        );
        assertFalse(success);
    }

    function test_NoSelfdestructReachable() public {
        // Aucun sélecteur plausible de type "kill"/"destroy" n'existe sur le contrat.
        (bool success, ) = address(custodian).call(abi.encodeWithSignature("kill()"));
        assertFalse(success);
        (bool success2, ) = address(custodian).call(abi.encodeWithSignature("destroy()"));
        assertFalse(success2);
    }
}
