// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UniswapV3TWAP — port Solidity 0.8.x de deux fonctions de la lib          ║
// ║  officielle Uniswap v3 (v3-core TickMath.sol + v3-periphery               ║
// ║  OracleLibrary.sol), pour débloquer S8.1.G4 (absence de TWAP).            ║
// ║                                                                          ║
// ║  POURQUOI CE FICHIER EXISTE (au lieu d'importer les libs officielles) :   ║
// ║  OracleLibrary.sol officiel a `pragma solidity >=0.5.0 <0.8.0;` — borne   ║
// ║  haute stricte, incompatible avec un projet Foundry mono-version pointé   ║
// ║  sur solc 0.8.36. FullMath.sol / LowGasSafeMath.sol (dont dépend          ║
// ║  OracleLibrary) s'appuient en plus sur le comportement *non vérifié*      ║
// ║  (wraparound) de l'arithmétique pré-0.8 pour leurs astuces 512 bits.      ║
// ║                                                                          ║
// ║  CE QUI EST PORTÉ, ET POURQUOI C'EST SUFFISANT ICI :                      ║
// ║  RMHT n'a besoin que du TICK MOYEN pondéré dans le temps, puis de le      ║
// ║  reconvertir en sqrtPriceX96 — PAS de getQuoteAtTick() (qui utilise       ║
// ║  FullMath) ni de harmonicMeanLiquidity (qui utilise aussi FullMath côté   ║
// ║  officiel). Résultat : FullMath n'est PAS nécessaire pour ce cas d'usage, ║
// ║  seul TickMath.getSqrtRatioAtTick() doit être porté :                     ║
// ║    - getSqrtRatioAtTick(int24) : port BIT-À-BIT du fichier officiel       ║
// ║      (constantes magiques inchangées, revérifiées deux fois contre le    ║
// ║      code source github.com/Uniswap/v3-core, contracts/libraries/        ║
// ║      TickMath.sol, commit affiché sur `main` au 27/08/2026). SEUL         ║
// ║      changement : la chaîne de multiplications/shifts qui déborde         ║
// ║      *intentionnellement* en 256 bits (le `>> 128` final ramène le        ║
// ║      résultat dans la bonne plage) est enveloppée dans `unchecked{}` —    ║
// ║      exactement le même pattern que la branche 0.8 maintenue par          ║
// ║      Uniswap lui-même et repris par des codebases auditées (ex.          ║
// ║      Vultisig, code4rena 2024-06).                                        ║
// ║      PRÉCISION 27/08/2026 (vérification numérique, cf.                    ║
// ║      test/UniswapV3TWAP.t.sol) : contrairement à ce que disait la         ║
// ║      première version de ce bandeau, AUCUN débordement 256 bits ne se     ║
// ║      produit réellement sur toute la plage de ticks valides — le          ║
// ║      produit maximal atteint 0,99990 × 2^256, soit juste sous la          ║
// ║      limite. Le `unchecked{}` est donc du GAS, pas une nécessité          ║
// ║      fonctionnelle : le code se comporterait à l'identique sans lui.      ║
// ║      On le garde pour rester bit-à-bit aligné sur la branche 0.8          ║
// ║      officielle, mais il ne masque aucun overflow vivant.                 ║
// ║    - consult(pool, secondsAgo) : réécrit nativement en 0.8.x (pas un      ║
// ║      port — c'est de l'arithmétique int56/int24 triviale qui ne           ║
// ║      dépendait de rien de spécifique à <0.8.0 dans l'original). Ne        ║
// ║      renvoie QUE arithmeticMeanTick (le seul champ utilisé par RMHT) —    ║
// ║      harmonicMeanLiquidity, non utilisé, a été omis pour ne pas           ║
// ║      réintroduire un besoin de FullMath sans raison.                      ║
// ║    - getOldestObservationSecondsAgo(pool) : même logique que la           ║
// ║      fonction homonyme d'OracleLibrary officiel. MàJ 27/08/2026 : sert    ║
// ║      côté RMHT à REFUSER de produire un prix tant que la pool ne          ║
// ║      couvre pas la fenêtre TWAP entière (fail-closed), et NON plus à      ║
// ║      raccourcir la fenêtre — un TWAP raccourci à l'écart entre deux       ║
// ║      blocs est le prix spot, pas une protection dégradée. Voir la note    ║
// ║      sur TWAP_WINDOW dans RMHT.sol.                                       ║
// ║                                                                          ║
// ║  NE PAS AJOUTER getTickAtSqrtRatio() ni FullMath ici sans revoir ce       ║
// ║  bandeau — ce fichier est volontairement minimal pour rester              ║
// ║  auditable en un coup d'œil.                                             ║
// ╚══════════════════════════════════════════════════════════════════════════╝

