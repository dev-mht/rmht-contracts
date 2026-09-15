// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.8.37;

import "forge-std/Test.sol";

/// @notice Tests de l'item S9.2.5 — `evm_version` épinglé à "osaka" dans
///         foundry.toml (27/08/2026). Le rapport de 14h avait établi par
///         désassemblage manuel que le bytecode déployé contient 206 PUSH0.
///         Ce fichier rend cette vérification REJOUABLE en CI, et pousse le
///         raisonnement un cran plus loin.
///
/// @dev  QUESTION RÉELLEMENT POSÉE PAR S9.2.5 : « compiler pour un fork plus
///       récent que ce que la chaîne supporte est-il risqué ? ». Le risque
///       n'existe que si solc ÉMET réellement quelque chose de spécifique à
///       ce fork. On mesure donc directement ce que le bytecode contient :
///         1. PUSH0 (0x5f, EIP-3855 / Shanghai) est-il présent ? → oui, et
///            c'est ce qui rendait le warning Foundry légitime.
///         2. Le bytecode est-il en format LEGACY et pas EOF ? Un conteneur
///            EOF commence par le magic 0xEF00. EOF a été retiré de Fusaka en
///            avril 2025 et reporté à Glamsterdam, donc "osaka" ne devrait
///            porter aucune sémantique EOF — on le vérifie au lieu de le
///            supposer.
///         3. CLZ (0x1e, EIP-7939), le SEUL nouvel opcode réellement apporté
///            par Fusaka/Osaka, est-il émis ? S'il est absent, alors le
///            bytecode produit avec evm_version = "osaka" n'exige en pratique
///            RIEN au-delà de Cancun — ce qui referme le risque résiduel
///            "Medium" documenté dans les rapports 14h et 16h.
///
///       LIMITE ASSUMÉE : le parcours d'opcodes ci-dessous saute correctement
///       les immédiats des PUSHn, et exclut la métadonnée CBOR de fin (dont
///       la longueur est encodée sur les 2 derniers octets). Il reste
///       théoriquement possible qu'une section de données constantes placée
///       en plein milieu du runtime soit lue comme du code ; sur un contrat
///       solc standard comme RMHT ce cas ne se présente pas, et de toute
///       façon cela ne pourrait produire que des FAUX POSITIFS (opcode
///       exotique vu à tort), jamais un faux négatif sur PUSH0.
contract EvmVersionOsakaTest is Test {
    uint8 constant OP_CLZ = 0x1e; // EIP-7939, introduit par Fusaka/Osaka
    uint8 constant OP_PUSH0 = 0x5f; // EIP-3855, Shanghai
    uint8 constant OP_PUSH1 = 0x60;
    uint8 constant OP_PUSH32 = 0x7f;

    struct Scan {
        uint256 push0Count;
        uint256 clzCount;
        uint256 opcodeCount;
    }

    function _scan(bytes memory code) internal pure returns (Scan memory s) {
        uint256 end = _codeRegionEnd(code);
        uint256 i = 0;
        while (i < end) {
            uint8 op = uint8(code[i]);
            s.opcodeCount++;
            if (op == OP_PUSH0) s.push0Count++;
            if (op == OP_CLZ) s.clzCount++;

            if (op >= OP_PUSH1 && op <= OP_PUSH32) {
                i += 1 + (uint256(op) - uint256(OP_PUSH1) + 1);
            } else {
                i += 1;
            }
        }
    }

    /// @dev solc termine le runtime par une métadonnée CBOR dont la longueur
    ///      tient sur les 2 derniers octets (big endian). L'inclure dans le
    ///      parcours ferait lire des octets de hash comme des opcodes.
    function _codeRegionEnd(bytes memory code) internal pure returns (uint256) {
        if (code.length < 2) return code.length;
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        uint256 total = metaLen + 2;
        if (total >= code.length) return code.length;
        return code.length - total;
    }

    function _rmhtRuntime() internal returns (bytes memory) {
        return vm.getDeployedCode("RMHT.sol:RMHT");
    }

    /// @notice Point 1 — PUSH0 est bien massivement présent : le warning
    ///         Foundry "EIP-3855 is not supported / Unsupported Chain IDs:
    ///         46630" portait sur un usage réel, pas sur un faux signal.
    function test_DeployedBytecode_UsesPush0() public {
        Scan memory s = _scan(_rmhtRuntime());
        emit log_named_uint("opcodes parcourus", s.opcodeCount);
        emit log_named_uint("occurrences PUSH0", s.push0Count);
        assertGt(s.push0Count, 0, "PUSH0 attendu (EIP-3855) : le support Shanghai+ est bien requis");
    }

    /// @notice Point 2 — bytecode LEGACY, pas de conteneur EOF. Si un jour
    ///         une version de solc décidait d'émettre de l'EOF sous une cible
    ///         plus récente, ce test le verrait immédiatement.
    function test_DeployedBytecode_IsLegacyNotEOF() public {
        bytes memory code = _rmhtRuntime();
        assertGt(code.length, 1, "bytecode vide");
        assertTrue(uint8(code[0]) != 0xEF, "prefixe EOF (0xEF) detecte : le bytecode n'est plus au format legacy");
    }

    /// @notice Point 3 — LE test qui referme S9.2.5 : aucun opcode
    ///         spécifiquement apporté par Fusaka/Osaka n'est émis. Compiler
    ///         avec evm_version = "osaka" ne fait donc dépendre le contrat
    ///         d'aucune sémantique post-Cancun à l'exécution.
    function test_DeployedBytecode_EmitsNoOsakaSpecificOpcode() public {
        Scan memory s = _scan(_rmhtRuntime());
        emit log_named_uint("occurrences CLZ (0x1e, EIP-7939)", s.clzCount);
        assertEq(s.clzCount, 0, "opcode CLZ (Fusaka/Osaka) emis : la cible EVM devient une vraie dependance runtime");
    }

    /// @notice Même vérification sur la librairie TWAP fraîchement ajoutée —
    ///         c'est du code nouveau, arithmétique et bourré de constantes
    ///         128 bits : exactement le genre de code où un compilateur
    ///         pourrait vouloir sortir un opcode récent (CLZ compris).
    ///         La librairie étant `internal`-only, elle est inlinée dans
    ///         RMHT : on revérifie donc sur RMHT après ajout, et sur les
    ///         custodians qui n'y touchent pas, pour comparaison.
    function test_OtherContracts_EmitNoOsakaSpecificOpcode() public {
        string[3] memory artifacts = [
            "RMHTAirdropCustodian.sol:RMHTAirdropCustodian",
            "RMHTFounderCustodian.sol:RMHTFounderCustodian",
            "RMHTLiquidityCustodian.sol:RMHTLiquidityCustodian"
        ];
        for (uint256 i = 0; i < artifacts.length; i++) {
            Scan memory s = _scan(vm.getDeployedCode(artifacts[i]));
            assertEq(s.clzCount, 0, artifacts[i]);
        }
    }
}
