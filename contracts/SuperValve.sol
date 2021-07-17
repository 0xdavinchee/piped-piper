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
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";

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
    using SafeCast for uint256;

    struct ReceiverData {
        address pipeRecipient;
        int96 percentageAllocation;
    }
    struct Allocations {
        ReceiverData[] receivers;
    }
    struct UpdateValveToPipeData {
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
    mapping(address => mapping(address => int96)) public userFlowRates;
    int256 public totalValveBalance;
    uint256 public valveFlowRateLastUpdated;

    event NewPipeInflow(address _pipe, int96 _flowRate);
    event NewPipeAddress(address _pipe);
    event RemovedPipeAddress(address _pipe);
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
    event ValveBalanceUpdated(int256 valveBalance, uint256 timestamp);
    event ValveBalanceModify(int96 flowRate, int256 valveBalanceOld, int256 valveBalanceNew, uint256 timestamp);
    event Withdrawal(uint256 withdrawalAmount);
    event WithdrawalData(int256 oldValveBalance, int256 newValveBalance, uint256 withdrawalAmount, int256 totalAdditionalFlow);
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
        uint256 totalWithdrawalAmount;
        int256 totalAdditionalFlows;
        for (uint256 i; i < _pipeAddresses.length; i++) {
            // prior to withdrawal, we must first add any additional flows to totalValveBalance
            (, int96 valveToPipeFlowRate, ,) = cfa.getFlow(acceptedToken, address(this), _pipeAddresses[i]);
            int256 flowAmountSinceUpdate = (block.timestamp.sub(valveFlowRateLastUpdated)).toInt256().mul(valveToPipeFlowRate);
            totalAdditionalFlows = totalAdditionalFlows.add(flowAmountSinceUpdate);
            uint256 pipeWithdrawAmount = withdrawFromPipeVault(_pipeAddresses[i], valveToPipeFlowRate, msg.sender);
            totalWithdrawalAmount = totalWithdrawalAmount.add(pipeWithdrawAmount);
        }
        int256 newValveBalance = totalValveBalance.add(totalAdditionalFlows).sub(totalWithdrawalAmount.toInt256());
        emit WithdrawalData(totalValveBalance, newValveBalance, totalWithdrawalAmount, totalAdditionalFlows);
        totalValveBalance = newValveBalance;
        valveFlowRateLastUpdated = block.timestamp;

        emit ValveBalanceUpdated(newValveBalance, block.timestamp);

        emit Withdrawal(totalWithdrawalAmount);
    }

    /** @dev Withdraws your funds from a single vault/pipe.
     */
    function withdrawFromPipeVault(address _pipeAddress, int96 _valveToPipeFlowRate, address _user)
        public
        validPipeAddress(_pipeAddress)
        returns (uint256 pipeWithdrawalAmount)
    {
        IPipe pipe = IPipe(_pipeAddress);

        int96 previousUserToPipeFlowRate = getUserPipeFlowRate(_user, _pipeAddress);
        if (pipe.totalWithdrawableBalance(_user, previousUserToPipeFlowRate) > 0) {
            // We need to update the total flowed to pipe amount otherwise this is 0 initially and
            // if they try to withdraw from vault, they get nothing.
            pipe.setUserFlowWithdrawData(_user, previousUserToPipeFlowRate);
            // update the valveToPipeData in IPipe (same flow rate, but need to calculate total flow
            // before withdrawal)
            pipe.setPipeFlowData(_valveToPipeFlowRate);

            pipeWithdrawalAmount = pipe.withdraw(previousUserToPipeFlowRate, _user);
        }
    }

    /** @dev Gets the withdrawable flow balance of all pipes as well
     * as the current timestamp which will allow client side calculation
     * of live flow.
     */
    function getUserTotalFlowedBalance(address _user) public view returns (int256 totalBalance, uint256 timestamp) {
        for (uint256 i; i < validPipeAddresses.length; i++) {
            int96 userToPipeFlowRate = getUserPipeFlowRate(_user, validPipeAddresses[i]);
            int256 withdrawableFlowAmount = getUserPipeFlowBalance(_user, validPipeAddresses[i], userToPipeFlowRate);
            totalBalance = totalBalance.add(withdrawableFlowAmount);
        }
        timestamp = block.timestamp;
    }

    /** @dev Gets the withdrawable flow balance from a single pipe,
     * which is essentially your deposited balance into the pipe,
     * this includes anything deposited into a vault.
     */
    function getUserPipeFlowBalance(
        address _user,
        address _pipeAddress,
        int96 _flowRate
    ) public view returns (int256) {
        return (IPipe(_pipeAddress).totalWithdrawableBalance(_user, _flowRate));
    }

    function getUserPipeFlowRate(address _user, address _pipe) public view returns (int96) {
        return userFlowRates[_user][_pipe];
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
        require(!isValidPipeAddress(_address), "SuperValve: This pipe address is already a valid pipe address.");
        validPipeAddresses.push(_address);
        emit NewPipeAddress(_address);
    }

    /** @dev Allow the admin role (the deployer of the contract), to add valid pipe addresses. */
    function removePipeAddress(address _address) external {
        require(isValidPipeAddress(_address), "SuperValve: This pipe address is not a valid pipe address.");
        require(hasRole(ADMIN, msg.sender), "SuperValve: You don't have permissions for this action.");
        uint256 index;

        for (uint256 i; i < validPipeAddresses.length; i++) {
            if (validPipeAddresses[i] == _address) {
                index = i;
            }
        }
        validPipeAddresses[index] = validPipeAddresses[validPipeAddresses.length - 1];
        validPipeAddresses.pop();
        emit RemovedPipeAddress(_address);
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

    /** @dev Gets the total valve balance. We subtract the current time from the previous updated
     * time to get the time passed since a valve flow rate update and multiply this by the flow rate.
     */
    function getTotalValveBalance(int96 _flowRate) public view returns (int256, uint256) {
        int256 flowAmountSinceLastUpdate = (block.timestamp.sub(valveFlowRateLastUpdated)).toInt256().mul(_flowRate);
        return (
            totalValveBalance.add(flowAmountSinceLastUpdate),
            block.timestamp
        );
    }

    /**************************************************************************
     * Valve-To-Pipe CRUD Functions
     *************************************************************************/

    /** @dev Modify multi flow function which is called after any modification of agreement. */
    function _modifyMultiFlow(
        bytes32 _agreementId,
        bytes calldata _cbdata,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        ISuperfluid.Context memory sfContext = host.decodeCtx(_ctx);

        Allocations memory userDataAllocations = _parseUserData(sfContext.userData);

        // get the newly created/updated userToValve flow rate
        (int96 oldUserToValveFlowRate, ) = getCallbackData(_cbdata);

        (, int96 newUserToValveFlowRate, , ) = cfa.getFlowByID(acceptedToken, _agreementId);
        newCtx = _updateValveToPipesFlow(
            userDataAllocations,
            UpdateValveToPipeData(sfContext, oldUserToValveFlowRate, newUserToValveFlowRate, newCtx)
        );
    }

    /** @dev Creators or updates the valveToPipe flowRate depending on whether the user has an existing agreement.
     * We will update the state to reflect the new flow rate from the SuperValve to the Pipe as well
     * as the users' updated allocation data.
     */
    function _updateValveToPipesFlow(Allocations memory allocations, UpdateValveToPipeData memory data)
        internal
        returns (bytes memory newCtx)
    {
        newCtx = data.ctx;
        bytes4 selector;

        // in case of mfa, we underutlize the app allowance for simplicity
        int96 safeFlowRate =
            data.newUserToValveFlowRate == 0
                ? 0
                : cfa.getMaximumFlowRateFromDeposit(acceptedToken, data.context.appAllowanceGranted.sub(1));
        data.context.appAllowanceGranted = data.newUserToValveFlowRate == 0
            ? 0
            : cfa.getDepositRequiredForFlowRate(acceptedToken, safeFlowRate);

        emit FlowRateInfo(data.context.appAllowanceGranted, safeFlowRate);
        emit RealFlowRate(data.newUserToValveFlowRate);
        {        
        int96 totalPercentage;
        for (uint256 i = 0; i < allocations.receivers.length; i++) {
            require(
                allocations.receivers[i].percentageAllocation >= 0 && allocations.receivers[i].percentageAllocation <= ONE_HUNDRED_PERCENT,
                "SuperValve: Your percentage is outside of the acceptable range."
            );
            totalPercentage += allocations.receivers[i].percentageAllocation;
        }
        require(totalPercentage == 100 || totalPercentage == 0, "SuperValve: Your allocations must add up to 100% or be 0%.");
        }
        for (uint256 i = 0; i < allocations.receivers.length; i++) {
            ReceiverData memory receiverData = allocations.receivers[i];
            int96 newPercentage = receiverData.percentageAllocation;

            require(isValidPipeAddress(receiverData.pipeRecipient), "SuperValve: The pipe address you have entered is not valid.");

            // get previous valveToPipe flow rate
            (, int96 previousValveToPipeFlowRate, , ) =
                cfa.getFlow(acceptedToken, address(this), receiverData.pipeRecipient);

            // we increment the totalValveBalance of the total flowed to each pipe here
            totalValveBalance = totalValveBalance.add((block.timestamp.sub(valveFlowRateLastUpdated)).toInt256().mul(previousValveToPipeFlowRate));

            // if the user does not want to allocate anything to the pipe and no agreement exists currently,
            // we skip.
            if (newPercentage == 0 && previousValveToPipeFlowRate == 0) {
                continue;
            }

            // if an agreement exists between the valve and pipe, we just update the flow
            if (previousValveToPipeFlowRate == 0) {
                selector = cfa.createFlow.selector;
            } else {
                selector = cfa.updateFlow.selector;
            }

            // get target allowance based on app allowance granted as well as percentage allocation
            uint256 targetAllowance =
                data.context.appAllowanceGranted.mul(uint256(receiverData.percentageAllocation)).div(100);

            // get the target flow rate based on target allowance
            int96 targetUserToPipeFlowRate =
                data.newUserToValveFlowRate == 0
                    ? 0
                    : cfa.getMaximumFlowRateFromDeposit(acceptedToken, targetAllowance);

            // decrement from total user to valve flow rate
            data.newUserToValveFlowRate = data.newUserToValveFlowRate.sub(targetUserToPipeFlowRate, "");

            // get the old userToPipe flow rate (we cannot calculate this from the agreement flow rate)
            // we must save the targetFlowRate and use this each following time.
            int96 oldUserToPipeFlowRate = userFlowRates[data.context.msgSender][receiverData.pipeRecipient];

            // new flow rate subtracted by previous flow rate to get difference
            int96 userToPipeFlowRateDifference =
                targetUserToPipeFlowRate.sub(oldUserToPipeFlowRate, "Int96: Error subtracting.");

            emit UpdateFlowInfo(
                receiverData.pipeRecipient,
                targetAllowance,
                targetUserToPipeFlowRate,
                previousValveToPipeFlowRate,
                oldUserToPipeFlowRate,
                userToPipeFlowRateDifference
            );
            
            // update the user's allocations and flow rate
            userAllocations[data.context.msgSender][receiverData.pipeRecipient] = newPercentage;
            userFlowRates[data.context.msgSender][receiverData.pipeRecipient] = targetUserToPipeFlowRate;

            // update the user flow withdraw data in Pipe for accounting purposes
            IPipe(receiverData.pipeRecipient).setUserFlowWithdrawData(data.context.msgSender, oldUserToPipeFlowRate);

            int96 newValveToPipeFlowRate =
                previousValveToPipeFlowRate.add(userToPipeFlowRateDifference, "Int96: Could not add.");

            IPipe(receiverData.pipeRecipient).setPipeFlowData(newValveToPipeFlowRate <= 0 ? 0 : newValveToPipeFlowRate);

            if (newValveToPipeFlowRate > 0) {
                (newCtx, ) = host.callAgreementWithContext(
                    cfa,
                    abi.encodeWithSelector(
                        selector,
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

        // after getting the new total valve flow rate, we set the new flow rate updated time
        valveFlowRateLastUpdated = block.timestamp;
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
        newCtx = _modifyMultiFlow( _agreementId, _cbdata, _ctx);
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
        newCtx = _modifyMultiFlow(_agreementId, _cbdata, _ctx);
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
        newCtx = _modifyMultiFlow( _agreementId, _cbdata, _ctx);
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
