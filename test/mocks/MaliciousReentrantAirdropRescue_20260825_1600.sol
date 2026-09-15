// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "../../src/RMHTAirdropCustodian.sol";

/// @notice Contrat malveillant qui tente de ré-entrer rescueEth() pendant
///         qu'il reçoit l'ETH envoyé par ce même appel — pour prouver que le
///         ReentrancyGuard de RMHTAirdropCustodian bloque bien la réentrance
///         (jamais exercé par un vrai test avant ce fichier, même si le
///         modifier `nonReentrant` est bien présent sur rescueEth()).
contract MaliciousReentrantAirdropRescue {
    RMHTAirdropCustodian public target;
    bool public targetSet;
    bool public reentered;
    bool public reentrancyReverted;

    /// @dev Casse la dépendance circulaire déploiement/adresse — voir le
    ///      mock équivalent côté RMHTFounderCustodian pour le même besoin.
    function setTarget(RMHTAirdropCustodian _target) external {
        require(!targetSet, "target already set");
        target = _target;
        targetSet = true;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try target.rescueEth(payable(address(this))) {
                // Ne devrait jamais réussir.
            } catch {
                reentrancyReverted = true;
            }
        }
    }
}
