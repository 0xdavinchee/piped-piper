// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

abstract contract Vault {
    function _depositToVault(
        address _underlying,
        uint256 _amount,
        address _sender
    ) public virtual {}

    function _vaultAddress() public virtual returns (address) {}

    function _withdrawFromVault(uint256 amount, address user) public virtual {}
}
