// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

abstract contract Vault {
    function _depositToVault(uint256 amount) public virtual {}

    function _withdrawFromVault(uint256 amount) public virtual {}

    function _vaultBalanceOf(address pipeAddress) public view virtual returns (uint256) {}
}
