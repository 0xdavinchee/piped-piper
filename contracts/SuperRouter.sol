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
import { Int96SafeMath } from "@superfluid-finance/ethereum-contracts/contracts/utils/Int96SafeMath.sol";

/// @author Piped-Piper ETHGlobal Hack Money Team
/// @title Handles flow agreement creation with multiple users, aggregates this flow and redirects
/// it to vaults based on the users' selected allocations.
contract SuperValve is SuperAppBase {
    int96 private constant ONE_HUNDRED_PERCENT = 1000;

    using SignedSafeMath for int256;
    using Int96SafeMath for int96;

    struct PipeFlowData {
        int96 percentage; // percentage will be between 0 and 1000 (allows one decimal place of contrast)
        address pipeAddress;
    }
    struct UserAllocation {
        int96 userToValveFlowRate;
        mapping(address => Allocation) allocations;
    }
    struct Allocation {
        int96 flowRate;
        int96 percentage;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;

    mapping(address => bool) private validPipeAddresses;
    mapping(address => int96) private superValveToPipeFlowRates;
    mapping(address => UserAllocation) private userAllocations;

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

        uint256 configWord =
            SuperAppDefinitions.APP_LEVEL_FINAL |
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

        // update the valveToPipeData in IPipe (same flow rate, but need to calculate total flow
        // before withdrawal)
        pipe.setPipeFlowData(flowRate);

        int96 previousFlowRate = userAllocations[msg.sender].allocations[_pipeAddress].flowRate;
        if (pipe.totalWithdrawableBalance(msg.sender, previousFlowRate) > 0) {
            pipe.withdraw(previousFlowRate);
        }
    }

    /** @dev User can call this to withdraw all funds and stop flow
     * into SuperValve.
     */
    function withdrawAndStopFlows(address[] memory _pipeAddresses) public {
        withdraw(_pipeAddresses);
        stopFlows();
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
        returns (address sender, PipeFlowData[] memory pipeFlowData)
    {
        bytes memory rawUserData = host.decodeCtx(_ctx).userData;
        sender = host.decodeCtx(_ctx).msgSender;
        pipeFlowData = abi.decode(rawUserData, (PipeFlowData[]));
    }

    /**************************************************************************
     * User Functions
     *************************************************************************/

    /**
     * @dev Users will call this to set up the initial agreement between themselves and the SuperValve.
     */
    function setupFlows(
        PipeFlowData[] memory _pipeFlowData,
        int96 _flowRate,
        ISuperToken _inputToken
    ) public isFullyAllocated(_pipeFlowData) validToken(_inputToken) hasFlowRate(_flowRate) {
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.createFlow.selector, _inputToken, address(this), _flowRate, new bytes(0)),
            abi.encode(_pipeFlowData)
        );
    }

    /**
     * @dev User will call this to update the agreement between themselves and the SuperValve.
     */
    function modifyFlows(
        PipeFlowData[] memory _pipeFlowData,
        int96 _flowRate,
        ISuperToken _inputToken
    ) public isFullyAllocated(_pipeFlowData) validToken(_inputToken) hasFlowRate(_flowRate) {
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.updateFlow.selector, _inputToken, address(this), _flowRate, new bytes(0)),
            abi.encode(_pipeFlowData)
        );
    }

    /**
     * @dev User will call this to stop their agreement between themselves and the SuperValve.
     */
    function stopFlows() public {
        require(userAllocations[msg.sender].userToValveFlowRate > 0, "You have no existing flows to stop.");
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.deleteFlow.selector, acceptedToken, msg.sender, address(this)),
            "0x"
        );
    }

    /** @dev Creates the initial flow from SuperValve to Pipe.
     * This will only occur once for each pipe, as there can only be one flow between two accounts (valve and pipe).
     * We will update the state to track the users userToValveFlowRate AND % allocation of the user to the pipe.
     */
    function _createValveToPipeFlow(
        PipeFlowData memory _pipeFlowData,
        int96 _newUserToValveFlowRate,
        address _sender,
        address _agreementClass,
        bytes calldata _ctx
    ) internal validPipeAddress(_pipeFlowData.pipeAddress) returns (bytes memory newCtx) {
        require(
            _pipeFlowData.percentage > 0 && _pipeFlowData.percentage <= ONE_HUNDRED_PERCENT,
            "Your percentage is outside of the acceptable range."
        );

        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(_pipeFlowData.pipeAddress).setUserFlowWithdrawData(_sender, 0);

        // get and set the userToPipe flow rate and % allocation to the pipe
        int96 userToPipeFlowRate = mulDiv(_pipeFlowData.percentage, _newUserToValveFlowRate, ONE_HUNDRED_PERCENT);
        userAllocations[_sender].allocations[_pipeFlowData.pipeAddress] = Allocation(
            userToPipeFlowRate,
            _pipeFlowData.percentage
        );

        // get the new total flow rate from valveToPipe given the users' updated flow rate
        int96 newValveToPipeFlowRate =
            superValveToPipeFlowRates[_pipeFlowData.pipeAddress].add(
                _newUserToValveFlowRate,
                "Int96 Error: Could not add."
            );

        // increment the valveToPipe flow rate
        superValveToPipeFlowRates[_pipeFlowData.pipeAddress] = newValveToPipeFlowRate;

        // update the valveToPipeData in IPipe
        IPipe(_pipeFlowData.pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

        // create the flow agreement between the SuperValve and Pipe
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.createFlow.selector, _pipeFlowData.pipeAddress, newValveToPipeFlowRate, _ctx),
            "0x",
            _ctx
        );
    }

    /** @dev Updates the valveToPipe flowRate when a user updates their flow rate.
     * We will update the state to reflect the new flow rate from the SuperValve to the Pipe as well
     * as the users' updated allocation data.
     */
    function _updateValveToPipeFlow(
        PipeFlowData memory _pipeFlowData,
        int96 _newUserToValveFlowRate,
        address _sender,
        ISuperToken _token,
        address _agreementClass,
        bytes calldata _ctx
    ) internal validPipeAddress(_pipeFlowData.pipeAddress) returns (bytes memory newCtx) {
        int96 percentage = _pipeFlowData.percentage;
        address pipeAddress = _pipeFlowData.pipeAddress;
        require(
            percentage >= 0 && percentage <= ONE_HUNDRED_PERCENT,
            "Your percentage is outside of the acceptable range."
        );

        // get the old userToPipe flow rate
        int96 oldUserToPipeFlowRate = userAllocations[_sender].allocations[pipeAddress].flowRate;

        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(pipeAddress).setUserFlowWithdrawData(_sender, oldUserToPipeFlowRate);

        // get and set the new userToPipe flow rate and % allocation to the pipe
        int96 newUserToPipeFlowRate = mulDiv(percentage, _newUserToValveFlowRate, ONE_HUNDRED_PERCENT);
        userAllocations[_sender].allocations[pipeAddress] = Allocation(newUserToPipeFlowRate, percentage);

        // get the new total flow rate from valveToPipe given the users' updated flow rate
        int96 newValveToPipeFlowRate =
            superValveToPipeFlowRates[pipeAddress].sub(oldUserToPipeFlowRate, "Int96 Error: Could not subtract.").add(
                newUserToPipeFlowRate,
                "Int96 Error: Could not add."
            );

        // update the valveToPipe flow rate
        superValveToPipeFlowRates[pipeAddress] = newValveToPipeFlowRate;

        // update the valveToPipeData in IPipe
        IPipe(_pipeFlowData.pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

        // update the flow agreement between SuperValve and Pipe
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.updateFlow.selector, _token, pipeAddress, newValveToPipeFlowRate, _ctx),
            "0x",
            _ctx
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
        int96 newValveToPipeFlowRate =
            superValveToPipeFlowRates[_pipeAddress].sub(oldUserToPipeFlowRate, "Int96 Error: Could not subtract.");

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
        userAllocations[sender].userToValveFlowRate = newUserToValveFlowRate;

        for (uint256 i; i < pipeFlowData.length; i++) {
            // check if an agreement exists between the SuperValve and Pipe
            (uint256 timestamp, , , ) = cfa.getFlow(_token, address(this), pipeFlowData[i].pipeAddress);
            bool _agreementExists = timestamp > 0;

            if (
                // if the user doesn't want to create or update, we skip
                (pipeFlowData[i].percentage == 0 && !_agreementExists) ||
                // if the total flow rate is unchanged AND the percentage allocated to this pipe remains unchanged
                // we don't need to update anything for this pipe
                (userAllocations[sender].userToValveFlowRate == newUserToValveFlowRate &&
                    pipeFlowData[i].percentage ==
                    userAllocations[sender].allocations[pipeFlowData[i].pipeAddress].percentage)
            ) {
                continue;
            }

            // if an agreement between the valve and pipe doesn't exist, create one
            if (!_agreementExists) {
                newCtx = _createValveToPipeFlow(pipeFlowData[i], newUserToValveFlowRate, sender, _agreementClass, _ctx);

                // else, just update it
            } else {
                newCtx = _updateValveToPipeFlow(
                    pipeFlowData[i],
                    newUserToValveFlowRate,
                    sender,
                    _token,
                    _agreementClass,
                    _ctx
                );
            }
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

    modifier hasFlowRate(int96 _flowRate) {
        require(_flowRate > 0, "Flow rate must be greater than 0.");
        _;
    }

    modifier isFullyAllocated(PipeFlowData[] memory _pipeFlowData) {
        int96 totalPercentage;
        for (uint256 i; i < _pipeFlowData.length; i++) {
            totalPercentage = totalPercentage.add(_pipeFlowData[i].percentage, "Int96 Error: Could not add.");
        }
        require(totalPercentage == ONE_HUNDRED_PERCENT, "Your flows don't add up to 100%.");
        _;
    }

    modifier validPipeAddress(address _pipeAddress) {
        require(validPipeAddresses[_pipeAddress] == true, "This is not a registered vault address.");
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
