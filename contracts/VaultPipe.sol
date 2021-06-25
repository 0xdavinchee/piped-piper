// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { Pipe } from "./Pipe.sol";
import { IFakeVault } from "./interfaces/IFakeVault.sol";

/// @title VaultPipe is solely for testing purposes, when we demo we will want
/// to import Aave's interface in here or something.
contract VaultPipe is Pipe {
    IFakeVault public vault;

    constructor(ISuperToken _acceptedToken, address _vault) Pipe(_acceptedToken) {
        vault = IFakeVault(_vault);
    }

    /** @dev Overrides the Vault abstract contract's _depositToVault function
     * by utilizing the external contract's interface.
     */
    function _depositToVault(uint256 _amount) public override {
        vault.depositTokens(_amount);
    }

    /** @dev Overrides the Vault abstract contract's _withdrawToVault function
     * by utilizing the external contract's interface.
     */
    function _withdrawFromVault(uint256 _amount) public override {
        vault.withdrawTokens(_amount);
    }

    /** @dev Overrides the Vault abstract contract's _vaultBalanceOf function
     * by utilizing the external contract's interface.
     */
    function _vaultBalanceOf(address _pipeAddress) public view override returns (uint256) {
        return vault.balanceOf(_pipeAddress);
    }
}
