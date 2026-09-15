// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";
import "../../src/RMHT.sol";

/// @notice Handler pour les tests d'invariants Foundry : effectue des actions
///         "légales" aléatoires (transferts, claims, avance du temps + poke
///         du palier) sur un petit groupe d'acteurs, pour que le runner
///         d'invariants explore plein de séquences différentes.
contract RMHTHandler is Test {
    RMHT public rmht;
    address[] public actors;

    constructor(RMHT _rmht, address[] memory _actors) {
        rmht = _rmht;
        actors = _actors;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 bal = rmht.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);

        vm.prank(from);
        rmht.transfer(to, amount);
    }

    function claim(uint256 seed) public {
        address who = actors[seed % actors.length];
        if (rmht.pendingRewardsOf(who) == 0) return;

        vm.prank(who);
        try rmht.claimRewards() {} catch {}
    }

    function warpAndPoke(uint256 warpSeed) public {
        vm.warp(block.timestamp + bound(warpSeed, 1 hours, 48 hours));
        rmht.pokeMilestone();
    }
}
