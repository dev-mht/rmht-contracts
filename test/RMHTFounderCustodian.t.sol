// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "../src/RMHTFounderCustodian.sol";
import "./mocks/MockRMHTWithMilestones.sol";
import "./mocks/MaliciousReentrantFounderRescue_20260825_1400.sol";

contract RMHTFounderCustodianTest is Test {
    RMHTFounderCustodian custodian;
    MockRMHTWithMilestones rmht;

    address owner = address(0xA11CE);
    address beneficiary = address(0xF01D);
    address stranger = address(0xD004);

    uint256 constant FOUNDER_ALLOCATION = 50_000_000 ether;

    /// @dev Timestamps en LITTÉRAUX : sous via_ir, l'optimiseur peut
    ///      re-substituer `block.timestamp` à une variable locale entre deux
    ///      vm.warp(), et on warpe alors depuis une horloge déjà décalée.
    uint256 constant T0 = 1_700_000_000;
    uint48 constant UNLOCK_AT = uint48(T0 + 365 days);

    event CustodianDeployed(address indexed initialOwner, address indexed beneficiary);
    event RmhtTokenSet(address indexed rmhtToken);
    event UnlockTimeSet(uint256 unlockTime);
    event Claimed(address indexed beneficiary, uint256 amount, uint256 totalClaimedAfter);
    event EthRescued(address indexed to, uint256 amount);
    /// @dev AJOUT 28/08/2026 — rewards de palier.
    event RewardsHarvested(uint256 amount, uint256 totalHarvestedRewardsAfter);
    event RewardClaimed(address indexed beneficiary, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        vm.warp(T0);

        vm.prank(owner);
        custodian = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);

        rmht = new MockRMHTWithMilestones();
        rmht.mint(address(custodian), FOUNDER_ALLOCATION);

        vm.prank(owner);
        custodian.setRmhtToken(address(rmht));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructeur / setUp
    // ═══════════════════════════════════════════════════════════════════════

    function test_Constructor_SetsOwnerAndBeneficiary() public view {
        assertEq(custodian.owner(), owner);
        assertEq(custodian.beneficiary(), beneficiary);
    }

    /// @notice REFONTE 27/08/2026 — `unlockTime` est fixé dans la transaction
    ///         de déploiement et devient immutable. C'est LE point qui empêche
    ///         un oubli de setup de geler les 50M pour toujours, maintenant
    ///         que le déblocage temporel est le seul chemin de sortie.
    function test_Constructor_SetsImmutableUnlockTime() public view {
        assertEq(custodian.unlockTime(), UNLOCK_AT);
    }

    function test_Constructor_EmitsUnlockTimeSet() public {
        vm.expectEmit(true, true, true, true);
        emit UnlockTimeSet(UNLOCK_AT);
        vm.prank(owner);
        new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
    }

    function test_RevertConstructor_UnlockTimeInThePast() public {
        vm.expectRevert(RMHTFounderCustodian.UnlockTimeMustBeFuture.selector);
        new RMHTFounderCustodian(owner, beneficiary, uint48(T0 - 1));
    }

    /// @notice Borne exacte : `block.timestamp` lui-même est refusé (il faut
    ///         strictement le futur), `block.timestamp + 1` passe.
    function test_RevertConstructor_UnlockTimeExactlyNow() public {
        vm.expectRevert(RMHTFounderCustodian.UnlockTimeMustBeFuture.selector);
        new RMHTFounderCustodian(owner, beneficiary, uint48(T0));
    }

    function test_Constructor_AcceptsOneSecondInTheFuture() public {
        RMHTFounderCustodian c = new RMHTFounderCustodian(owner, beneficiary, uint48(T0 + 1));
        assertEq(c.unlockTime(), uint48(T0 + 1));
    }

    /// @notice Il ne doit plus exister AUCUN moyen de déplacer la date après
    ///         coup — ni pour l'owner, ni pour personne. Vérifié sur l'ABI :
    ///         le sélecteur de l'ancienne fonction ne répond plus.
    function test_NoSetUnlockTimeFunctionRemains() public {
        (bool ok, ) = address(custodian).call(
            abi.encodeWithSignature("setUnlockTime(uint48)", uint48(T0 + 999 days))
        );
        assertFalse(ok, "setUnlockTime() ne doit plus exister sur ce contrat");
        assertEq(custodian.unlockTime(), UNLOCK_AT);
    }

    function test_RevertConstructor_ZeroBeneficiary() public {
        vm.expectRevert(bytes("RMHTFounder: zero address"));
        new RMHTFounderCustodian(owner, address(0), UNLOCK_AT);
    }

    function test_RevertConstructor_ZeroOwner() public {
        vm.expectRevert(bytes("Ownable: zero address"));
        new RMHTFounderCustodian(address(0), beneficiary, UNLOCK_AT);
    }

    function test_Constructor_EmitsCustodianDeployed() public {
        vm.expectEmit(true, true, true, true);
        emit CustodianDeployed(owner, beneficiary);
        vm.prank(owner);
        new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  setRmhtToken()
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetRmhtToken_AlreadySetInSetUp() public view {
        assertTrue(custodian.rmhtSet());
        assertEq(address(custodian.rmht()), address(rmht));
    }

    function test_RevertSetRmhtToken_AlreadySet() public {
        vm.prank(owner);
        vm.expectRevert(RMHTFounderCustodian.RmhtAlreadySet.selector);
        custodian.setRmhtToken(address(rmht));
    }

    function test_RevertSetRmhtToken_ZeroAddress() public {
        RMHTFounderCustodian fresh = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
        vm.prank(owner);
        vm.expectRevert(bytes("RMHTFounder: zero address"));
        fresh.setRmhtToken(address(0));
    }

    function test_RevertSetRmhtToken_NotAContract() public {
        RMHTFounderCustodian fresh = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
        vm.prank(owner);
        vm.expectRevert(RMHTFounderCustodian.TokenNotContract.selector);
        fresh.setRmhtToken(stranger); // EOA, pas de code
    }

    function test_RevertSetRmhtToken_NotOwner() public {
        RMHTFounderCustodian fresh = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setRmhtToken(address(rmht));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  unlockedAmount() — REFONTE 27/08/2026 : tout ou rien à `unlockTime`
    //
    //  L'ancienne section testait le vesting par tranches (10M débloqués tous
    //  les 10 paliers de market cap). Ce mécanisme a été retiré : il faisait
    //  dépendre le calendrier de libération du fondateur d'une fonction
    //  PERMISSIONLESS (`RMHT.pokeMilestone()`), donc n'importe qui pouvait
    //  accélérer le vesting en poussant le market cap.
    // ═══════════════════════════════════════════════════════════════════════

    function test_UnlockedAmount_ZeroBeforeUnlockTime() public view {
        assertEq(custodian.unlockedAmount(), 0);
    }

    /// @notice Borne exacte, côté "pas encore" : une seconde avant la date,
    ///         rien n'est débloqué.
    function test_UnlockedAmount_ZeroOneSecondBefore() public {
        vm.warp(uint256(UNLOCK_AT) - 1);
        assertEq(custodian.unlockedAmount(), 0);
    }

    /// @notice Borne exacte, côté "c'est bon" : à la seconde pile, 100%.
    function test_UnlockedAmount_FullAtExactUnlockTime() public {
        vm.warp(uint256(UNLOCK_AT));
        assertEq(custodian.unlockedAmount(), FOUNDER_ALLOCATION);
    }

    function test_UnlockedAmount_FullLongAfter() public {
        vm.warp(uint256(UNLOCK_AT) + 3650 days);
        assertEq(custodian.unlockedAmount(), FOUNDER_ALLOCATION);
    }

    /// @notice LE test qui matérialise la décision du 27/08/2026 : quel que
    ///         soit le nombre de paliers franchis côté RMHT, RIEN ne sort
    ///         avant la date. Le mock est poussé à un nombre de paliers qui
    ///         aurait débloqué la totalité sous l'ancien vesting par tranches.
    function test_UnlockedAmount_MilestonesHaveNoEffectAnymore() public {
        rmht.setMilestonesReached(1000);
        assertEq(custodian.unlockedAmount(), 0, "les paliers ne doivent plus rien debloquer");

        vm.warp(uint256(UNLOCK_AT));
        assertEq(custodian.unlockedAmount(), FOUNDER_ALLOCATION);
    }

    /// @notice Corollaire : le déblocage ne dépend plus du tout de l'état de
    ///         RMHT.sol. Même sans `setRmhtToken()`, `unlockedAmount()`
    ///         répond — c'est devenu une fonction purement temporelle, sans
    ///         appel externe (c'est ce que SolidityScan flaguait en High).
    function test_UnlockedAmount_IndependentOfRmhtBeingSet() public {
        RMHTFounderCustodian fresh = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
        assertFalse(fresh.rmhtSet());
        assertEq(fresh.unlockedAmount(), 0);

        vm.warp(uint256(UNLOCK_AT));
        assertEq(fresh.unlockedAmount(), FOUNDER_ALLOCATION);
    }

    function testFuzz_UnlockedAmount_IsAStepFunctionOfTime(uint48 when) public {
        vm.assume(when >= T0);
        vm.warp(uint256(when));
        assertEq(
            custodian.unlockedAmount(),
            when >= UNLOCK_AT ? FOUNDER_ALLOCATION : 0
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  claim() — pull-payment, un seul retrait utile en pratique
    // ═══════════════════════════════════════════════════════════════════════

    function test_RevertClaim_NotBeneficiary() public {
        vm.warp(uint256(UNLOCK_AT));
        vm.prank(stranger);
        vm.expectRevert(RMHTFounderCustodian.NotBeneficiary.selector);
        custodian.claim();
    }

    function test_RevertClaim_NothingToClaim() public {
        vm.prank(beneficiary);
        vm.expectRevert(RMHTFounderCustodian.NothingToClaim.selector);
        custodian.claim();
    }

    /// @notice Même le bénéficiaire ne peut rien retirer une seconde avant.
    function test_RevertClaim_OneSecondBeforeUnlock() public {
        vm.warp(uint256(UNLOCK_AT) - 1);
        vm.prank(beneficiary);
        vm.expectRevert(RMHTFounderCustodian.NothingToClaim.selector);
        custodian.claim();
    }

    function test_Claim_FullAllocationAtUnlockTime() public {
        vm.warp(uint256(UNLOCK_AT));

        vm.expectEmit(true, true, true, true);
        emit Claimed(beneficiary, FOUNDER_ALLOCATION, FOUNDER_ALLOCATION);
        vm.prank(beneficiary);
        custodian.claim();

        assertEq(rmht.balanceOf(beneficiary), FOUNDER_ALLOCATION);
        assertEq(custodian.claimedAmount(), FOUNDER_ALLOCATION);
        assertEq(rmht.balanceOf(address(custodian)), 0);
    }

    function test_RevertClaim_NothingLeftAfterFullClaim() public {
        vm.warp(uint256(UNLOCK_AT));
        vm.startPrank(beneficiary);
        custodian.claim();
        vm.expectRevert(RMHTFounderCustodian.NothingToClaim.selector);
        custodian.claim();
        vm.stopPrank();
    }

    function test_ClaimableNow_ZeroThenFullThenZero() public {
        assertEq(custodian.claimableNow(), 0);

        vm.warp(uint256(UNLOCK_AT));
        assertEq(custodian.claimableNow(), FOUNDER_ALLOCATION);

        vm.prank(beneficiary);
        custodian.claim();
        assertEq(custodian.claimableNow(), 0);
    }

    function test_RevertClaim_TransferFailed() public {
        vm.warp(uint256(UNLOCK_AT));
        rmht.setTransferShouldFail(true);
        vm.prank(beneficiary);
        vm.expectRevert(RMHTFounderCustodian.TransferFailed.selector);
        custodian.claim();
    }

    function test_RevertClaim_RmhtNotSetYet() public {
        RMHTFounderCustodian fresh = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);
        vm.warp(uint256(UNLOCK_AT));
        vm.prank(beneficiary); // bénéficiaire correct : on isole bien le check rmhtSet
        vm.expectRevert(RMHTFounderCustodian.RmhtNotSetYet.selector);
        fresh.claim();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  rescueEth() — uniquement l'ETH envoyé par erreur
    // ═══════════════════════════════════════════════════════════════════════

    function test_RescueEth_Success() public {
        vm.deal(address(custodian), 1 ether);
        uint256 balBefore = owner.balance;

        vm.expectEmit(true, true, true, true);
        emit EthRescued(owner, 1 ether);
        vm.prank(owner);
        custodian.rescueEth(payable(owner));

        assertEq(owner.balance, balBefore + 1 ether);
        assertEq(address(custodian).balance, 0);
    }

    function test_RevertRescueEth_NothingToRescue() public {
        vm.prank(owner);
        vm.expectRevert(RMHTFounderCustodian.NothingToRescue.selector);
        custodian.rescueEth(payable(owner));
    }

    function test_RevertRescueEth_NotOwner() public {
        vm.deal(address(custodian), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        custodian.rescueEth(payable(stranger));
    }

    function test_RevertRescueEth_ZeroAddress() public {
        vm.deal(address(custodian), 1 ether);
        vm.prank(owner);
        vm.expectRevert(bytes("RMHTFounder: zero address"));
        custodian.rescueEth(payable(address(0)));
    }

    function test_Receive_AcceptsEth() public {
        (bool success, ) = address(custodian).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(custodian).balance, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  rescueEth() — branche EthTransferFailed (jamais exercée avant)
    // ═══════════════════════════════════════════════════════════════════════

    function test_RevertRescueEth_TransferFailed() public {
        NonPayableReceiverFounder badRecipient = new NonPayableReceiverFounder();
        vm.deal(address(custodian), 1 ether);
        vm.prank(owner);
        vm.expectRevert(RMHTFounderCustodian.EthTransferFailed.selector);
        custodian.rescueEth(payable(address(badRecipient)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ReentrancyGuard — jamais réellement testé avant (verrou présent sur
    //  claim() et rescueEth(), mais aucun test ne prouvait qu'il bloquait une
    //  vraie tentative de réentrance, seulement des require() indépendants).
    // ═══════════════════════════════════════════════════════════════════════

    function test_RescueEth_ReentrancyGuardBlocksReentry_ViaRescueEth() public {
        MaliciousReentrantFounderRescue attacker = new MaliciousReentrantFounderRescue(false);
        attacker.setTarget(custodian);
        vm.deal(address(custodian), 1 ether);

        vm.prank(owner);
        custodian.rescueEth(payable(address(attacker)));

        assertTrue(attacker.reentered(), "reentrancy attempt never fired");
        assertTrue(attacker.reentrancyReverted(), "reentrant call should have reverted");
        // L'opération légitime elle-même n'a pas été bloquée par le verrou.
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(custodian).balance, 0);
    }

    function test_RescueEth_ReentrancyGuardBlocksReentry_ViaClaim() public {
        // Prouve que le verrou est partagé entre rescueEth() et claim() —
        // pas un booléen local à chaque fonction. L'attaquant EST le
        // `beneficiary` réel du custodian : si le blocage venait du check
        // `msg.sender != beneficiary` plutôt que du ReentrancyGuard, ce test
        // échouerait, puisque l'attaquant passerait ce check-là sans problème.
        MaliciousReentrantFounderRescue attacker = new MaliciousReentrantFounderRescue(true);

        vm.prank(owner);
        RMHTFounderCustodian freshCustodian = new RMHTFounderCustodian(owner, address(attacker), UNLOCK_AT);
        attacker.setTarget(freshCustodian);

        MockRMHTWithMilestones freshRmht = new MockRMHTWithMilestones();
        freshRmht.mint(address(freshCustodian), FOUNDER_ALLOCATION);
        vm.prank(owner);
        freshCustodian.setRmhtToken(address(freshRmht));
        // Rend claim() réellement réclamable — si le verrou ne bloquait pas,
        // la réentrance réussirait et viderait toute l'allocation.
        vm.warp(uint256(UNLOCK_AT));

        vm.deal(address(freshCustodian), 1 ether);
        vm.prank(owner);
        freshCustodian.rescueEth(payable(address(attacker)));

        assertTrue(attacker.reentered(), "reentrancy attempt never fired");
        assertTrue(attacker.reentrancyReverted(), "reentrant claim() should have reverted despite attacker being the real beneficiary");
        assertEq(freshCustodian.claimedAmount(), 0, "claim() must not have succeeded during reentrancy");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Ownable2Step — transferOwnership()/acceptOwnership()/renounceOwnership()
    //  jamais testées du tout avant ce fichier (même trou que trouvé la
    //  session précédente sur RMHTAirdropCustodian.sol).
    // ═══════════════════════════════════════════════════════════════════════

    address newOwnerCandidate = address(0xB0B);

    function test_TransferOwnership_StartsPending() public {
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(owner, newOwnerCandidate);
        vm.prank(owner);
        custodian.transferOwnership(newOwnerCandidate);

        assertEq(custodian.pendingOwner(), newOwnerCandidate);
        // Ownership ne change PAS tant que acceptOwnership() n'est pas appelé.
        assertEq(custodian.owner(), owner);
    }

    function test_RevertTransferOwnership_NotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        custodian.transferOwnership(newOwnerCandidate);
    }

    function test_RevertTransferOwnership_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Ownable: zero address"));
        custodian.transferOwnership(address(0));
    }

    function test_AcceptOwnership_Success() public {
        vm.prank(owner);
        custodian.transferOwnership(newOwnerCandidate);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(owner, newOwnerCandidate);
        vm.prank(newOwnerCandidate);
        custodian.acceptOwnership();

        assertEq(custodian.owner(), newOwnerCandidate);
        assertEq(custodian.pendingOwner(), address(0));

        // Le nouvel owner a bien les pouvoirs onlyOwner ; l'ancien ne les a plus.
        vm.deal(address(custodian), 1 ether);
        vm.prank(newOwnerCandidate);
        custodian.rescueEth(payable(newOwnerCandidate));

        vm.deal(address(custodian), 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, owner));
        custodian.rescueEth(payable(owner));
    }

    function test_RevertAcceptOwnership_NotPendingOwner() public {
        vm.prank(owner);
        custodian.transferOwnership(newOwnerCandidate);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        custodian.acceptOwnership();
    }

    function test_RenounceOwnership_Success() public {
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(owner, address(0));
        vm.prank(owner);
        custodian.renounceOwnership();

        assertEq(custodian.owner(), address(0));

        // Plus aucune fonction onlyOwner n'est appelable, par personne.
        vm.deal(address(custodian), 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, owner));
        custodian.rescueEth(payable(owner));
    }

    function test_RevertRenounceOwnership_NotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        custodian.renounceOwnership();
    }

    function test_RenounceOwnership_ClearsPendingOwner() public {
        // Une proposition en cours ne doit pas survivre à un renounce —
        // sinon un pendingOwner oublié pourrait accepter après coup.
        vm.startPrank(owner);
        custodian.transferOwnership(newOwnerCandidate);
        custodian.renounceOwnership();
        vm.stopPrank();

        assertEq(custodian.pendingOwner(), address(0));
        vm.prank(newOwnerCandidate);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, newOwnerCandidate));
        custodian.acceptOwnership();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  REWARDS DE PALIER (AJOUT 28/08/2026) — harvestVaultRewards() /
    //  claimReward() / claimableRewardsNow(). Le point à démontrer : ces
    //  rewards sont réclamables À TOUT MOMENT, y compris pendant l'année de
    //  verrou du principal, et sans jamais y toucher.
    // ═══════════════════════════════════════════════════════════════════════

    function test_HarvestVaultRewards_RapatrieDepuisRmht() public {
        rmht.accrueReward(address(custodian), 1_000 ether);

        uint256 balBefore = rmht.balanceOf(address(custodian));
        custodian.harvestVaultRewards();

        assertEq(rmht.balanceOf(address(custodian)) - balBefore, 1_000 ether);
        assertEq(custodian.totalHarvestedRewards(), 1_000 ether);
        assertEq(custodian.claimedRewards(), 0);
        assertEq(custodian.claimableRewardsNow(), 1_000 ether);
    }

    function test_HarvestVaultRewards_EstPermissionless() public {
        rmht.accrueReward(address(custodian), 42 ether);

        vm.prank(stranger); // n'importe qui, pas seulement le bénéficiaire
        custodian.harvestVaultRewards();

        assertEq(custodian.totalHarvestedRewards(), 42 ether);
    }

    function test_HarvestVaultRewards_EmitEvent() public {
        rmht.accrueReward(address(custodian), 500 ether);

        vm.expectEmit(true, true, true, true);
        emit RewardsHarvested(500 ether, 500 ether);
        custodian.harvestVaultRewards();
    }

    function test_HarvestVaultRewards_AppelsSuccessifsCumulent() public {
        rmht.accrueReward(address(custodian), 100 ether);
        custodian.harvestVaultRewards();
        rmht.accrueReward(address(custodian), 300 ether);
        custodian.harvestVaultRewards();

        assertEq(custodian.totalHarvestedRewards(), 400 ether);
    }

    /// @dev FIX 28/08/2026 : RMHT.claimRewards() revert ("RMHT: No rewards")
    ///      quand il n'y a rien à réclamer. harvestVaultRewards() étant
    ///      permissionless et appelée en boucle par un bot après chaque
    ///      palier, elle teste d'abord pendingRewardsOf() et ne fait rien
    ///      plutôt que de revert.
    function test_HarvestVaultRewards_NoOpSiRienAAccumuler() public {
        uint256 balBefore = rmht.balanceOf(address(custodian));

        custodian.harvestVaultRewards(); // ne doit pas revert

        assertEq(rmht.balanceOf(address(custodian)), balBefore);
        assertEq(custodian.totalHarvestedRewards(), 0);
    }

    /// @dev Le no-op doit relâcher le verrou nonReentrant. Écrit en `return;`
    ///      sous le modifier, `_status` resterait à ENTERED et le second
    ///      appel reverterait — c'est le bug rencontré sur
    ///      RMHT.pokeMilestone() le 21/08/2026.
    function test_HarvestVaultRewards_NoOpNeBloquePasLeVerrouReentrance() public {
        custodian.harvestVaultRewards();
        custodian.harvestVaultRewards();

        rmht.accrueReward(address(custodian), 7 ether);
        custodian.harvestVaultRewards();
        assertEq(custodian.totalHarvestedRewards(), 7 ether);
    }

    function test_RevertHarvestVaultRewards_RmhtPasEncoreRegle() public {
        vm.prank(owner);
        RMHTFounderCustodian fresh = new RMHTFounderCustodian(owner, beneficiary, UNLOCK_AT);

        vm.expectRevert(RMHTFounderCustodian.RmhtNotSetYet.selector);
        fresh.harvestVaultRewards();
    }

    /// @notice LE test qui compte : les rewards sont réclamables AVANT
    ///         `unlockTime`, alors que le principal, lui, reste intégralement
    ///         bloqué. C'est toute la raison d'être de l'ajout du 28/08.
    function test_ClaimReward_PossibleAvantUnlockTime() public {
        rmht.accrueReward(address(custodian), 1_234 ether);
        custodian.harvestVaultRewards();

        assertTrue(block.timestamp < custodian.unlockTime());
        assertEq(custodian.unlockedAmount(), 0); // principal toujours verrouillé

        uint256 balBefore = rmht.balanceOf(beneficiary);
        vm.prank(beneficiary);
        custodian.claimReward();

        assertEq(rmht.balanceOf(beneficiary) - balBefore, 1_234 ether);
        assertEq(custodian.claimedRewards(), 1_234 ether);
        assertEq(custodian.claimableRewardsNow(), 0);
        // Le principal n'a pas bougé d'un iota.
        assertEq(custodian.claimedAmount(), 0);
        assertEq(rmht.balanceOf(address(custodian)), FOUNDER_ALLOCATION);
    }

    function test_ClaimReward_EmitEvent() public {
        rmht.accrueReward(address(custodian), 11 ether);
        custodian.harvestVaultRewards();

        vm.expectEmit(true, true, true, true);
        emit RewardClaimed(beneficiary, 11 ether);
        vm.prank(beneficiary);
        custodian.claimReward();
    }

    function test_RevertClaimReward_NotBeneficiary() public {
        rmht.accrueReward(address(custodian), 10 ether);
        custodian.harvestVaultRewards();

        vm.prank(stranger);
        vm.expectRevert(RMHTFounderCustodian.NotBeneficiary.selector);
        custodian.claimReward();
    }

    function test_RevertClaimReward_RienAReclamer() public {
        vm.prank(beneficiary);
        vm.expectRevert(RMHTFounderCustodian.NothingToClaimReward.selector);
        custodian.claimReward();
    }

    function test_RevertClaimReward_DeuxiemeAppelSansNouveauHarvest() public {
        rmht.accrueReward(address(custodian), 50 ether);
        custodian.harvestVaultRewards();

        vm.prank(beneficiary);
        custodian.claimReward();

        vm.prank(beneficiary);
        vm.expectRevert(RMHTFounderCustodian.NothingToClaimReward.selector);
        custodian.claimReward();
    }

    function test_RevertClaimReward_TransferFailed() public {
        rmht.accrueReward(address(custodian), 5 ether);
        custodian.harvestVaultRewards();
        rmht.setTransferShouldFail(true);

        vm.prank(beneficiary);
        vm.expectRevert(RMHTFounderCustodian.TransferFailed.selector);
        custodian.claimReward();
    }

    /// @notice Plusieurs paliers d'affilée : harvest → claim → harvest → claim,
    ///         toujours avant `unlockTime`. La comptabilité doit rester exacte
    ///         et n'entamer jamais le principal.
    function test_ClaimReward_PlusieursPaliersSuccessifs() public {
        rmht.accrueReward(address(custodian), 100 ether);
        custodian.harvestVaultRewards();
        vm.prank(beneficiary);
        custodian.claimReward();

        rmht.accrueReward(address(custodian), 250 ether);
        custodian.harvestVaultRewards();
        vm.prank(beneficiary);
        custodian.claimReward();

        assertEq(custodian.totalHarvestedRewards(), 350 ether);
        assertEq(custodian.claimedRewards(), 350 ether);
        assertEq(rmht.balanceOf(beneficiary), 350 ether);
        assertEq(rmht.balanceOf(address(custodian)), FOUNDER_ALLOCATION);
    }

    /// @notice Non-régression du principal : après `unlockTime`, claim() sort
    ///         toujours exactement FOUNDER_ALLOCATION, ni plus (il ne rafle
    ///         pas les rewards non réclamées) ni moins.
    function test_Claim_PrincipalIntactMemeAvecRewardsNonReclamees() public {
        rmht.accrueReward(address(custodian), 900 ether);
        custodian.harvestVaultRewards(); // rewards sur le solde, pas encore réclamées

        vm.warp(uint256(UNLOCK_AT) + 1);
        vm.prank(beneficiary);
        custodian.claim();

        assertEq(custodian.claimedAmount(), FOUNDER_ALLOCATION);
        assertEq(rmht.balanceOf(beneficiary), FOUNDER_ALLOCATION);
        // Les rewards restent dues et réclamables séparément.
        assertEq(custodian.claimableRewardsNow(), 900 ether);
        assertEq(rmht.balanceOf(address(custodian)), 900 ether);

        vm.prank(beneficiary);
        custodian.claimReward();
        assertEq(rmht.balanceOf(beneficiary), FOUNDER_ALLOCATION + 900 ether);
        assertEq(rmht.balanceOf(address(custodian)), 0);
    }

    /// @notice Ordre inverse : rewards réclamées d'abord, principal ensuite.
    function test_ClaimReward_PuisClaimPrincipal() public {
        rmht.accrueReward(address(custodian), 60 ether);
        custodian.harvestVaultRewards();
        vm.prank(beneficiary);
        custodian.claimReward();

        vm.warp(uint256(UNLOCK_AT) + 1);
        vm.prank(beneficiary);
        custodian.claim();

        assertEq(rmht.balanceOf(beneficiary), FOUNDER_ALLOCATION + 60 ether);
        assertEq(custodian.claimedAmount(), FOUNDER_ALLOCATION);
        assertEq(custodian.claimedRewards(), 60 ether);
    }

    /// @notice Les rewards continuent d'être récoltables APRÈS le retrait du
    ///         principal, tant que RMHT.sol en doit encore à ce contrat.
    function test_HarvestVaultRewards_ApresRetraitDuPrincipal() public {
        vm.warp(uint256(UNLOCK_AT) + 1);
        vm.prank(beneficiary);
        custodian.claim();
        assertEq(rmht.balanceOf(address(custodian)), 0);

        rmht.accrueReward(address(custodian), 3 ether);
        custodian.harvestVaultRewards();

        vm.prank(beneficiary);
        custodian.claimReward();
        assertEq(rmht.balanceOf(beneficiary), FOUNDER_ALLOCATION + 3 ether);
    }
}
