// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";

import { ISuperfluid, ISuperToken, ISuperApp, ISuperAgreement, SuperAppDefinitions } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { IConstantFlowAgreementV1 } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import { SuperAppBase } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SuperValve is Ownable, SuperAppBase {
  using SafeERC20 for ERC20;

  // Contract state
  ISuperfluid public host;
  IConstantFlowAgreementV1 public cfa;
  ERC20 public inputToken;
  ISuperToken public outputToken;

  // List of compatible pipe contracts
  address[] private validPipes;

  struct FlowData {
    uint256 totalFlowRate;
    mapping(address => uint256) pipeAllocation;
  }

  uint256 public totalInflow;

  // User outflow state
  mapping(address => FlowData) public userFlows;

  event NewInboundStream(address to, address token, uint96 rate);
  event NewOutboundStream(address to, address token, uint96 rate);
  event Distribution(address token, uint256 totalAmount); // TODO: Implement triggered distribution

  constructor(
    ISuperfluid _host,
    IConstantFlowAgreementV1 _cfa,
    ERC20 _inputToken,
    ISuperToken _outputToken
  ) {
    require(address(_host) != address(0), "host address invalid");
    require(address(_cfa) != address(0), "cfa address invalid");
    require(address(_inputToken) != address(0), "inputToken address invalid");
    require(address(_outputToken) != address(0), "outputToken address invalid");
    require(!_host.isApp(ISuperApp(msg.sender)), "Owner is a SuperApp");
    require(ISuperToken(_outputToken).getUnderlyingToken() == _inputToken, "outputToken does not match inputToken");

    _host = host;
    _cfa = cfa;
    _inputToken = inputToken;
    _outputToken = outputToken;

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
  function _updateOutflow(bytes calldata ctx, bytes calldata agreementData) private returns (bytes memory newCtx) {
    newCtx = ctx;

    (address requester, address flowReceiver) = abi.decode(agreementData, (address, address));
    int96 changeInFlowRate = cfa.getNetFlow(inputToken, address(this)) - totalInflow;

    if (userFlows[requester].totalFlowRate == changeInFlowRate) {
      // Rate has not changed, return
      return newCtx;
    } else {
      // Add/update the streamer
      userFlows[requester].totalFlowRate = userFlows[requester].totalFlowRate + changeInFlowRate;
    }

    // Return if reciever is not a pipe
    if (!isPipeValid(flowReceiver)) return newCtx;

    console.log("Updating CFA");

    if (userFlows[requester].totalFlowRate == int96(0)) {
      // @dev Delete the flow if no longer needed
      (newCtx, ) = _exchange.host.callAgreementWithContext(
        cfa,
        abi.encodeWithSelector(cfa.deleteFlow.selector, outputToken, address(this), requester, new bytes(0)),
        "0x", // user data
        newCtx
      );
    } else if (userFlows[requester].totalFlowRate != int96(0)) {
      // @dev Update the flow if already exists
      (newCtx, ) = _host.callAgreementWithContext(
        cfa,
        abi.encodeWithSelector(
          cfa.updateFlow.selector,
          outputToken,
          receiver,
          changeInFlowRate,
          new bytes(0) // placeholder
        ),
        "0x",
        newCtx
      );
    } else {
      // @dev Create a flow if doesn't exist
      (newCtx, ) = _host.callAgreementWithContext(
        cfa,
        abi.encodeWithSelector(
          cfa.createFlow.selector,
          outputToken,
          receiver,
          changeInFlowRate,
          new bytes(0) // placeholder
        ),
        "0x",
        newCtx
      );
    }

    console.log("Done updating CFA");
    _exchange.totalInflow = _exchange.totalInflow + changeInFlowRate;
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
    for (uint256 i = 0; i < validPipes.length; i++) {
      if (validPipes[i] == _pipeAddress) {
        return true;
      }
    }
    return false;
  }

  function getValidPipes() public view returns (address[] memory) {
    return validPipes;
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
    if (!_isInputToken(_superToken) || !_isCFAv1(_agreementClass)) return _ctx;

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
    if (!_isInputToken(_superToken) || !_isCFAv1(_agreementClass)) return _ctx;

    return _updateOutflow(_ctx, _agreementData);
  }

  function _isInputToken(ISuperToken superToken) internal view returns (bool) {
    return address(superToken) == address(inputToken);
  }

  function _isOutputToken(ISuperToken superToken) internal view returns (bool) {
    return address(superToken) == address(outputToken);
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
      require(_isInputToken(superToken), "!inputAccepted");
    } else if (_isIDAv1(agreementClass)) {
      require(_isOutputToken(superToken), "!outputAccepted");
    }
    _;
  }

  function _createFlow(address to, int96 flowRate) internal {
    _exchange.host.callAgreement(
      _exchange.cfa,
      abi.encodeWithSelector(
        _exchange.cfa.createFlow.selector,
        _exchange.inputToken,
        to,
        flowRate,
        new bytes(0) // placeholder
      ),
      "0x"
    );
  }

  function _createFlow(
    address to,
    int96 flowRate,
    bytes memory ctx
  ) internal returns (bytes memory newCtx) {
    (newCtx, ) = _exchange.host.callAgreementWithContext(
      _exchange.cfa,
      abi.encodeWithSelector(
        _exchange.cfa.createFlow.selector,
        _exchange.inputToken,
        to,
        flowRate,
        new bytes(0) // placeholder
      ),
      "0x",
      ctx
    );
  }

  function _updateFlow(address to, int96 flowRate) internal {
    _exchange.host.callAgreement(
      _exchange.cfa,
      abi.encodeWithSelector(
        _exchange.cfa.updateFlow.selector,
        _exchange.inputToken,
        to,
        flowRate,
        new bytes(0) // placeholder
      ),
      "0x"
    );
  }

  function _updateFlow(
    address to,
    int96 flowRate,
    bytes memory ctx
  ) internal returns (bytes memory newCtx) {
    (newCtx, ) = _exchange.host.callAgreementWithContext(
      _exchange.cfa,
      abi.encodeWithSelector(
        _exchange.cfa.updateFlow.selector,
        _exchange.inputToken,
        to,
        flowRate,
        new bytes(0) // placeholder
      ),
      "0x",
      ctx
    );
  }

  function _deleteFlow(address from, address to) internal {
    _exchange.host.callAgreement(
      _exchange.cfa,
      abi.encodeWithSelector(
        _exchange.cfa.deleteFlow.selector,
        _exchange.inputToken,
        from,
        to,
        new bytes(0) // placeholder
      ),
      "0x"
    );
  }

  function _deleteFlow(
    address from,
    address to,
    bytes memory ctx
  ) internal returns (bytes memory newCtx) {
    (newCtx, ) = _exchange.host.callAgreementWithContext(
      _exchange.cfa,
      abi.encodeWithSelector(
        _exchange.cfa.deleteFlow.selector,
        _exchange.inputToken,
        from,
        to,
        new bytes(0) // placeholder
      ),
      "0x",
      ctx
    );
  }
}
