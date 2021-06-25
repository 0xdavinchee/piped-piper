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
    int96 private constant ONE_HUNDRED_PERCENT = 1000;
    bytes32 private constant ADMIN = keccak256("ADMIN");

    using SignedSafeMath for int256;
    using Int96SafeMath for int96;

    struct PipeFlowData {
        int96 percentage; // percentage will be between 0 and 1000 (allows one decimal place of contrast)
        address pipeAddress;
    }
    struct Allocation {
        int96 flowRate;
        int96 percentage;
    }
    struct UserAllocation {
        int96 userToValveFlowRate;
        mapping(address => Allocation) allocations;
        uint256 userPipeFlowId;
    }
    struct UpdateValveToPipeData {
        bool hasAgreement;
        PipeFlowData pipeFlowData;
        int96 newUserToValveFlowRate;
        address sender;
        ISuperToken token;
        address agreementClass;
        bytes ctx;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 public cfa; // private
    ISuperToken public acceptedToken; // private

    mapping(address => bool) public validPipeAddresses; // private
    mapping(address => int96) public superValveToPipeFlowRates; // private
    mapping(address => UserAllocation) private userAllocations; // private
    PipeFlowData[][] public userPipeFlowData;

    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken,
        address[] memory initialPipeAddresses
    ) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        require(address(_acceptedToken) != address(0), "Token is zero address.");
        _setupRole(ADMIN, msg.sender);
        _setRoleAdmin(ADMIN, ADMIN);
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

    // TODO: ensure the user is able to stop their flows then withdraw.
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

        int96 previousFlowRate = userAllocations[msg.sender].allocations[_pipeAddress].flowRate;
        if (pipe.totalWithdrawableBalance(msg.sender, previousFlowRate) > 0) {
            // update the valveToPipeData in IPipe (same flow rate, but need to calculate total flow
            // before withdrawal)
            pipe.setPipeFlowData(flowRate);

            pipe.withdraw(previousFlowRate);
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

    function getSenderAndPipeFlowData(bytes calldata _ctx)
        internal
        view
        returns (address sender, PipeFlowData[] storage pipeFlowData)
    {
        sender = host.decodeCtx(_ctx).msgSender;
        uint256 userPipeFlowId = userAllocations[sender].userPipeFlowId;
        pipeFlowData = userPipeFlowData[userPipeFlowId];
    }

    /** @dev Allow the admin role (the deployer of the contract), to add or remove valid pipe addresses. */
    function addOrRemovePipeAddress(address _address, bool _isValid) external {
        require(hasRole(ADMIN, msg.sender), "SuperValve: You don't have permissions for this action.");
        validPipeAddresses[_address] = _isValid;
    }

    /** @dev Checks before create/update of an agreement. */
    function _beforeFlowToPipe(
        ISuperToken _token,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) private view returns (bytes memory cbdata) {
        (, PipeFlowData[] memory pipeFlowData) = getSenderAndPipeFlowData(_ctx);
        isFullyAllocated(pipeFlowData);
        require(pipeFlowData.length > 0, "SuperValve: You have not set your allocations yet.");
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(_token, _agreementId);
        require(newUserToValveFlowRate > 0, "There is no flow coming in.");
        return new bytes(0);
    }

    /** @dev Checks before termination of an agreement. */
    function _beforeStopFlowToPipe(bytes calldata _ctx) private view returns (bytes memory cbdata) {
        (address sender, PipeFlowData[] memory pipeFlowData) = getSenderAndPipeFlowData(_ctx);
        require(pipeFlowData.length > 0, "SuperValve: You have not set your allocations yet.");
        require(userAllocations[sender].userToValveFlowRate > 0, "SuperValve: You don't have any flows to stop.");
        return new bytes(0);
    }

    /**************************************************************************
     * User Functions
     *************************************************************************/

    /**
     * @dev Users will call this to set and update their flowData.
     */
    function setUserFlowData(PipeFlowData[] memory _pipeFlowData, ISuperToken _inputToken)
        public
        validToken(_inputToken)
    {
        isFullyAllocated(_pipeFlowData);
        uint256 userPipeFlowDataIndex = userPipeFlowData.length;
        userAllocations[msg.sender].userPipeFlowId = userPipeFlowDataIndex++;
        for (uint256 i; i < _pipeFlowData.length; i++) {
            userPipeFlowData[userPipeFlowDataIndex++].push(_pipeFlowData[i]);
        }
    }

    /**************************************************************************
     * Valve-To-Pipe CRUD Functions
     *************************************************************************/
    /** @dev Creators or updates the valveToPipe flowRate depending on whether the user has an existing agreement.
     * We will update the state to reflect the new flow rate from the SuperValve to the Pipe as well
     * as the users' updated allocation data.
     */
    function _updateValveToPipeFlow(UpdateValveToPipeData memory data)
        internal
        validPipeAddress(data.pipeFlowData.pipeAddress)
        returns (bytes memory newCtx)
    {
        int96 percentage = data.pipeFlowData.percentage;
        address pipeAddress = data.pipeFlowData.pipeAddress;
        require(
            percentage >= 0 && percentage <= ONE_HUNDRED_PERCENT,
            "Your percentage is outside of the acceptable range."
        );

        // get the old userToPipe flow rate
        int96 oldUserToPipeFlowRate = userAllocations[data.sender].allocations[pipeAddress].flowRate;

        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(pipeAddress).setUserFlowWithdrawData(data.sender, oldUserToPipeFlowRate);

        // get and set the new userToPipe flow rate and % allocation to the pipe
        int96 newUserToPipeFlowRate = mulDiv(percentage, data.newUserToValveFlowRate, ONE_HUNDRED_PERCENT);
        userAllocations[data.sender].allocations[pipeAddress] = Allocation(newUserToPipeFlowRate, percentage);

        // get the new total flow rate from valveToPipe given the users' updated flow rate
        int96 newValveToPipeFlowRate = superValveToPipeFlowRates[pipeAddress]
        .sub(oldUserToPipeFlowRate, "Int96 Error: Could not subtract.")
        .add(newUserToPipeFlowRate, "Int96 Error: Could not add.");

        // update the valveToPipe flow rate
        superValveToPipeFlowRates[pipeAddress] = newValveToPipeFlowRate;

        // update the valveToPipeData in IPipe
        IPipe(data.pipeFlowData.pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

        // update the flow agreement between SuperValve and Pipe
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(data.agreementClass),
            abi.encodeWithSelector(
                data.hasAgreement ? cfa.updateFlow.selector : cfa.createFlow.selector,
                data.token,
                pipeAddress,
                newValveToPipeFlowRate,
                data.ctx
            ),
            "0x",
            data.ctx
        );
    }

    /** @dev Updates the valveToPipe flowRate when a user chooses to remove their flow rate.
     * We update the local state to reflect the new flow rate from the SuperValve to the pipe as well as removing
     * the users' allocations.
     */
    function _stopFlowToPipe(
        address _pipeAddress,
        address _sender,
        ISuperToken _token,
        address _agreementClass,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        // get the previous userToPipeFlowRate
        int96 oldUserToPipeFlowRate = userAllocations[_sender].allocations[_pipeAddress].flowRate;

        // update the user flow withdraw data in pipe for accounting purposes
        IPipe(_pipeAddress).setUserFlowWithdrawData(_sender, oldUserToPipeFlowRate);

        // get the new total flow rate from valveToPipe given the users flow rate is 0 now
        int96 newValveToPipeFlowRate = superValveToPipeFlowRates[_pipeAddress].sub(
            oldUserToPipeFlowRate,
            "Int96 Error: Could not subtract."
        );

        // remove users' allocations to the pipe at _pipeAddress
        userAllocations[_sender].allocations[_pipeAddress] = Allocation(0, 0);

        // update the valveToPipe flow rate
        superValveToPipeFlowRates[_pipeAddress] = newValveToPipeFlowRate;

        // update the valveToPipeData in IPipe
        IPipe(_pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

        // update the flow agreement between SuperValve and Pipe
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.updateFlow.selector, _token, _pipeAddress, newValveToPipeFlowRate, _ctx),
            "0x",
            _ctx
        );
    }

    /** @dev This is called in our callback function and either creates (only once) or
     * updates the flow between the SuperValve and a Pipe.
     */
    function _modifyFlowToPipes(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        (address sender, PipeFlowData[] memory pipeFlowData) = getSenderAndPipeFlowData(_ctx);

        // get the newly created/updated userToValve flow rate
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(_token, _agreementId);

        // update the userToValve flow rate to the newly created/updated one
        if (userAllocations[sender].userToValveFlowRate != newUserToValveFlowRate) {
            userAllocations[sender].userToValveFlowRate = newUserToValveFlowRate;
        }

        for (uint256 i; i < pipeFlowData.length; i++) {
            // check if an agreement exists between the SuperValve and Pipe
            (uint256 timestamp, , , ) = cfa.getFlow(_token, address(this), pipeFlowData[i].pipeAddress);

            if (
                // if the user doesn't want to create or update, we skip
                (pipeFlowData[i].percentage == 0 && timestamp == 0) ||
                // if the total flow rate is unchanged AND the percentage allocated to this pipe remains unchanged
                // we don't need to update anything for this pipe
                (userAllocations[sender].userToValveFlowRate == newUserToValveFlowRate &&
                    pipeFlowData[i].percentage ==
                    userAllocations[sender].allocations[pipeFlowData[i].pipeAddress].percentage)
            ) {
                continue;
            }

            newCtx = _updateValveToPipeFlow(
                UpdateValveToPipeData(
                    timestamp > 0,
                    pipeFlowData[i],
                    newUserToValveFlowRate,
                    sender,
                    _token,
                    _agreementClass,
                    _ctx
                )
            );
        }
    }

    /** @dev This is called in our callback function when a user terminates their agreement with the
     * SuperValve.
     */
    function _stopFlowToPipes(
        ISuperToken _token,
        address _agreementClass,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        (address sender, PipeFlowData[] memory pipeFlowData) = getSenderAndPipeFlowData(_ctx);

        // set the userToValve flow rate equal to 0
        userAllocations[sender].userToValveFlowRate = 0;

        for (uint256 i; i < pipeFlowData.length; i++) {
            // if the user has no flow to the pipe, we skip
            bool hasFlowToCurrentPipe = userAllocations[sender].allocations[pipeFlowData[i].pipeAddress].flowRate > 0;
            if (!hasFlowToCurrentPipe) {
                continue;
            }
            newCtx = _stopFlowToPipe(pipeFlowData[i].pipeAddress, sender, _token, _agreementClass, _ctx);
        }
    }

    /**************************************************************************
     * Super App Callbacks
     *************************************************************************/

    /**
     * @dev Before we create the agreement, we need to ensure that the user has actually set their allocations
     * as well as actually having a flow rate that is greater than 0.
     */
    function beforeAgreementCreated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {
        cbdata = _beforeFlowToPipe(_token, _agreementId, _ctx);
    }

    /**
     * @dev After the user starts flowing funds into the SuperValve, we redirect these flows through the
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
        newCtx = _modifyFlowToPipes(_token, _agreementClass, _agreementId, _ctx);
    }

    /**
     * @dev Before we update the agreement, we need to ensure that the user has actually set their allocations
     * as well as actually having a flow rate that is greater than 0.
     */
    function beforeAgreementUpdated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {
        cbdata = _beforeFlowToPipe(_token, _agreementId, _ctx);
    }

    /** @dev If the user updates their flow rates or the proportion that go into the different flows, then we
     * will udpate the total flowed from the SuperValve to the Pipe.
     */
    function afterAgreementUpdated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata
        bytes calldata _ctx
    ) external override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory newCtx) {
        newCtx = _modifyFlowToPipes(_token, _agreementClass, _agreementId, _ctx);
    }

    /**
     * @dev Before we terminate the agreement, we should ensure that the user has an existing flow
     * as well as allocations.
     */
    function beforeAgreementTerminated(
        ISuperToken _token,
        address _agreementClass,
        bytes32, // _agreementId
        bytes calldata, // _agreementData
        bytes calldata _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {
        cbdata = _beforeStopFlowToPipe(_ctx);
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
        newCtx = _stopFlowToPipes(_token, _agreementClass, _ctx);
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

    function isFullyAllocated(PipeFlowData[] memory _pipeFlowData) public pure {
        int96 totalPercentage;
        for (uint256 i; i < _pipeFlowData.length; i++) {
            totalPercentage = totalPercentage.add(_pipeFlowData[i].percentage, "Int96 Error: Could not add.");
        }
        require(totalPercentage == ONE_HUNDRED_PERCENT, "SuperValve: Your flows don't add up to 100%.");
    }

    modifier hasFlowRate(int96 _flowRate) {
        require(_flowRate > 0, "SuperValve: Flow rate must be greater than 0.");
        _;
    }

    modifier validPipeAddress(address _pipeAddress) {
        require(validPipeAddresses[_pipeAddress] == true, "SuperValve: This is not a registered vault address.");
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
