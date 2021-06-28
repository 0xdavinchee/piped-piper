// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;
pragma abicoder v2;

import "hardhat/console.sol";

import { ISuperfluid, ISuperToken, ISuperApp, ISuperAgreement, SuperAppDefinitions } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { SuperAppBase } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract SuperValve is Ownable, SuperAppBase {
  using SafeERC20 for ERC20;

  // Contract state
  ISuperfluid public host;
  IConstantFlowAgreementV1 public cfa;
  ISuperToken public acceptedToken;

  // TODO Change all int to int96
  // Holds total flows across all pipes
  int public totalInflow;

  // List of compatible pipe contracts
  address[] private validPipes;

  struct FlowData {
    int totalFlowRate;

    // Value out of total user flow allocated to pipe
    mapping(address => int) pipeAllocation; 
  }

  // User outflow state
  mapping(address => FlowData) public userFlows;

  event NewInboundStream(address to, address token, uint96 rate);
  event NewOutboundStream(address to, address token, uint96 rate);
  event Distribution(address token, uint256 totalAmount); // TODO: Implement triggered distribution

  constructor(
    address _host,
    address _cfa,
    ISuperToken _acceptedToken
  ) {
    require(address(_host) != address(0), "host address invalid");
    require(address(_cfa) != address(0), "cfa address invalid");
    require(address(_acceptedToken) != address(0), "acceptedToken address invalid");
    require(!ISuperfluid(_host).isApp(ISuperApp(msg.sender)), "Owner cannot be a SuperApp");

    host = ISuperfluid(_host);
    cfa = IConstantFlowAgreementV1(_cfa);
    acceptedToken = ISuperToken(_acceptedToken);

    uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
      SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
      SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
      SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

    host.registerApp(configWord);
  }

  /**************************************************************************
   * SuperValve Logic
   *************************************************************************/

  /// @dev If a new stream is opened, or an existing one is opened
  function _updateOutflow(bytes calldata ctx, bytes calldata agreementData) internal returns (bytes memory newCtx) {
    newCtx = ctx;

    // Create a new flow to the pipe and assign to the user
    (address requester, address flowReceiver) = abi.decode(agreementData, (address, address));

    address pipe;
    if (isPipeValid(flowReceiver)) {
      pipe = flowReceiver;
    } else {
      return newCtx;
    }

    int changeInFlowRate = cfa.getNetFlow(acceptedToken, address(this)) - totalInflow;

    // If rate has not changed, return
    if (changeInFlowRate == 0) return newCtx;

    int pipeFlowRate = getPipeInflow(pipe);
    int resultingPipeFlow = pipeFlowRate + changeInFlowRate;

    // Update flows for pipe and internal user accounting
    if (resultingPipeFlow <= 0) {

      // @dev User has 0 net flow, deleting the stream
      (newCtx, ) = host.callAgreementWithContext(
        cfa,
        abi.encodeWithSelector(cfa.deleteFlow.selector, acceptedToken, address(this), pipe, new bytes(0)),
        "0x", // user data
        newCtx
      );

      userFlows[requester].totalFlowRate = 0;
      userFlows[requester].pipeAllocation[pipe] = 0;

    } else if (pipeFlowRate != 0) {

      // @dev Update the flow if already exists
      (newCtx, ) = host.callAgreementWithContext(
        cfa,
        abi.encodeWithSelector(
          cfa.updateFlow.selector,
          acceptedToken,
          pipe,
          resultingPipeFlow,
          new bytes(0) // placeholder
        ),
        "0x",
        newCtx
      );

      userFlows[requester].totalFlowRate = userFlows[requester].totalFlowRate + changeInFlowRate;
      userFlows[requester].pipeAllocation[pipe] = userFlows[requester].pipeAllocation[pipe] + changeInFlowRate;

    } else {
      // @dev Create a flow if doesn't exist
      (newCtx, ) = host.callAgreementWithContext(
        cfa,
        abi.encodeWithSelector(
          cfa.createFlow.selector,
          acceptedToken,
          flowReceiver,
          changeInFlowRate,
          new bytes(0) // placeholder
        ),
        "0x",
        newCtx
      );
      userFlows[requester].totalFlowRate = changeInFlowRate;
      userFlows[requester].pipeAllocation[pipe] = changeInFlowRate;
    }

    totalInflow = cfa.getNetFlow(acceptedToken, address(this));
  }

  /**************************************************************************
   * Pipe management methods
   *************************************************************************/

  // TODO make so only owner can change pipes array
  function addPipe(address _pipeAddress) public {
    validPipes.push(_pipeAddress);
  }

  function removePipe(address _pipeAddress) public {
    validPipes.push(_pipeAddress);
  }

  function isPipeValid(address _pipeAddress) public returns (bool) {
    for (uint32 i = 0; i < validPipes.length; i++) {
      if (validPipes[i] == _pipeAddress) {
        return true;
      }
    }
    return false;
  }

  function getValidPipes() public view returns (address[] memory) {
    return validPipes;
  }

  function getPipeInflow(address _pipeAddress) public returns (int96) {
    if(isPipeValid(_pipeAddress)) {
      cfa.getNetFlow(acceptedToken, _pipeAddress);
    } else {
      return 0;
    }
  }

  /**************************************************************************
   * SuperApp callbacks
   *************************************************************************/

  function afterAgreementCreated(
    ISuperToken _superToken,
    address _agreementClass,
    bytes32, // _agreementId,
    bytes calldata _agreementData,
    bytes calldata, // _cbdata,
    bytes calldata _ctx
  ) external override onlyExpected(_superToken, _agreementClass) onlyHost returns (bytes memory newCtx) {
    return _updateOutflow(_ctx, _agreementData);
  }

  function afterAgreementUpdated(
    ISuperToken _superToken,
    address _agreementClass,
    bytes32, //_agreementId,
    bytes calldata _agreementData,
    bytes calldata, //_cbdata,
    bytes calldata _ctx
  ) external override onlyExpected(_superToken, _agreementClass) onlyHost returns (bytes memory newCtx) {
    if (!_isAcceptedToken(_superToken) || !_isCFAv1(_agreementClass)) return _ctx;

    return _updateOutflow(_ctx, _agreementData);
  }

  function afterAgreementTerminated(
    ISuperToken _superToken,
    address _agreementClass,
    bytes32, //_agreementId,
    bytes calldata _agreementData,
    bytes calldata, //_cbdata,
    bytes calldata _ctx
  ) external override onlyHost returns (bytes memory newCtx) {
    // According to the app basic guidelines, we should never revert in a termination callback
    if (!_isAcceptedToken(_superToken) || !_isCFAv1(_agreementClass)) return _ctx;

    return _updateOutflow(_ctx, _agreementData);
  }

  function _isAcceptedToken(ISuperToken superToken) internal view returns (bool) {
    return address(superToken) == address(acceptedToken);
  }

  function _isCFAv1(address agreementClass) internal view returns (bool) {
    return
      ISuperAgreement(agreementClass).agreementType() ==
      keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
  }

  modifier onlyHost() {
    require(msg.sender == address(host), "Caller must be the host");
    _;
  }

  modifier onlyExpected(ISuperToken superToken, address agreementClass) {
    if (_isCFAv1(agreementClass)) {
      require(_isAcceptedToken(superToken), "!inputAccepted");
    }
    _;
  }
}
