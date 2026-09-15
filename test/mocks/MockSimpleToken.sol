// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock ERC20 minimal, avec transfer() dont le succès est
///         configurable — pour tester les branches de RMHT.rescueTokens()
///         sur un token externe (succès, échec silencieux "return false",
///         et le cas "pas un contrat" via un simple EOA sans ce mock).
contract MockSimpleToken {
    mapping(address => uint256) public balanceOf;
    bool public transfersSucceed = true;

    constructor(address initialHolder, uint256 initialBalance) {
        balanceOf[initialHolder] = initialBalance;
    }

    function setTransfersSucceed(bool v) external {
        transfersSucceed = v;
    }

    /// @dev Ne revert jamais — renvoie simplement `false` quand
    ///      transfersSucceed est désactivé, pour reproduire le pattern
    ///      ERC20 non-standard que rescueTokens() doit détecter via son
    ///      check manuel `ok && (data.length == 0 || abi.decode(data, (bool)))`.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (!transfersSucceed) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
