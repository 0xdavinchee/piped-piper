// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

abstract contract Vault {
    address internal vault;

    constructor(address _vault) {
        require(_vault != address(0), "Vault is zero address.");
        vault = _vault;
    }

    function _depositToVault(uint256 amount) public virtual {}

    function _withdrawFromVault(uint256 amount) public virtual {}

    function _vaultBalanceOf(address pipeAddress) public view virtual returns (uint256) {}
}