/// @dev Sous-ensemble de IUniswapV3Pool nécessaire à ce fichier — PAS le même
///      IUniswapV3PoolMinimal que RMHT.sol (qui n'a pas besoin d'observe()/
///      observations() pour ses autres usages, inchangé). RMHT.sol n'a pas
///      besoin d'étendre son interface : il appelle UniswapV3TWAP.consult(
///      uniswapV3Pool, ...) directement avec l'`address` de la pool (déjà
///      son type dans RMHT.sol), et c'est cette lib qui fait le cast interne
///      vers IUniswapV3PoolObservable.
interface IUniswapV3PoolObservable {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

library UniswapV3TWAP {
    /// @dev Identique à TickMath.MAX_TICK officiel — computed from log base
    ///      1.0001 of 2**128. Sert uniquement au require() de garde dans
    ///      getSqrtRatioAtTick ; RMHT n'a pas besoin de MIN_TICK/MIN_SQRT_RATIO/
    ///      MAX_SQRT_RATIO (pas de getTickAtSqrtRatio ici), donc non recopiés.
    int24 internal constant MAX_TICK = 887272;

    /// @notice Calcule sqrt(1.0001^tick) * 2^96 — PORT BIT-À-BIT de
    ///         TickMath.getSqrtRatioAtTick (Uniswap/v3-core,
    ///         contracts/libraries/TickMath.sol), seul changement : les
    ///         multiplications de la chaîne ci-dessous sont enveloppées dans
    ///         `unchecked{}` (débordement 256 bits volontaire, absorbé par le
    ///         `>> 128` qui suit chaque étape — comportement identique à
    ///         l'original pré-0.8, qui ne vérifiait pas l'overflow).
    /// @dev Throws si |tick| > MAX_TICK, exactement comme l'original.
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        unchecked {
            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Divise par 1<<32 en arrondissant vers le haut pour passer de
            // Q128.128 à Q128.96. Downcast sûr : le résultat tient toujours
            // dans 160 bits vu la contrainte |tick| <= MAX_TICK (identique à
            // l'original — MAX_SQRT_RATIO fait 160 bits, cf. commentaire du
            // fichier officiel).
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice Tick moyen arithmétique sur [block.timestamp - secondsAgo,
    ///         block.timestamp] — équivalent au champ arithmeticMeanTick de
    ///         OracleLibrary.consult() officiel (harmonicMeanLiquidity omis,
    ///         non utilisé par RMHT — évite une dépendance FullMath inutile).
    function consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
        require(secondsAgo != 0, "UniswapV3TWAP: BP");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IUniswapV3PoolObservable(pool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));

        // Arrondi systématique vers -infini (identique à l'original) — sans
        // ça, la division entière de Solidity arrondirait vers zéro, ce qui
        // biaiserait légèrement le prix moyen vers le haut sur un tick négatif.
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) {
            arithmeticMeanTick--;
        }
    }

    /// @notice Comme OracleLibrary.getOldestObservationSecondsAgo() officiel :
    ///         renvoie depuis combien de temps remonte la plus ancienne
    ///         observation encore stockée par la pool.
    /// @dev Sert à plafonner la fenêtre TWAP demandée à ce qui est
    ///      réellement disponible, plutôt que de faire revert
    ///      getRMHTPriceInETH() pendant les tout premiers instants de vie
    ///      de la pool (observationCardinality encore basse par défaut —
    ///      une pool Uniswap v3 fraîchement créée ne stocke qu'UNE seule
    ///      observation tant que increaseObservationCardinalityNext() n'a
    ///      pas été appelé).
    function getOldestObservationSecondsAgo(address pool) internal view returns (uint32 secondsAgo) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) =
            IUniswapV3PoolObservable(pool).slot0();
        require(observationCardinality > 0, "UniswapV3TWAP: NI");

        (uint32 observationTimestamp, , , bool initialized) =
            IUniswapV3PoolObservable(pool).observations((observationIndex + 1) % observationCardinality);

        // Si l'index suivant n'est pas encore initialisé (cardinality en
        // cours d'augmentation), la plus ancienne observation reste à
        // l'index 0 — identique à l'original.
        if (!initialized) {
            (observationTimestamp, , , ) = IUniswapV3PoolObservable(pool).observations(0);
        }

        secondsAgo = uint32(block.timestamp) - observationTimestamp;
    }
}
