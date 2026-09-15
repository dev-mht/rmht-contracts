// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721ReceiverLike {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

/// @notice Mock minimal du NonfungiblePositionManager, juste assez pour tester
///         RMHTLiquidityCustodian sans dépendre d'un vrai déploiement Uniswap v3.
contract MockPositionManager {
    uint128 public mockLiquidity = 1_000_000;
    uint256 public collectAmount0 = 5 ether;
    uint256 public collectAmount1 = 3 ether;

    /// @dev AJOUTÉ 27/08/2026 — le `from` d'un vrai safeTransferFrom ERC-721
    ///      est le PROPRIÉTAIRE du NFT, pas le position manager. Le mock
    ///      envoyait address(this), ce qui ne modélisait pas la réalité et
    ///      empêchait de tester le contrôle de dépôt du custodian.
    ///      Par défaut address(0) => comportement historique (address(this)).
    address public depositor;

    address public lastCollectRecipient;
    address public lastCollectCaller;
    uint256 public collectCallCount;

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Simule le dépôt initial du NFT de position dans le custodian
    ///         (équivalent d'un safeTransferFrom depuis ce position manager).
    function deliverPosition(address custodian, uint256 tokenId) external {
        address from = depositor == address(0) ? address(this) : depositor;
        IERC721ReceiverLike(custodian).onERC721Received(from, from, tokenId, "");
    }

    /// @notice Dépôt en se faisant passer pour un `from` arbitraire — sert à
    ///         simuler un tiers qui tente de squatter le custodian avec sa
    ///         propre position avant l'équipe.
    function deliverPositionFrom(address custodian, uint256 tokenId, address from) external {
        IERC721ReceiverLike(custodian).onERC721Received(from, from, tokenId, "");
    }

    function setDepositor(address d) external {
        depositor = d;
    }

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1) {
        lastCollectRecipient = params.recipient;
        lastCollectCaller = msg.sender;
        collectCallCount++;
        return (collectAmount0, collectAmount1);
    }

    function positions(uint256)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        return (0, address(0), address(0), address(0), 0, 0, 0, mockLiquidity, 0, 0, 0, 0);
    }

    function setMockLiquidity(uint128 l) external {
        mockLiquidity = l;
    }
}
