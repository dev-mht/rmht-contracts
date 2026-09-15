// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RMHT.sol";

/// @notice Contrat malveillant qui tente de ré-entrer rescueTokens() pendant
///         qu'il reçoit l'ETH envoyé par ce même appel — pour prouver que le
///         ReentrancyGuard bloque bien cette attaque classique.
contract MaliciousReentrantOwner {
    RMHT public target;
    bool public reentered;
    /// @dev AJOUTÉ 24/08/2026 : la tentative de reentrance elle-même revert
    ///      (ReentrancyGuardReentrantCall) — sans try/catch, ce revert
    ///      remontait à travers receive() et annulait jusqu'à l'écriture de
    ///      `reentered = true`, rendant impossible de prouver après coup
    ///      qu'une tentative avait bien eu lieu.
    bool public reentrancyReverted;

    constructor(RMHT _target) {
        target = _target;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try target.rescueTokens(address(0), 1) {
                // Ne devrait jamais réussir.
            } catch {
                reentrancyReverted = true;
            }
        }
    }

    function rescue(uint256 amount) external {
        target.rescueTokens(address(0), amount);
    }
}
