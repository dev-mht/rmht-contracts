// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../src/RMHTAirdropCustodian.sol";
import "./mocks/MockRMHTWithRewards.sol";
import "./mocks/MaliciousReentrantAirdropRescue_20260825_1600.sol";

/// @notice Contrat sans receive()/fallback() — utilisé pour tester la branche
///         EthTransferFailed() de rescueEth().
contract NonPayableReceiverAirdrop {}

contract RMHTAirdropCustodianTest is Test {
    RMHTAirdropCustodian custodian;
    MockRMHTWithRewards rmht;

    address owner = address(0xA11CE);
    address userA = address(0xA001); // grosse allocation
    address userB = address(0xB002); // petite allocation
    address userC = address(0xC003); // allocation à zéro (cas limite)
    address stranger = address(0xD004); // n'a jamais d'allocation

    uint256 constant AMOUNT_A = 8_000_000 ether;
    uint256 constant AMOUNT_B = 2_000_000 ether;
    uint256 constant TOTAL_ALLOCATED = AMOUNT_A + AMOUNT_B; // userC = 0
    uint256 constant CUSTODIAN_BALANCE = 18_086_021 ether;  // solde réel du custodian communauté (> alloué, comme en prod) — fondateur sorti le 22/08/2026 vers RMHTFounderCustodian

    uint256 constant PRECISION = 1e36;

    event RewardsHarvested(uint256 amount, uint256 newRewardPerShare);
    event RewardClaimed(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    function setUp() public {
        vm.warp(1_700_000_000);

        vm.prank(owner);
        custodian = new RMHTAirdropCustodian(owner);

        rmht = new MockRMHTWithRewards();
        rmht.mint(address(custodian), CUSTODIAN_BALANCE);

        vm.startPrank(owner);
        custodian.setRmhtToken(address(rmht));
        custodian.setUnlockTime(uint48(block.timestamp + 365 days));

        address[] memory users = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        users[0] = userA; amounts[0] = AMOUNT_A;
        users[1] = userB; amounts[1] = AMOUNT_B;
        users[2] = userC; amounts[2] = 0;
        custodian.setAllocations(users, amounts);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  setUp / cadrage
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetUp_ActiveAllocatedMatchesNonZeroAllocations() public view {
        // activeAllocated inclut userC (isSet=true, amount=0) mais sa part ne pèse rien
        assertEq(custodian.activeAllocated(), TOTAL_ALLOCATED);
        assertEq(custodian.totalAllocated(), TOTAL_ALLOCATED);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Ownership 2 temps (NOUVEAU) — jamais exercé jusqu'ici sur ce contrat
    // ═══════════════════════════════════════════════════════════════════════

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        custodian.transferOwnership(stranger);
    }

    function test_TransferOwnership_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Ownable: zero address"));
        custodian.transferOwnership(address(0));
    }

    function test_TransferOwnership_SetsPendingOwner() public {
        vm.prank(owner);
        custodian.transferOwnership(stranger);

        assertEq(custodian.owner(), owner); // pas encore transféré
        assertEq(custodian.pendingOwner(), stranger);
    }

    function test_AcceptOwnership_RevertsIfNotPending() public {
        vm.prank(owner);
        custodian.transferOwnership(stranger);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, userA));
        custodian.acceptOwnership();
    }

    function test_AcceptOwnership_Success() public {
        vm.prank(owner);
        custodian.transferOwnership(stranger);

        vm.prank(stranger);
        custodian.acceptOwnership();

        assertEq(custodian.owner(), stranger);
        assertEq(custodian.pendingOwner(), address(0));

        // L'ancien owner a bien perdu tout pouvoir onlyOwner.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, owner));
        custodian.rescueEth(payable(owner));
    }

    function test_RenounceOwnership_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, stranger));
        custodian.renounceOwnership();
    }

    function test_RenounceOwnership_Success() public {
        vm.prank(owner);
        custodian.renounceOwnership();
        assertEq(custodian.owner(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  setRmhtToken() (NOUVEAU) — seul le succès (dans setUp) était exercé
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetRmhtToken_OnlyOwner() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.setRmhtToken(address(rmht));
    }

    function test_SetRmhtToken_RevertsIfAlreadySet() public {
        // `custodian` (celui de setUp) a déjà rmht réglé.
        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.RmhtAlreadySet.selector);
        custodian.setRmhtToken(address(rmht));
    }

    function test_SetRmhtToken_RevertsOnZeroAddress() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.prank(owner);
        vm.expectRevert(bytes("RMHTAirdrop: zero address"));
        fresh.setRmhtToken(address(0));
    }

    function test_SetRmhtToken_RevertsIfNotAContract() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.TokenNotContract.selector);
        fresh.setRmhtToken(stranger); // EOA, pas de code
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  setUnlockTime() (NOUVEAU) — seul le succès (dans setUp) était exercé
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetUnlockTime_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, address(this)));
        custodian.setUnlockTime(uint48(block.timestamp + 1 days));
    }

    function test_SetUnlockTime_RevertsIfRmhtNotSetYet() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.RmhtNotSetYet.selector);
        fresh.setUnlockTime(uint48(block.timestamp + 1 days));
    }

    function test_SetUnlockTime_RevertsIfAlreadySet() public {
        // `custodian` a déjà unlockTime réglé dans setUp.
        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.UnlockTimeAlreadySet.selector);
        custodian.setUnlockTime(uint48(block.timestamp + 1 days));
    }

    function test_SetUnlockTime_RevertsIfNotFuture() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.startPrank(owner);
        fresh.setRmhtToken(address(rmht));
        vm.expectRevert(RMHTAirdropCustodian.UnlockTimeMustBeFuture.selector);
        fresh.setUnlockTime(uint48(block.timestamp));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  setAllocations() (NOUVEAU) — seul le succès (dans setUp) était exercé
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetAllocations_OnlyOwner() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = stranger;
        amounts[0] = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, address(this)));
        custodian.setAllocations(users, amounts);
    }

    function test_SetAllocations_RevertsOnLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        users[0] = stranger;
        users[1] = userA;
        amounts[0] = 1 ether;

        vm.prank(owner);
        vm.expectRevert(bytes("RMHTAirdrop: length mismatch"));
        custodian.setAllocations(users, amounts);
    }

    function test_SetAllocations_RevertsOnEmptyBatch() public {
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(owner);
        vm.expectRevert(bytes("RMHTAirdrop: empty batch"));
        custodian.setAllocations(users, amounts);
    }

    function test_SetAllocations_RevertsOnBatchTooLarge() public {
        address[] memory users = new address[](101);
        uint256[] memory amounts = new uint256[](101);
        for (uint256 i; i < 101; ++i) {
            users[i] = address(uint160(0x9000 + i));
            amounts[i] = 0;
        }

        vm.prank(owner);
        vm.expectRevert(bytes("RMHTAirdrop: batch too large"));
        custodian.setAllocations(users, amounts);
    }

    function test_SetAllocations_RevertsOnZeroAddressInBatch() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = address(0);
        amounts[0] = 1 ether;

        vm.prank(owner);
        vm.expectRevert(bytes("RMHTAirdrop: zero address"));
        custodian.setAllocations(users, amounts);
    }

    function test_SetAllocations_RevertsIfAlreadySetForUser() public {
        // userA a déjà une allocation fixée dans setUp.
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = userA;
        amounts[0] = 1 ether;

        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.AllocationAlreadySet.selector);
        custodian.setAllocations(users, amounts);
    }

    function test_SetAllocations_RevertsIfExceedsAvailableBalance() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        MockRMHTWithRewards freshRmht = new MockRMHTWithRewards();
        freshRmht.mint(address(fresh), 100 ether); // solde volontairement insuffisant

        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = stranger;
        amounts[0] = 200 ether; // > solde réel du contrat

        vm.startPrank(owner);
        fresh.setRmhtToken(address(freshRmht));
        vm.expectRevert(RMHTAirdropCustodian.ExceedsAvailableBalance.selector);
        fresh.setAllocations(users, amounts);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  rescueEth() (NOUVEAU) — jamais testé du tout sur ce contrat
    // ═══════════════════════════════════════════════════════════════════════

    function test_RescueEth_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable2Step.OwnableUnauthorizedAccount.selector, address(this)));
        custodian.rescueEth(payable(owner));
    }

    function test_RescueEth_RevertsOnZeroAddress() public {
        vm.deal(address(custodian), 1 ether);
        vm.prank(owner);
        vm.expectRevert(bytes("RMHTAirdrop: zero address"));
        custodian.rescueEth(payable(address(0)));
    }

    function test_RescueEth_RevertsIfNothingToRescue() public {
        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.NothingToRescue.selector);
        custodian.rescueEth(payable(owner));
    }

    function test_RescueEth_Success() public {
        vm.deal(address(custodian), 3 ether);
        uint256 before = owner.balance;

        vm.prank(owner);
        custodian.rescueEth(payable(owner));

        assertEq(owner.balance, before + 3 ether);
        assertEq(address(custodian).balance, 0);
    }

    /// @dev Contrat sans receive()/fallback(), pour déclencher EthTransferFailed().
    function test_RescueEth_RevertsIfTransferFails() public {
        vm.deal(address(custodian), 1 ether);
        NonPayableReceiverAirdrop badRecipient = new NonPayableReceiverAirdrop();

        vm.prank(owner);
        vm.expectRevert(RMHTAirdropCustodian.EthTransferFailed.selector);
        custodian.rescueEth(payable(address(badRecipient)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Déblocage hybride par palier (NOUVEAU) — seul unlockTime était testé
    // ═══════════════════════════════════════════════════════════════════════

    function test_Claim_UnlockedByMilestone_AvantUnlockTime() public {
        rmht.setMilestonesReached(custodian.UNLOCK_MILESTONE());

        // unlockTime volontairement PAS atteint — seul le palier débloque ici.
        vm.prank(userA);
        custodian.claim();

        assertEq(rmht.balanceOf(userA), AMOUNT_A);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  harvestVaultRewards()
    // ═══════════════════════════════════════════════════════════════════════

    function test_HarvestVaultRewards_RapatrieDepuisRmhtEtAugmenteBalance() public {
        uint256 harvested = 1_000 ether;
        rmht.accrueReward(address(custodian), harvested);

        uint256 balBefore = rmht.balanceOf(address(custodian));
        custodian.harvestVaultRewards();
        uint256 balAfter = rmht.balanceOf(address(custodian));

        assertEq(balAfter - balBefore, harvested);
    }

    function test_HarvestVaultRewards_RewardPerShareAuBonProrata() public {
        uint256 harvested = 1_000 ether;
        rmht.accrueReward(address(custodian), harvested);

        custodian.harvestVaultRewards();

        uint256 expected = (harvested * PRECISION) / TOTAL_ALLOCATED;
        assertEq(custodian.rewardPerShare(), expected);
    }

    function test_HarvestVaultRewards_EmitEvent() public {
        uint256 harvested = 500 ether;
        rmht.accrueReward(address(custodian), harvested);

        uint256 expected = (harvested * PRECISION) / TOTAL_ALLOCATED;
        vm.expectEmit(true, true, true, true);
        emit RewardsHarvested(harvested, expected);
        custodian.harvestVaultRewards();
    }

    function test_HarvestVaultRewards_EstPermissionless() public {
        rmht.accrueReward(address(custodian), 100 ether);
        vm.prank(stranger);
        custodian.harvestVaultRewards(); // ne doit pas revert, n'importe qui peut appeler
        assertEq(custodian.rewardPerShare(), (100 ether * PRECISION) / TOTAL_ALLOCATED);
    }

    /// @dev FIX 28/08/2026 — ce test asserte l'inverse de ce qu'il assertait
    ///      avant. Comportement d'origine : harvestVaultRewards() REVERTAIT
    ///      ("RMHT: No rewards") quand rien n'avait été accumulé côté
    ///      RMHT.sol, alors que le contrat annonçait un no-op silencieux ;
    ///      c'était signalé ici même comme "à fixer (vérifier
    ///      pendingRewardsOf() avant d'appeler claimRewards())". C'est fait :
    ///      la fonction teste maintenant pendingRewardsOf(address(this)) et
    ///      ne fait rien si le montant est nul. Elle est permissionless et
    ///      typiquement appelée en boucle par un bot après chaque palier —
    ///      un appel à vide ne doit pas coûter une transaction en revert.
    function test_HarvestVaultRewards_NoOpSiRienAAccumulerCotesRmht() public {
        uint256 balBefore = rmht.balanceOf(address(custodian));
        uint256 rpsBefore = custodian.rewardPerShare();

        custodian.harvestVaultRewards(); // ne doit PLUS revert

        assertEq(rmht.balanceOf(address(custodian)), balBefore);
        assertEq(custodian.rewardPerShare(), rpsBefore);
    }

    /// @dev Corollaire du fix ci-dessus : le verrou nonReentrant doit être
    ///      correctement relâché après un appel à vide. C'est le piège du
    ///      `return` sous modifier rencontré sur RMHT.pokeMilestone() le
    ///      21/08/2026 — si le no-op avait été écrit `return;` au lieu d'un
    ///      `if (...) { ... }`, _status resterait à ENTERED et le SECOND
    ///      appel ci-dessous reverterait avec ReentrancyGuardReentrantCall().
    function test_HarvestVaultRewards_NoOpNeBloquePasLeVerrouReentrance() public {
        custodian.harvestVaultRewards(); // appel à vide #1
        custodian.harvestVaultRewards(); // appel à vide #2 — doit passer aussi

        // ...et un vrai harvest doit encore fonctionner après coup.
        rmht.accrueReward(address(custodian), 250 ether);
        custodian.harvestVaultRewards();
        assertEq(custodian.rewardPerShare(), (250 ether * PRECISION) / TOTAL_ALLOCATED);
    }

    /// @dev Garde-fou de diagnostic ajouté le 28/08/2026 : appelée avant
    ///      setRmhtToken(), la fonction dit pourquoi elle refuse au lieu
    ///      d'aller taper sur address(0).
    function test_HarvestVaultRewards_RevertSiRmhtPasEncoreRegle() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.expectRevert(RMHTAirdropCustodian.RmhtNotSetYet.selector);
        fresh.harvestVaultRewards();
    }

    /// @dev Idem sur claim() : le check rmhtSet est passé AVANT l'appel
    ///      externe milestonesReached(), qui partait sinon sur address(0).
    function test_Claim_RevertSiRmhtPasEncoreRegle() public {
        RMHTAirdropCustodian fresh = new RMHTAirdropCustodian(owner);
        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.RmhtNotSetYet.selector);
        fresh.claim();
    }

    /// @notice Cas limite : activeAllocated == 0 (tout le monde a déjà claim son principal).
    ///         Ici la division par zéro est bien évitée — les tokens rapatriés restent
    ///         sur le solde du custodian sans être répartis, rewardPerShare ne bouge pas.
    function test_HarvestVaultRewards_ActiveAllocatedZero_PasDeDivisionParZero() public {
        // Tout le monde retire son principal → activeAllocated tombe à 0
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(userA);
        custodian.claim();
        vm.prank(userB);
        custodian.claim();
        // userC a une allocation de 0 → NothingToClaim(), on ne l'appelle pas.
        assertEq(custodian.activeAllocated(), 0);

        rmht.accrueReward(address(custodian), 777 ether);
        uint256 balBefore = rmht.balanceOf(address(custodian));

        custodian.harvestVaultRewards(); // ne doit pas revert (pas de div/0)

        assertEq(rmht.balanceOf(address(custodian)) - balBefore, 777 ether); // rapatrié mais pas réparti
        assertEq(custodian.rewardPerShare(), 0);
    }

    function test_HarvestVaultRewards_PlusieursAppelsSuccessifsCumulent() public {
        rmht.accrueReward(address(custodian), 100 ether);
        custodian.harvestVaultRewards();
        uint256 rpsAfterFirst = custodian.rewardPerShare();

        rmht.accrueReward(address(custodian), 300 ether);
        custodian.harvestVaultRewards();
        uint256 rpsAfterSecond = custodian.rewardPerShare();

        assertGt(rpsAfterSecond, rpsAfterFirst);
        assertEq(rpsAfterSecond, ((100 ether + 300 ether) * PRECISION) / TOTAL_ALLOCATED);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  claimReward()
    // ═══════════════════════════════════════════════════════════════════════

    function test_ClaimReward_CalculDeltaParUtilisateurAuProrataDeSonAllocation() public {
        uint256 harvested = 1_000 ether; // rewardPerShare = harvested*PRECISION/TOTAL_ALLOCATED
        rmht.accrueReward(address(custodian), harvested);
        custodian.harvestVaultRewards();

        uint256 expectedA = (AMOUNT_A * custodian.rewardPerShare()) / PRECISION;
        uint256 expectedB = (AMOUNT_B * custodian.rewardPerShare()) / PRECISION;

        assertEq(custodian.pendingRewardOf(userA), expectedA);
        assertEq(custodian.pendingRewardOf(userB), expectedB);
        // userA a 4x l'allocation de userB → 4x le reward
        assertEq(expectedA, expectedB * 4);

        vm.prank(userA);
        custodian.claimReward();
        assertEq(rmht.balanceOf(userA), expectedA);
    }

    function test_ClaimReward_MiseAJourSnapshot_PasDeDoubleClaim() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();

        vm.prank(userA);
        custodian.claimReward();
        uint256 firstClaim = rmht.balanceOf(userA);
        assertGt(firstClaim, 0);

        // Deuxième claim immédiat, sans nouveau harvest → rien à réclamer
        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.NothingToClaimReward.selector);
        custodian.claimReward();

        assertEq(rmht.balanceOf(userA), firstClaim); // inchangé
    }

    function test_ClaimReward_RevertSiRienDeNouveauDepuisLeDernierClaim() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();
        vm.prank(userA);
        custodian.claimReward();

        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.NothingToClaimReward.selector);
        custodian.claimReward();
    }

    function test_ClaimReward_AvantToutHarvest_Revert() public {
        // Le rapport de session envisageait un "retour 0 sans erreur" ici, mais le
        // code réel fait `if (reward == 0) revert NothingToClaimReward()` — testé
        // tel quel pour documenter le comportement effectif du contrat.
        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.NothingToClaimReward.selector);
        custodian.claimReward();
    }

    function test_ClaimReward_AllocationZero_RienARecevoirMemeApresHarvest() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();

        assertEq(custodian.pendingRewardOf(userC), 0);
        vm.prank(userC);
        vm.expectRevert(RMHTAirdropCustodian.NothingToClaimReward.selector);
        custodian.claimReward();
    }

    function test_ClaimReward_AdresseSansAllocation_Revert() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();

        vm.prank(stranger);
        vm.expectRevert(RMHTAirdropCustodian.NothingToClaimReward.selector);
        custodian.claimReward();
    }

    function test_ClaimReward_RevertSiTransferEchoue() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();

        rmht.setTransferShouldFail(true);
        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.TransferFailed.selector);
        custodian.claimReward();
    }

    function test_ClaimReward_EmitEvent() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();

        uint256 expected = custodian.pendingRewardOf(userA);
        vm.expectEmit(true, true, true, true);
        emit RewardClaimed(userA, expected);
        vm.prank(userA);
        custodian.claimReward();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Interaction claim() (principal) × rewards de palier — pas de double comptage
    // ═══════════════════════════════════════════════════════════════════════

    function test_Claim_FigeLaPartDeRewardDueAvantDeSortirDuCalculActif() public {
        // Reward latent au moment du claim() du principal
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();
        uint256 latentBeforeClaim = custodian.pendingRewardOf(userA);
        assertGt(latentBeforeClaim, 0);

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(userA);
        custodian.claim(); // retire le principal

        // Le reward latent doit rester intact et réclamable ensuite
        assertEq(custodian.pendingRewardOf(userA), latentBeforeClaim);

        vm.prank(userA);
        custodian.claimReward();
        assertEq(rmht.balanceOf(userA), AMOUNT_A + latentBeforeClaim);
    }

    function test_Claim_SortDuCalculActif_ActiveAllocatedDiminue() public {
        vm.warp(block.timestamp + 365 days + 1);
        uint256 before = custodian.activeAllocated();

        vm.prank(userA);
        custodian.claim();

        assertEq(custodian.activeAllocated(), before - AMOUNT_A);
    }

    function test_Claim_PuisNouveauHarvest_NePlusCrediterUserAyantDejaClaim() public {
        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(userA);
        custodian.claim();
        uint256 frozenReward = custodian.pendingRewardOf(userA);

        // Nouveau harvest après le claim du principal de userA : sa part figée
        // ne doit plus bouger, seul userB (encore actif) continue d'accumuler.
        rmht.accrueReward(address(custodian), 500 ether);
        custodian.harvestVaultRewards();

        assertEq(custodian.pendingRewardOf(userA), frozenReward); // inchangé
        assertGt(custodian.pendingRewardOf(userB), 0);
    }

    function test_Claim_AllocationZero_Revert() public {
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(userC);
        vm.expectRevert(RMHTAirdropCustodian.NothingToClaim.selector);
        custodian.claim();
    }

    function test_Claim_AvantUnlockTime_Revert() public {
        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.NotUnlockedYet.selector);
        custodian.claim();
    }

    function test_Claim_DeuxFois_Revert() public {
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(userA);
        custodian.claim();

        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.AlreadyClaimed.selector);
        custodian.claim();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Invariant léger : somme des rewards distribués ≤ total rapatrié depuis RMHT
    // ═══════════════════════════════════════════════════════════════════════

    function test_Invariant_SommeRewardsDistribuesNexcedePasTotalHarveste() public {
        uint256 totalHarvested;

        rmht.accrueReward(address(custodian), 1_000 ether);
        custodian.harvestVaultRewards();
        totalHarvested += 1_000 ether;

        vm.prank(userA);
        custodian.claimReward();
        vm.prank(userB);
        custodian.claimReward();

        rmht.accrueReward(address(custodian), 777 ether);
        custodian.harvestVaultRewards();
        totalHarvested += 777 ether;

        vm.prank(userA);
        custodian.claimReward();
        // userB ne réclame pas cette fois : reward latent laissé de côté

        uint256 distributed = rmht.balanceOf(userA) + rmht.balanceOf(userB);
        assertLe(distributed, totalHarvested);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  claim() — branche TransferFailed jamais exercée (seule celle de
    //  claimReward(), ligne différente du même fichier, l'était)
    // ═══════════════════════════════════════════════════════════════════════

    function test_Claim_RevertSiTransferEchoue() public {
        vm.warp(block.timestamp + 365 days + 1);
        rmht.setTransferShouldFail(true);
        vm.prank(userA);
        vm.expectRevert(RMHTAirdropCustodian.TransferFailed.selector);
        custodian.claim();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ReentrancyGuard sur rescueEth() — jamais réellement testé avant
    //  (le modifier nonReentrant est présent, mais aucun test ne prouvait
    //  qu'il bloque une vraie tentative de réentrance)
    // ═══════════════════════════════════════════════════════════════════════

    function test_RescueEth_ReentrancyGuardBlocksReentry() public {
        MaliciousReentrantAirdropRescue attacker = new MaliciousReentrantAirdropRescue();
        attacker.setTarget(custodian);
        vm.deal(address(custodian), 1 ether);

        vm.prank(owner);
        custodian.rescueEth(payable(address(attacker)));

        assertTrue(attacker.reentered(), "reentrancy attempt never fired");
        assertTrue(attacker.reentrancyReverted(), "reentrant call should have reverted");
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(custodian).balance, 0);
    }
}
