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
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Int96SafeMath } from "@superfluid-finance/ethereum-contracts/contracts/utils/Int96SafeMath.sol";

/// @author Piped-Piper ETHGlobal Hack Money Team
/// @title Handles flow agreement creation with multiple users, aggregates this flow and redirects
/// it to different contracts based on the users' selected allocations.
/// Caveats: There is a limit to the number of pipes/vaults a router can connect to due to the 3 million
/// gas limit on a callback.
/// Certain variables are set to public for testing purposes.
contract SuperValve is SuperAppBase, AccessControl {
    bytes32 private constant ADMIN = keccak256("ADMIN");
    string private constant ADD_ERROR = "INT96: Error adding.";

    using SignedSafeMath for int256;
    using Int96SafeMath for int96;

    struct UserToPipeFlowData {
        uint256 vaultWithdrawnAmount;
        uint256 flowUpdatedTimestamp;
        int256 flowAmountSinceUpdate;
        int256 totalFlowedToPipe;
        int96 flowRate;
    }

    struct UserFlowData {
        int96 userToValveFlowRate;
        mapping(address => UserToPipeFlowData) pipeOutflowRates;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 public cfa; // private
    ISuperToken public acceptedToken; // private

    int96 public valveInflowRate;
    address[] public validPipeAddresses; // private
    mapping(address => UserFlowData) public userFlowData; // private

    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken,
        address[] memory initialPipeAddresses
    ) {
        require(address(_host) != address(0), "SuperValve: Host is zero address.");
        require(address(_cfa) != address(0), "SuperValve: CFA is zero address.");
        require(address(_acceptedToken) != address(0), "SuperValve: Token is zero address.");
        _setupRole(ADMIN, msg.sender);
        _setRoleAdmin(ADMIN, ADMIN);
        host = _host;
        cfa = _cfa;
        acceptedToken = _acceptedToken;

        for (uint256 i; i < initialPipeAddresses.length; i++) {
            validPipeAddresses.push(initialPipeAddresses[i]);
        }

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

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
            withdrawFromVault(_pipeAddresses[i]);
        }
    }

    /** @dev Withdraws your funds from a single vault/pipe.
     */
    function withdrawFromVault(address _pipeAddress) public validPipeAddress(_pipeAddress) {
        IPipe pipe = IPipe(_pipeAddress);
        (, int96 flowRate, , ) = cfa.getFlow(acceptedToken, address(this), _pipeAddress);

        int96 previousFlowRate = userFlowData[msg.sender].pipeOutflowRates[_pipeAddress].flowRate;
        if (pipe.totalWithdrawableBalance(msg.sender, previousFlowRate) > 0) {
            // update the valveToPipeData in IPipe (same flow rate, but need to calculate total flow
            // before withdrawal)
            pipe.setPipeFlowData(flowRate);

            pipe.withdraw(previousFlowRate);
        }
    }

    function getValidPipeAddresses() public view returns (address[] memory) {
        return validPipeAddresses;
    }

    function getSenderAndPipeAddress(bytes calldata _ctx) internal view returns (address sender, address pipeAddress) {
        sender = host.decodeCtx(_ctx).msgSender;
        bytes memory userData = host.decodeCtx(_ctx).userData;
        (pipeAddress) = abi.decode(userData, (address));
    }

    /** @dev Allow the admin role (the deployer of the contract), to add valid pipe addresses. */
    function addPipeAddress(address _address) external {
        require(hasRole(ADMIN, msg.sender), "SuperValve: You don't have permissions for this action.");
        validPipeAddresses.push(_address);
    }

    /** @dev Allow the admin role (the deployer of the contract), to add valid pipe addresses. */
    function removePipeAddress(address _address) external {
        require(hasRole(ADMIN, msg.sender), "SuperValve: You don't have permissions for this action.");
        uint256 index;

        // TODO: can store this information in state to not have to do two different loops.
        for (uint256 i; i < validPipeAddresses.length; i++) {
            if (validPipeAddresses[i] == _address) {
                index = i;
            }
        }
        validPipeAddresses[index] = validPipeAddresses[validPipeAddresses.length - 1];
        validPipeAddresses.pop();
    }

    /**************************************************************************
     * User Functions
     *************************************************************************/

    function getUserFlowRate() external view returns (int96) {
        (, int96 flowRate, , ) = cfa.getFlow(acceptedToken, msg.sender, address(this));
        return flowRate;
    }

    function getValveInflowRate() external view returns (int96) {
        return cfa.getNetFlow(acceptedToken, address(this));
    }

    function getValveToPipeFlowRate(address _pipe) public view returns (int96) {
        if (!isValidPipeAddress(_pipe)) {
            return 0;
        }
        (, int96 valveToPipeFlowRate, , ) = cfa.getFlow(acceptedToken, address(this), _pipe);
        return valveToPipeFlowRate;
    }

    /**************************************************************************
     * Valve-To-Pipe CRUD Functions
     *************************************************************************/
    /** @dev Creators or updates the valveToPipe flowRate depending on whether the user has an existing agreement.
     * We will update the state to reflect the new flow rate from the SuperValve to the Pipe as well
     * as the users' updated allocation data.
     */
    function _updateValveToPipeFlow(address _agreementClass, bytes calldata _ctx)
        internal
        returns (bytes memory newCtx)
    {
        newCtx = _ctx;

        (address sender, address pipeAddress) = getSenderAndPipeAddress(_ctx);

        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(pipeAddress).setUserFlowWithdrawData(sender, userFlowData[sender].pipeOutflowRates[pipeAddress].flowRate);

        if (!isValidPipeAddress(pipeAddress)) {
            return newCtx;
        }

        int96 newInflowRate = cfa.getNetFlow(acceptedToken, address(this));
        int96 flowRateDifference = newInflowRate - valveInflowRate;

        if (flowRateDifference == 0) return newCtx;

        int96 valveToPipeFlowRate = getValveToPipeFlowRate(pipeAddress);
        int96 newValveToPipeFlowRate = valveToPipeFlowRate + flowRateDifference;

        IPipe(pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

        if (newValveToPipeFlowRate <= 0) {
            (newCtx, ) = host.callAgreementWithContext(
                ISuperAgreement(_agreementClass),
                abi.encodeWithSelector(
                    cfa.deleteFlow.selector,
                    acceptedToken,
                    address(this),
                    pipeAddress,
                    new bytes(0) // placeholder
                ),
                "0x",
                newCtx
            );

            userFlowData[sender].userToValveFlowRate = 0;
            userFlowData[sender].pipeOutflowRates[pipeAddress].flowRate = 0;
        } else if (valveToPipeFlowRate != 0) {
            (newCtx, ) = host.callAgreementWithContext(
                ISuperAgreement(_agreementClass),
                abi.encodeWithSelector(
                    cfa.updateFlow.selector,
                    acceptedToken,
                    pipeAddress,
                    newValveToPipeFlowRate,
                    new bytes(0) // placeholder
                ),
                "0x",
                newCtx
            );

            userFlowData[sender].userToValveFlowRate = userFlowData[sender].userToValveFlowRate.add(
                flowRateDifference,
                ADD_ERROR
            );
            userFlowData[sender].pipeOutflowRates[pipeAddress].flowRate = userFlowData[sender]
            .pipeOutflowRates[pipeAddress]
            .flowRate
            .add(flowRateDifference, ADD_ERROR);
        } else {
            (newCtx, ) = host.callAgreementWithContext(
                ISuperAgreement(_agreementClass),
                abi.encodeWithSelector(
                    cfa.createFlow.selector,
                    acceptedToken,
                    pipeAddress,
                    newValveToPipeFlowRate,
                    new bytes(0) // placeholder
                ),
                "0x",
                newCtx
            );

            userFlowData[sender].userToValveFlowRate = flowRateDifference;
            userFlowData[sender].pipeOutflowRates[pipeAddress].flowRate = flowRateDifference;
        }

        valveInflowRate = newInflowRate;
    }

    /**************************************************************************
     * Super App Callbacks
     *************************************************************************/
    /**
     * @dev After the user starts flowing funds into the SuperValve, we redirect these flows through the
     * various pipes to the vaults accordingly based on the users selection vaults (pipes) in setupFlows.
     */
    function afterAgreementCreated(
        ISuperToken _token,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata
        bytes calldata _ctx
    ) external override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory newCtx) {
        newCtx = _updateValveToPipeFlow(_agreementClass, _ctx);
    }

    /** @dev If the user updates their flow rates or the proportion that go into the different flows, then we
     * will udpate the total flowed from the SuperValve to the Pipe.
     */
    function afterAgreementUpdated(
        ISuperToken _token,
        address _agreementClass,
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata
        bytes calldata _ctx
    ) external override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory newCtx) {
        newCtx = _updateValveToPipeFlow(_agreementClass, _ctx);
    }

    /** @dev If the user removes their flow rates, we will update the state accordingly.
     */
    function afterAgreementTerminated(
        ISuperToken _token,
        address _agreementClass,
        bytes32, // _agreementId
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata
        bytes calldata _ctx
    ) external override returns (bytes memory newCtx) {
        if (_token != acceptedToken) {
            return _ctx;
        }
        newCtx = _updateValveToPipeFlow(_agreementClass, _ctx);
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

    function isValidPipeAddress(address _pipeAddress) internal view returns (bool) {
        for (uint256 i; i < validPipeAddresses.length; i++) {
            if (validPipeAddresses[i] == _pipeAddress) {
                return true;
            }
        }
        return false;
    }

    modifier validPipeAddress(address _pipeAddress) {
        require(isValidPipeAddress(_pipeAddress), "SuperValve: This is not a registered vault address.");
        _;
    }

    modifier hasFlowRate(int96 _flowRate) {
        require(_flowRate > 0, "SuperValve: Flow rate must be greater than 0.");
        _;
    }

    modifier onlyHost() {
        require(msg.sender == address(host), "SuperValve: support only one host");
        _;
    }

    modifier validToken(ISuperToken _token) {
        require(address(_token) == address(acceptedToken), "SuperValve: not accepted tokens");
        _;
    }

    modifier onlyExpected(ISuperToken _superToken, address _agreementClass) {
        require(_isAccepted(_superToken), "SuperValve: not accepted tokens");
        require(_isCFAv1(_agreementClass), "SuperValve: only CFAv1 supported");
        _;
    }
}
