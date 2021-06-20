// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import "./Pipe.sol";

contract StakeDaoPipe is Pipe {
    // IStakeDaoVault vault private;
    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken,
        address _vault
    ) Pipe(_host, _cfa, _acceptedToken, _vault) {}

    function _deposit(uint256 amount) public override {
        // this will implement stakedao's deposit function and override the one in Pipe
        // and utilize it here.
    }
}
