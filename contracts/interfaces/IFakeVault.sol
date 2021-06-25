// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract IFakeVault is ERC20 {
    function depositTokens(uint256 _amount) public virtual;

    function withdrawTokens(uint256 _amount) public virtual;
}
