// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICustodianLike {
    function collect() external returns (uint256 amount0, uint256 amount1);
}

/// @notice Mock du NonfungiblePositionManager qui, pendant sa propre exécution
///         de collect(), tente de rappeler custodian.collect() — pour prouver
///         que le verrou nonReentrant() de RMHTLiquidityCustodian bloque bien
///         cette attaque classique de réentrance.
contract MaliciousReentrantPositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    address public custodian;
    /// @dev cf. MockPositionManager : `from` doit pouvoir être le owner.
    address public depositor;
    bool public reentered;
    bool public reentrancyReverted;

    function setCustodian(address _custodian) external {
        custodian = _custodian;
    }

    function setDepositor(address d) external {
        depositor = d;
    }

    /// @dev Simule le dépôt initial du NFT, comme MockPositionManager.
    function deliverPosition(address _custodian, uint256 tokenId) external {
        (bool ok, ) = _custodian.call(
            abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)",
                depositor == address(0) ? address(this) : depositor,
                depositor == address(0) ? address(this) : depositor,
                tokenId,
                ""
            )
        );
        require(ok, "deliverPosition failed");
    }

    function collect(CollectParams calldata) external returns (uint256 amount0, uint256 amount1) {
        if (!reentered) {
            reentered = true;
            // Tente de rappeler collect() sur le custodian pendant que son
            // premier appel à collect() est encore en cours d'exécution.
            try ICustodianLike(custodian).collect() {
                // Ne devrait jamais réussir.
            } catch {
                reentrancyReverted = true;
            }
        }
        return (5 ether, 3 ether);
    }

    function positions(uint256)
        external
        pure
        returns (
            uint96, address, address, address, uint24, int24, int24,
            uint128 liquidity, uint256, uint256, uint128, uint128
        )
    {
        return (0, address(0), address(0), address(0), 0, 0, 0, 1_000_000, 0, 0, 0, 0);
    }
}
