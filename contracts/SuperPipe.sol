// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";

contract SuperPipe is SuperAppBase {
    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;
    address private vault;

    mapping(address => uint256) private userDepositedAmounts;

    // TODO: add vault to constructor, deploy script and .env
    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken
    ) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        require(address(_acceptedToken) != address(0), "Token is zero address.");
        host = _host;
        cfa = _cfa;
        acceptedToken = _acceptedToken;

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL | SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP;

        host.registerApp(configWord);
    }
}
