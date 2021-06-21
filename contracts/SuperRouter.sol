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
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";

contract SuperRouter is SuperAppBase {
    int96 private constant ONE_HUNDRED_PERCENT = 1000;

    using SignedSafeMath for int256;

    struct PipeFlowData {
        int96 percentage; // percentage will be between 0 and 1000 (allows one decimal place of contrast)
        address pipeAddress;
    }
    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;

    mapping(address => bool) private validPipeAddresses;

    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken,
        address[] memory initialPipeAddresses
    ) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        require(address(_acceptedToken) != address(0), "Token is zero address.");
        host = _host;
        cfa = _cfa;
        acceptedToken = _acceptedToken;

        for (uint256 i; i < initialPipeAddresses.length; i++) {
            validPipeAddresses[initialPipeAddresses[i]] = true;
        }

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL;

        host.registerApp(configWord);
    }

    /**************************************************************************
     * Helper Functions
     *************************************************************************/
    /**
     * @dev Withdraws all your funds from all the different vaults/pipes.
     */
    function withdraw(address[] memory _pipeAddresses) public {
        for (uint256 i; i < _pipeAddresses.length; i++) {
            IPipe pipe = IPipe(_pipeAddresses[i]);
            if (pipe.totalWithdrawableBalance(msg.sender) > 0) {
                pipe.withdraw();
            }
        }
    }

    /**
     * @dev Returns a * b / c.
     */
    function mulDiv(
        int96 a,
        int96 b,
        int96 c
    ) internal pure returns (int96) {
        return int96(int256(a).mul(int256(b)).div(int256(c)));
    }

    /**
     * @dev A user can call this to set up a flow to the SuperRouter.
     */
    function setupFlows(
        PipeFlowData[] memory _pipeFlowData,
        int96 _flowRate,
        ISuperToken _inputToken
    ) public {
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.createFlow.selector, _inputToken, address(this), _flowRate, new bytes(0)),
            abi.encode(_pipeFlowData)
        );
    }

    function _createFlowToPipe(
        address _pipeAddress,
        int96 _percentage,
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        require(validPipeAddresses[_pipeAddress] == true, "This is not a registered vault address.");
        require(
            _percentage >= 0 && _percentage <= ONE_HUNDRED_PERCENT,
            "Your percentage is outside of the acceptable range."
        );
        (, int96 flowRate, , ) = cfa.getFlowByID(_token, _agreementId);
        int96 proportionedFlowRate = mulDiv(_percentage, flowRate, ONE_HUNDRED_PERCENT);
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.createFlow.selector, _pipeAddress, proportionedFlowRate, _ctx),
            "0x",
            _ctx
        );

        address sender = host.decodeCtx(_ctx).msgSender;
        IPipe(_pipeAddress).setFlowWithdrawData(sender, 0);
    }

    function _createFlowToPipes(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        bytes memory rawUserData = host.decodeCtx(newCtx).userData;
        PipeFlowData[] memory pipeFlowData = abi.decode(rawUserData, (PipeFlowData[]));
        for (uint256 i; i < pipeFlowData.length; i++) {
            _createFlowToPipe(
                pipeFlowData[i].pipeAddress,
                pipeFlowData[i].percentage,
                _token,
                _agreementClass,
                _agreementId,
                _ctx
            );
        }
    }

    /**************************************************************************
     * Super App Callbacks
     *************************************************************************/

    function beforeAgreementCreated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _agreementData,
        bytes calldata _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {}

    /**
     * @dev After the user starts flowing funds into the SuperRouter, we must redirect these flows through the
     * various pipes to the vaults accordingly based on the users selection vaults (pipes) in setupFlows.
     */
    function afterAgreementCreated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata
        bytes calldata _ctx
    ) external override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory newCtx) {
        newCtx = _createFlowToPipes(_token, _agreementClass, _agreementId, _ctx);
    }

    /**************************************************************************
     * Utilities
     *************************************************************************/

    function _isAccepted(ISuperToken _superToken) private view returns (bool) {
        return address(_superToken) == address(acceptedToken);
    }

    function _isCFAv1(address _agreementClass) private view returns (bool) {
        return
            ISuperAgreement(_agreementClass).agreementType() ==
            keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    }

    modifier onlyHost() {
        require(msg.sender == address(host), "SuperRouter: support only one host");
        _;
    }

    modifier onlyExpected(ISuperToken _superToken, address _agreementClass) {
        require(_isAccepted(_superToken), "SuperRouter: not accepted tokens");
        require(_isCFAv1(_agreementClass), "SuperRouter: only CFAv1 supported");
        _;
    }
}
