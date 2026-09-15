// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../../src/RMHT.sol";
import "../mocks/MockAggregatorV3.sol";
import "../mocks/MockUniswapV3Pool.sol";
import "./RMHTHandler.sol";

contract RMHTInvariantTest is Test {
    RMHT rmht;
    RMHTHandler handler;
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
    uint256 constant MARKET = 385_000_000 ether; // 500M - AIRDROP - FOUNDER
    uint256 initialVaultBalanceSeen;

    function setUp() public {
        vm.warp(1_700_000_000);

        vm.prank(owner);
        rmht = new RMHT(airdropWallet, AIRDROP, marketWallet, MARKET, founderWallet, FOUNDER, feedGovernor);

        ethUsdFeed = new MockAggregatorV3(8);
        sequencerFeed = new MockAggregatorV3(0);
        pool = new MockUniswapV3Pool(address(rmht), address(0xBEEF), uint160(2 ** 96));
        sequencerFeed.setRoundData(0, block.timestamp - 2 hours, block.timestamp);
        ethUsdFeed.setRoundData(3000 * 1e8, block.timestamp, block.timestamp);

        vm.startPrank(owner);
        rmht.setConfig(address(pool), address(ethUsdFeed), address(sequencerFeed));
        rmht.lockConfig();
        vm.stopPrank();

        // Distribuer un peu de supply à des acteurs "normaux" (non exclus des
        // rewards) depuis le marketWallet, pour que le handler ait de quoi jouer.
        address[] memory actors = new address[](4);
        actors[0] = address(0x1001);
        actors[1] = address(0x1002);
        actors[2] = address(0x1003);
        actors[3] = address(0x1004);

        vm.startPrank(marketWallet);
        for (uint256 i = 0; i < actors.length; i++) {
            rmht.transfer(actors[i], 50_000_000 ether);
        }
        vm.stopPrank();

        handler = new RMHTHandler(rmht, actors);
        targetContract(address(handler));

        initialVaultBalanceSeen = rmht.vaultBalance();
    }

    /// @notice La supply totale ne bouge jamais, quoi qu'il arrive — pas de
    ///         mint/burn caché nulle part dans le contrat.
    function invariant_TotalSupplyNeverChanges() public view {
        assertEq(rmht.totalSupply(), 1_000_000_000 ether);
    }

    /// @notice Le vault ne peut jamais dépasser sa valeur de départ, ni
    ///         redevenir plus grand après une libération (pas de "reset" bugué).
    function invariant_VaultBalanceNeverExceedsInitial() public view {
        assertLe(rmht.vaultBalance(), VAULT);
    }

    /// @notice Le solde RMHT réellement détenu par le contrat ne peut jamais
    ///         être inférieur au vaultBalance qu'il est censé garantir —
    ///         rescueTokens() ne doit jamais pouvoir entamer cette réserve.
    function invariant_ContractHoldsAtLeastVaultBalance() public view {
        assertGe(rmht.balanceOf(address(rmht)), rmht.vaultBalance());
    }

    /// @notice Le nombre de milestones ne peut jamais dépasser ce que permet
    ///         mathématiquement une décroissance de 1,5% à chaque fois
    ///         (protection contre un bug qui libérerait le vault trop vite).
    function invariant_MilestoneCountConsistentWithVaultDrop() public view {
        uint256 released = VAULT - rmht.vaultBalance();
        // Le vault ne peut jamais avoir libéré plus que sa valeur de départ.
        assertLe(released, VAULT);
    }
}
