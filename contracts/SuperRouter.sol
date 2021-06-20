// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;
pragma experimental ABIEncoderV2;

import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import {
    ISuperfluid,
    ISuperToken,
    ISuperAgreement,
    SuperAppDefinitions
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { SuperAppBase } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";
import { IPipe } from "./interfaces/IPipe.sol";

contract SuperRouter is SuperAppBase {
    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    mapping(address => bool) validPipeAddresses;

    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        address[] memory initialPipeAddresses
    ) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        host = _host;
        cfa = _cfa;

        for (uint256 i; i < initialPipeAddresses.length; i++) {
            validPipeAddresses[initialPipeAddresses[i]] = true;
        }

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL;

        host.registerApp(configWord);
    }
}
