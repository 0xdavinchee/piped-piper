// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { Pipe } from "./Pipe.sol";
import { IFakeVault } from "./interfaces/IFakeVault.sol";

contract fUSDCVault is Pipe {
    IFakeVault public vault;

    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken,
        address _vault
    ) Pipe(_host, _cfa, _acceptedToken) {
        vault = IFakeVault(_vault);
    }

    function _depositToVault(uint256 _amount) public override {
        vault.depositTokens(_amount);
    }

    function _withdrawFromVault(uint256 _amount) public override {
        vault.depositTokens(_amount);
    }

    function _vaultBalanceOf(address _pipeAddress) public view override returns (uint256) {
        return vault.balanceOf(_pipeAddress);
    }
}
