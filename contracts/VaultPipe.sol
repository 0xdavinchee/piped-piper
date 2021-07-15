// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pipe } from "./Pipe.sol";
import { IFakeVault } from "./interfaces/IFakeVault.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

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
    function _depositToVault(uint256 _amount, address _sender) public override {
        bool success = acceptedToken.transfer(address(vault), _amount);
        require(success, "VaultPipe: Deposit transfer failed.");
        vault.depositTokens(_amount, _sender);
    }

    function _vaultAddress() public override view returns(address) {
        return address(vault);
    }

    /** @dev Overrides the Vault abstract contract's _withdrawToVault function
     * by utilizing the external contract's interface.
     */
    function _withdrawFromVault(uint256 _amount, address _user) public override {
        bool depositSuccess = IERC20(vault).transfer(address(vault), _amount);
        require(depositSuccess, "VaultPipe: Deposit transfer failed.");
        vault.withdrawTokens(_amount, _user);
    }

    /** @dev Overrides the Vault abstract contract's _vaultBalanceOf function
     * by utilizing the external contract's interface.
     */
    function _vaultBalanceOf(address _pipeAddress) public view override returns (uint256) {
        return vault.balanceOf(_pipeAddress);
    }
}
