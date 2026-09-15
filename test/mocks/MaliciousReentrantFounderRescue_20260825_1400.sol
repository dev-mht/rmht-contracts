// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RMHTFounderCustodian.sol";

/// @notice Contrat sans receive()/fallback payable — pour prouver que
///         rescueEth() revert bien avec EthTransferFailed quand le
///         destinataire refuse l'ETH (branche jamais exercée avant ce fichier).
contract NonPayableReceiverFounder {}

/// @notice Contrat malveillant qui tente de ré-entrer rescueEth() (et,
///         séparément, claim()) pendant qu'il reçoit l'ETH envoyé par ce
///         même appel — pour prouver que le ReentrancyGuard partagé de
///         RMHTFounderCustodian bloque bien la réentrance, même si l'appelant
///         de la tentative de réentrance n'est pas owner/beneficiary (le
///         modifier nonReentrant est évalué avant onlyOwner/le check
///         beneficiary, donc le revert attendu est bien
///         ReentrancyGuardReentrantCall, pas OwnableUnauthorizedAccount).
contract MaliciousReentrantFounderRescue {
    RMHTFounderCustodian public target;
    bool public targetSet;
    bool public reentered;
    bool public reentrancyReverted;
    /// @notice Si true, la tentative de réentrance appelle claim() au lieu de
    ///         rescueEth() — prouve que le verrou est bien partagé entre les
    ///         deux fonctions nonReentrant du contrat, pas seulement local à
    ///         rescueEth().
    bool public reenterViaClaim;

    constructor(bool _reenterViaClaim) {
        reenterViaClaim = _reenterViaClaim;
    }

    /// @notice Casse la dépendance circulaire déploiement (ce mock doit être
    ///         l'adresse `beneficiary`, immutable, passée au constructeur de
    ///         RMHTFounderCustodian — donc son adresse doit exister AVANT que
    ///         le custodian ne soit déployé). Appelable une seule fois.
    function setTarget(RMHTFounderCustodian _target) external {
        require(!targetSet, "target already set");
        target = _target;
        targetSet = true;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            if (reenterViaClaim) {
                try target.claim() {
                    // Ne devrait jamais réussir.
                } catch {
                    reentrancyReverted = true;
                }
            } else {
                try target.rescueEth(payable(address(this))) {
                    // Ne devrait jamais réussir.
                } catch {
                    reentrancyReverted = true;
                }
            }
        }
    }
}
