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
        mapping(address => int96) allocations; // allocation %'s
        uint256 userPipeFlowId;
    }
    struct UpdateValveToPipeData {
        bool hasAgreement;
        address pipeAddress;
        int96 percentage;
        int96 newUserToValveFlowRate;
        address sender;
        ISuperToken token;
        address agreementClass;
        bytes ctx;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 public cfa; // private
    ISuperToken public acceptedToken; // private

    address[] public validPipeAddresses; // private
    mapping(address => int96) public superValveToPipeFlowRates; // private
    mapping(address => UserAllocation) public userAllocations; // private

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

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL | SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

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

        int96 previousFlowRate = getUserPipeFlowRate(msg.sender, _pipeAddress);
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

    function getUserPipeFlowRate(address _user, address _pipe) public view returns (int96) {
        UserAllocation storage userAllocation = userAllocations[_user];

        (, int96 totalFlow, , ) = cfa.getFlow(acceptedToken, _user, address(this));
        int96 pipeAllocation = userAllocation.allocations[_pipe];
        return
            totalFlow.mul(pipeAllocation, "Int96 Error: Could not multiply.").div(
                ONE_HUNDRED_PERCENT,
                "Int96 Error: Could not divide."
            );
    }

    function getValidPipeAddresses() public view returns (address[] memory) {
        return validPipeAddresses;
    }

    function getSender(bytes calldata _ctx) internal view returns (address sender) {
        sender = host.decodeCtx(_ctx).msgSender;
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
        for (uint256 i = index; i < validPipeAddresses.length; i++) {
            validPipeAddresses[i] = validPipeAddresses[i + 1];
        }
        validPipeAddresses.pop();
    }

    /** @dev Checks before create of an agreement. */
    function _beforeCreateFlowToPipe(bytes calldata _ctx) private view returns (bytes memory cbdata) {
        address sender = getSender(_ctx);
        isFullyAllocated(sender);
        return new bytes(0);
    }

    /** @dev Checks before update of an agreement. */
    function _beforeUpdateFlowToPipe(bytes32 _agreementId, bytes calldata _ctx)
        private
        view
        returns (bytes memory cbdata)
    {
        address sender = getSender(_ctx);
        isFullyAllocated(sender);
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);
        require(newUserToValveFlowRate > 0, "SuperValve: There is no flow coming in.");
        return new bytes(0);
    }

    /**************************************************************************
     * User Functions
     *************************************************************************/

    /**
     * @dev Users will call this to set and update their flowData.
     */
    function setUserFlowData(PipeFlowData[] memory _pipeFlowData) public {
        require(
            validPipeAddresses.length == _pipeFlowData.length,
            "SuperValve: Your number of allocations is incorrect."
        );
        for (uint256 i; i < validPipeAddresses.length; i++) {
            require(
                validPipeAddresses[i] == _pipeFlowData[i].pipeAddress,
                "SuperValve: This is not a registered vault address."
            );
            userAllocations[msg.sender].allocations[_pipeFlowData[i].pipeAddress] = _pipeFlowData[i].percentage;
        }
        isFullyAllocated(msg.sender);
    }

    function getUserFlowRate() external view returns (int96) {
        (, int96 flowRate, , ) = cfa.getFlow(acceptedToken, msg.sender, address(this));
        return flowRate;
    }

    function getValveFlowRate() external view returns (int96) {
        return cfa.getNetFlow(acceptedToken, address(this));
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
        validPipeAddress(data.pipeAddress)
        returns (bytes memory newCtx)
    {
        int96 percentage = data.percentage;
        address pipeAddress = data.pipeAddress;
        require(
            percentage >= 0 && percentage <= ONE_HUNDRED_PERCENT,
            "SuperValve: Your percentage is outside of the acceptable range."
        );

        // get the old userToPipe flow rate
        int96 oldUserToPipeFlowRate = getUserPipeFlowRate(data.sender, pipeAddress);

        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(pipeAddress).setUserFlowWithdrawData(data.sender, oldUserToPipeFlowRate);

        // get and set the new userToPipe flow rate and % allocation to the pipe
        int96 newUserToPipeFlowRate = mulDiv(percentage, data.newUserToValveFlowRate, ONE_HUNDRED_PERCENT);
        userAllocations[data.sender].allocations[pipeAddress] = percentage;

        // get the new total flow rate from valveToPipe given the users' updated flow rate
        int96 newValveToPipeFlowRate = superValveToPipeFlowRates[pipeAddress]
        .sub(oldUserToPipeFlowRate, "Int96 Error: Could not subtract.")
        .add(newUserToPipeFlowRate, "Int96 Error: Could not add.");

        // update the valveToPipe flow rate
        superValveToPipeFlowRates[pipeAddress] = newValveToPipeFlowRate;

        // update the valveToPipeData in IPipe
        IPipe(data.pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

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
        address _agreementClass,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        // get the previous userToPipeFlowRate
        int96 oldUserToPipeFlowRate = getUserPipeFlowRate(_sender, _pipeAddress);

        // update the user flow withdraw data in pipe for accounting purposes
        IPipe(_pipeAddress).setUserFlowWithdrawData(_sender, oldUserToPipeFlowRate);

        // get the new total flow rate from valveToPipe given the users flow rate is 0 now
        int96 newValveToPipeFlowRate = superValveToPipeFlowRates[_pipeAddress].sub(
            oldUserToPipeFlowRate,
            "Int96 Error: Could not subtract."
        );

        // remove users' allocations to the pipe at _pipeAddress
        userAllocations[_sender].allocations[_pipeAddress] = 0;

        // update the valveToPipe flow rate
        superValveToPipeFlowRates[_pipeAddress] = newValveToPipeFlowRate;

        // update the valveToPipeData in IPipe
        IPipe(_pipeAddress).setPipeFlowData(newValveToPipeFlowRate);

        // update the flow agreement between SuperValve and Pipe
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.updateFlow.selector, acceptedToken, _pipeAddress, newValveToPipeFlowRate, _ctx),
            "0x",
            _ctx
        );
    }

    /** @dev This is called in our callback function and either creates (only once) or
     * updates the flow between the SuperValve and a Pipe.
     */
    function _modifyFlowToPipes(
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        address sender = getSender(_ctx);

        // get the newly created/updated userToValve flow rate
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);

        for (uint256 i; i < validPipeAddresses.length; i++) {
            // check if an agreement exists between the SuperValve and Pipe
            (uint256 timestamp, , , ) = cfa.getFlow(acceptedToken, address(this), validPipeAddresses[i]);
            int96 percentage = userAllocations[sender].allocations[validPipeAddresses[i]];

            newCtx = _updateValveToPipeFlow(
                UpdateValveToPipeData(
                    timestamp > 0,
                    validPipeAddresses[i],
                    percentage,
                    newUserToValveFlowRate,
                    sender,
                    acceptedToken,
                    _agreementClass,
                    _ctx
                )
            );
        }
    }

    /** @dev This is called in our callback function when a user terminates their agreement with the
     * SuperValve.
     */
    function _stopFlowToPipes(address _agreementClass, bytes calldata _ctx) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        address sender = getSender(_ctx);

        for (uint256 i; i < validPipeAddresses.length; i++) {
            // if the user has no flow to the pipe, we skip

            bool hasFlowToCurrentPipe = getUserPipeFlowRate(sender, validPipeAddresses[i]) > 0;
            if (!hasFlowToCurrentPipe) {
                continue;
            }
            newCtx = _stopFlowToPipe(validPipeAddresses[i], sender, _agreementClass, _ctx);
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
        bytes32, // _agreementId
        bytes calldata, // _agreementData
        bytes calldata _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {
        cbdata = _beforeCreateFlowToPipe(_ctx);
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
        newCtx = _modifyFlowToPipes(_agreementClass, _agreementId, _ctx);
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
        cbdata = _beforeUpdateFlowToPipe(_agreementId, _ctx);
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
        newCtx = _modifyFlowToPipes(_agreementClass, _agreementId, _ctx);
    }

    /** @dev Checks before termination of an agreement. */
    function _beforeStopFlowToPipe(bytes calldata _ctx) private view returns (bytes memory cbdata) {
        address sender = getSender(_ctx);
        (, int96 totalFlow, , ) = cfa.getFlow(acceptedToken, sender, address(this));
        require(totalFlow > 0, "SuperValve: You don't have any flows to stop.");
        return new bytes(0);
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
        newCtx = _stopFlowToPipes(_agreementClass, _ctx);
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

    function isFullyAllocated(address _sender) public view {
        int96 totalPercentage;
        for (uint256 i; i < validPipeAddresses.length; i++) {
            totalPercentage = totalPercentage.add(
                userAllocations[_sender].allocations[validPipeAddresses[i]],
                "Int96 Error: Could not add."
            );
        }
        require(totalPercentage == ONE_HUNDRED_PERCENT, "SuperValve: Your flows don't add up to 100%.");
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
