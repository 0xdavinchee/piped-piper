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
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
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
    int96 private constant ONE_HUNDRED_PERCENT = 100;

    using SignedSafeMath for int256;
    using Int96SafeMath for int96;
    using SafeMath for uint256;

    struct ReceiverData {
        address pipeRecipient;
        int96 percentageAllocation;
    }
    struct Allocations {
        ReceiverData[] receivers;
    }
    struct UpdateValveToPipeData {
        bytes4 selector;
        ISuperfluid.Context context;
        int96 oldUserToValveFlowRate;
        int96 newUserToValveFlowRate;
        bytes ctx;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 public cfa; // private
    ISuperToken public acceptedToken; // private

    address[] public validPipeAddresses; // private
    mapping(address => mapping(address => int96)) public userAllocations; // private

    event NewPipeInflow(address _pipe, int96 _flowRate);
    event PipeInflowDeleted(address _pipe);
    event UpdateFlowInfo(
        address _pipe,
        uint256 targetAllowance,
        int96 targetUserToPipeFlowRate,
        int96 previousValveToPipeFlowRate,
        int96 oldUserToPipeFlowRate,
        int96 userToPipeFlowRateDifference
    );
    event FlowRateInfo(uint256 appAllowance, int96 safeFlowRate);
    event RealFlowRate(int96 flowRate);
    event EndFlowRate(int96 endFlowRate);
    event Terminator();

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

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL;

        host.registerApp(configWord);
    }

    /**************************************************************************
     * Pipe Specific Functions
     *************************************************************************/

    /**
     * @dev Withdraws all your funds from all the different vaults/pipes.
     */
    function withdraw(address[] memory _pipeAddresses) public {
        for (uint256 i; i < _pipeAddresses.length; i++) {
            withdrawFromVault(_pipeAddresses[i], msg.sender);
        }
    }

    /** @dev Withdraws your funds from a single vault/pipe.
     */
    function withdrawFromVault(address _pipeAddress, address _user) public validPipeAddress(_pipeAddress) {
        IPipe pipe = IPipe(_pipeAddress);
        (, int96 valveToPipeFlowRate, , ) = cfa.getFlow(acceptedToken, address(this), _pipeAddress);

        int96 previousFlowRate = getUserPipeFlowRate(_user, _pipeAddress);
        if (pipe.totalWithdrawableBalance(_user, previousFlowRate) > 0) {
            // update the valveToPipeData in IPipe (same flow rate, but need to calculate total flow
            // before withdrawal)
            pipe.setPipeFlowData(valveToPipeFlowRate);

            pipe.withdraw(previousFlowRate);
        }
    }

    // TODO: This doesn't currently work.
    /** @dev Gets the withdrawable flow balance of all pipes as well
     * as the current timestamp which will allow client side calculation
     * of live flow.
     */
    function getUserTotalFlowedBalance() public view returns (int256 totalBalance, uint256 timestamp) {
        for (uint256 i; i < validPipeAddresses.length; i++) {
            int96 userToPipeFlowRate = getUserPipeFlowRate(msg.sender, validPipeAddresses[i]);
            int256 withdrawableFlowAmount = getUserPipeFlowBalance(
                msg.sender,
                validPipeAddresses[i],
                userToPipeFlowRate
            );
            totalBalance = totalBalance.add(withdrawableFlowAmount);
        }
        timestamp = block.timestamp;
    }

    /** @dev Gets the withdrawable flow balance from a single pipe,
     * which is essentially your deposited balance into the pipe.
     */
    function getUserPipeFlowBalance(
        address _user,
        address _pipeAddress,
        int96 _flowRate
    ) public view returns (int256) {
        return (IPipe(_pipeAddress).withdrawableFlowBalance(_user, _flowRate));
    }

    function getUserPipeFlowRate(address _user, address _pipe) public view returns (int96) {
        (, int96 userToValveFlow, , ) = cfa.getFlow(acceptedToken, _user, address(this));
        int96 pipeAllocationPercentage = userAllocations[_user][_pipe];
        return mulDiv(userToValveFlow, pipeAllocationPercentage, ONE_HUNDRED_PERCENT);
    }

    function getUserPipeAllocation(address _user, address _pipeAddress) public view returns (int96 pipeAllocationPct) {
        pipeAllocationPct = userAllocations[_user][_pipeAddress];
    }

    function getValidPipeAddresses() public view returns (address[] memory) {
        return validPipeAddresses;
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

        for (uint256 i; i < validPipeAddresses.length; i++) {
            if (validPipeAddresses[i] == _address) {
                index = i;
            }
        }
        validPipeAddresses[index] = validPipeAddresses[validPipeAddresses.length - 1];
        validPipeAddresses.pop();
    }

    /**************************************************************************
     * Helper Functions
     *************************************************************************/
    /**
     * @dev Returns a * b / c.
     */
    function mulDiv(
        int96 a,
        int96 b,
        int96 c
    ) internal pure returns (int96) {
        if (c == 0) return 0;
        return int96(int256(a).mul(int256(b)).div(int256(c)));
    }

    function _parseUserData(bytes memory userData) private pure returns (Allocations memory userDataAllocations) {
        address[] memory pipeRecipients;
        int96[] memory inflowPercentageAllocations;
        (pipeRecipients, inflowPercentageAllocations) = abi.decode(userData, (address[], int96[]));
        userDataAllocations.receivers = new ReceiverData[](pipeRecipients.length);

        for (uint256 i = 0; i < pipeRecipients.length; i++) {
            userDataAllocations.receivers[i] = ReceiverData(pipeRecipients[i], inflowPercentageAllocations[i]);
        }
    }

    function getSender(bytes calldata _ctx) internal view returns (address sender) {
        sender = host.decodeCtx(_ctx).msgSender;
    }

    /** @dev Checks before update of an agreement. */
    function _beforeModifyFlowToPipe(bytes32 _agreementId) private view returns (bytes memory cbdata) {
        (, int96 oldUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);
        int96 previousValveInflowRate = cfa.getNetFlow(acceptedToken, address(this));
        cbdata = abi.encode(oldUserToValveFlowRate, previousValveInflowRate);
    }

    function getCallbackData(bytes memory _cbdata)
        private
        pure
        returns (int96 oldUserToValveFlowRate, int96 previousValveInflowRate)
    {
        (oldUserToValveFlowRate, previousValveInflowRate) = abi.decode(_cbdata, (int96, int96));
    }

    /**************************************************************************
     * Valve-To-Pipe CRUD Functions
     *************************************************************************/
    /** @dev Creators or updates the valveToPipe flowRate depending on whether the user has an existing agreement.
     * We will update the state to reflect the new flow rate from the SuperValve to the Pipe as well
     * as the users' updated allocation data.
     */
    function _updateValveToPipesFlow(Allocations memory allocations, UpdateValveToPipeData memory data)
        internal
        returns (bytes memory newCtx)
    {
        newCtx = data.ctx;

        // in case of mfa, we underutlize the app allowance for simplicity
        int96 safeFlowRate = data.newUserToValveFlowRate == 0
            ? 0
            : cfa.getMaximumFlowRateFromDeposit(acceptedToken, data.context.appAllowanceGranted.sub(1));
        data.context.appAllowanceGranted = data.newUserToValveFlowRate == 0
            ? 0
            : cfa.getDepositRequiredForFlowRate(acceptedToken, safeFlowRate);

        emit FlowRateInfo(data.context.appAllowanceGranted, safeFlowRate);
        emit RealFlowRate(data.newUserToValveFlowRate);

        for (uint256 i = 0; i < allocations.receivers.length; i++) {
            ReceiverData memory receiverData = allocations.receivers[i];
            int96 newPercentage = receiverData.percentageAllocation;
            require(
                newPercentage >= 0 && newPercentage <= ONE_HUNDRED_PERCENT,
                "SuperValve: Your percentage is outside of the acceptable range."
            );

            // get previous valveToPipe flow rate
            (, int96 previousValveToPipeFlowRate, , ) = cfa.getFlow(
                acceptedToken,
                address(this),
                receiverData.pipeRecipient
            );

            // if the user does not want to allocate anything to the pipe and no agreement exists currently,
            // we skip.
            if (newPercentage == 0 && previousValveToPipeFlowRate == 0) {
                continue;
            }

            // get target allowance based on app allowance granted as well as percentage allocation
            uint256 targetAllowance = data
            .context
            .appAllowanceGranted
            .mul(uint256(receiverData.percentageAllocation))
            .div(100);

            int96 targetUserToPipeFlowRate = data.newUserToValveFlowRate == 0
                ? 0
                : cfa.getMaximumFlowRateFromDeposit(acceptedToken, targetAllowance);
            data.newUserToValveFlowRate = data.newUserToValveFlowRate.sub(targetUserToPipeFlowRate, "");

            // get the old userToPipe flow rate (totalUserToValve * previousPctAlloc / 100%)
            int96 oldUserToPipeFlowRate = mulDiv(
                data.oldUserToValveFlowRate,
                userAllocations[data.context.msgSender][receiverData.pipeRecipient],
                ONE_HUNDRED_PERCENT
            );

            // new flow rate subtracted by previous flow rate to get difference
            int96 userToPipeFlowRateDifference = targetUserToPipeFlowRate.sub(
                oldUserToPipeFlowRate,
                "Int96: Error subtracting."
            );

            emit UpdateFlowInfo(
                receiverData.pipeRecipient,
                targetAllowance,
                targetUserToPipeFlowRate,
                previousValveToPipeFlowRate,
                oldUserToPipeFlowRate,
                userToPipeFlowRateDifference
            );
            userAllocations[data.context.msgSender][receiverData.pipeRecipient] = newPercentage;

            // update the user flow withdraw data in Pipe for accounting purposes
            IPipe(receiverData.pipeRecipient).setUserFlowWithdrawData(data.context.msgSender, oldUserToPipeFlowRate);

            int96 newValveToPipeFlowRate = previousValveToPipeFlowRate.add(
                userToPipeFlowRateDifference,
                "Int96: Could not add."
            );

            IPipe(receiverData.pipeRecipient).setPipeFlowData(newValveToPipeFlowRate <= 0 ? 0 : newValveToPipeFlowRate);

            if (newValveToPipeFlowRate > 0) {
                (newCtx, ) = host.callAgreementWithContext(
                    cfa,
                    abi.encodeWithSelector(
                        data.selector,
                        acceptedToken,
                        receiverData.pipeRecipient,
                        newValveToPipeFlowRate,
                        new bytes(0) // placeholder
                    ),
                    "0x",
                    newCtx
                );

                emit NewPipeInflow(receiverData.pipeRecipient, newValveToPipeFlowRate);
            } else {
                (newCtx, ) = host.callAgreementWithContext(
                    cfa,
                    abi.encodeWithSelector(
                        cfa.deleteFlow.selector,
                        acceptedToken,
                        address(this),
                        receiverData.pipeRecipient,
                        new bytes(0) // placeholder
                    ),
                    "0x",
                    newCtx
                );

                emit PipeInflowDeleted(receiverData.pipeRecipient);
            }
        }
        emit EndFlowRate(data.newUserToValveFlowRate);
        require(data.newUserToValveFlowRate >= 0, "SuperValve: Outflow is greater than the inflow from the user.");
    }

    /**************************************************************************
     * Super App Callbacks
     *************************************************************************/

    /**
     * @dev Before we create an agreement we want to get the previous flow rate.
     */
    function beforeAgreementCreated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata // _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {
        cbdata = _beforeModifyFlowToPipe(_agreementId);
    }

    /**
     * @dev After the user starts flowing funds into the SuperValve, we redirect these flows through the
     * various pipes to the vaults accordingly based on the users selection vaults (pipes) in setupFlows.
     */
    function afterAgreementCreated(
        ISuperToken, // _token,
        address, // _agreementClass
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        newCtx = _ctx;
        ISuperfluid.Context memory sfContext = host.decodeCtx(_ctx);

        Allocations memory userDataAllocations = _parseUserData(sfContext.userData);

        // get the newly created/updated userToValve flow rate
        (int96 oldUserToValveFlowRate, ) = getCallbackData(_cbdata);
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);
        newCtx = _updateValveToPipesFlow(
            userDataAllocations,
            UpdateValveToPipeData(
                cfa.createFlow.selector,
                sfContext,
                oldUserToValveFlowRate,
                newUserToValveFlowRate,
                newCtx
            )
        );
    }

    /**
     * @dev Before we update an agreement we want to get the previous flow rate.
     */
    function beforeAgreementUpdated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata // _ctx
    ) external view override onlyHost onlyExpected(_token, _agreementClass) returns (bytes memory cbdata) {
        cbdata = _beforeModifyFlowToPipe(_agreementId);
    }

    /** @dev If the user updates their flow rates or the proportion that go into the different flows, then we
     * will udpate the total flowed from the SuperValve to the Pipe.
     */
    function afterAgreementUpdated(
        ISuperToken, // _token
        address, // _agreementClass
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        newCtx = _ctx;
        ISuperfluid.Context memory sfContext = host.decodeCtx(_ctx);

        Allocations memory userDataAllocations = _parseUserData(sfContext.userData);

        // get the newly created/updated userToValve flow rate
        (int96 oldUserToValveFlowRate, ) = getCallbackData(_cbdata);
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);
        newCtx = _updateValveToPipesFlow(
            userDataAllocations,
            UpdateValveToPipeData(
                cfa.updateFlow.selector,
                sfContext,
                oldUserToValveFlowRate,
                newUserToValveFlowRate,
                newCtx
            )
        );
    }

    /**
     * @dev Before we update an agreement we want to get the previous flow rate.
     */
    function beforeAgreementTerminated(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata // _ctx
    ) external view override returns (bytes memory cbdata) {
        // According to the app basic law, we should never revert in a termination callback
        if (_token != acceptedToken || !_isCFAv1(_agreementClass) || msg.sender != address(host)) {
            return new bytes(0);
        }
        cbdata = _beforeModifyFlowToPipe(_agreementId);
    }

    /** @dev If the user removes their flow rates, we will update the state accordingly.
     */
    function afterAgreementTerminated(
        ISuperToken, // _token,
        address, // _agreementClass,
        bytes32 _agreementId,
        bytes calldata, // _agreementData
        bytes calldata _cbdata,
        bytes calldata _ctx
    ) external override returns (bytes memory newCtx) {
        newCtx = _ctx;
        ISuperfluid.Context memory sfContext = host.decodeCtx(_ctx);

        Allocations memory userDataAllocations = _parseUserData(sfContext.userData);
        emit Terminator();
        // get the newly created/updated userToValve flow rate
        (int96 oldUserToValveFlowRate, ) = getCallbackData(_cbdata);
        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);
        newCtx = _updateValveToPipesFlow(
            userDataAllocations,
            UpdateValveToPipeData(
                cfa.updateFlow.selector,
                sfContext,
                oldUserToValveFlowRate,
                newUserToValveFlowRate,
                newCtx
            )
        );
    }

    /**************************************************************************
     * Utilities
     *************************************************************************/

    function _isAcceptedToken(ISuperToken _superToken) private view returns (bool) {
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

    modifier onlyHost() {
        require(msg.sender == address(host), "SuperValve: support only one host");
        _;
    }

    modifier onlyExpected(ISuperToken _superToken, address _agreementClass) {
        require(_isAcceptedToken(_superToken), "SuperValve: not accepted tokens");
        require(_isCFAv1(_agreementClass), "SuperValve: only CFAv1 supported");
        _;
    }
}
