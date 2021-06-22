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

// TODO: There is a limit to how many pipes can be connected to this SuperRouter.

contract SuperRouter is SuperAppBase {
    int96 private constant ONE_HUNDRED_PERCENT = 1000;

    using SignedSafeMath for int256;
    using Int96SafeMath for int96;

    struct PipeFlowData {
        int96 percentage; // percentage will be between 0 and 1000 (allows one decimal place of contrast)
        address pipeAddress;
    }
    struct UserAllocation {
        int96 totalFlowRate;
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
    mapping(address => int96) private superRouterToPipeFlowRates;
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
            withdrawFromVault(_pipeAddresses[i]);
        }
    }

    /** @dev Withdraws your funds from a single vault/pipe. */
    function withdrawFromVault(address _pipeAddress) public {
        IPipe pipe = IPipe(_pipeAddress);
        if (pipe.totalWithdrawableBalance(msg.sender) > 0) {
            pipe.withdraw();
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
     * @dev Users will call this to set up the initial agreement between themselves and the SuperRouter.
     */
    function setupFlows(
        PipeFlowData[] memory _pipeFlowData,
        int96 _flowRate,
        ISuperToken _inputToken
    ) public isFullyAllocated(_pipeFlowData) {
        int96 totalPercentage;
        for (uint256 i; i < _pipeFlowData.length; i++) {
            totalPercentage = totalPercentage + _pipeFlowData[i].percentage;
        }
        require(totalPercentage == ONE_HUNDRED_PERCENT, "Your flows don't add up to 100%.");
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.createFlow.selector, _inputToken, address(this), _flowRate, new bytes(0)),
            abi.encode(_pipeFlowData)
        );
    }

    /**
     * @dev User will call this to update the agreement between themselves and the SuperRouter.
     */
    function modifyFlows(
        PipeFlowData[] memory _pipeFlowData,
        int96 _flowRate,
        ISuperToken _inputToken
    ) public isFullyAllocated(_pipeFlowData) {
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.updateFlow.selector, _inputToken, address(this), _flowRate, new bytes(0)),
            abi.encode(_pipeFlowData)
        );
    }

    /**
     * @dev User will call this to stop their agreement between themselves and the SuperRouter.
     */
    function stopFlows() public {
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.deleteFlow.selector, acceptedToken, msg.sender, address(this)),
            "0x"
        );
    }

    /** @dev Creates the initial flow to a pipe.
     * This will only occur once for each pipe, as there can only be one flow between two accounts.
     * We will update the state to track the users totalFlowRate AND % allocation of the user to the pipe.
     */
    function _createFlowToPipe(
        address _pipeAddress,
        int96 _percentage,
        int96 _totalUserToRouterFlowRate,
        address _sender,
        address _agreementClass,
        bytes calldata _ctx
    ) internal validPipeAddress(_pipeAddress) returns (bytes memory newCtx) {
        require(
            _percentage > 0 && _percentage <= ONE_HUNDRED_PERCENT,
            "Your percentage is outside of the acceptable range."
        );

        // calculate the flowRate allocated to this _pipeAddress
        int96 pipeFlowRate = mulDiv(_percentage, _totalUserToRouterFlowRate, ONE_HUNDRED_PERCENT);
        IPipe(_pipeAddress).setFlowWithdrawData(_sender, 0);

        // set the flow rate and % allocation of an individual user
        userAllocations[_sender].allocations[_pipeAddress] = Allocation(pipeFlowRate, _percentage);

        // increment the total flow rate of the SuperRouter to the particular pipe address
        superRouterToPipeFlowRates[_pipeAddress] =
            superRouterToPipeFlowRates[_pipeAddress] +
            _totalUserToRouterFlowRate;

        // create the flow agreement between user and SuperRouter
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.createFlow.selector, _pipeAddress, pipeFlowRate, _ctx),
            "0x",
            _ctx
        );
    }

    /** @dev Updates the routerToPipe flowRate when a user updates their flow rate.
     * We will update the local state in here to reflect the new flow rate from the SuperRouter to the pipe as well
     * as the users' updated allocation.
     */
    function _updateFlowToPipe(
        address _pipeAddress,
        int96 _percentage,
        address _sender,
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) internal validPipeAddress(_pipeAddress) returns (bytes memory newCtx) {
        require(
            _percentage >= 0 && _percentage <= ONE_HUNDRED_PERCENT,
            "Your percentage is outside of the acceptable range."
        );

        // get the previous userToPipe flow rate
        int96 oldUserToPipeFlowRate = userAllocations[_sender].allocations[_pipeAddress].flowRate;

        // update the flow withdraw data in pipe for accounting purposes
        IPipe(_pipeAddress).setFlowWithdrawData(_sender, oldUserToPipeFlowRate);

        // get the new userToRouter flow rate
        (, int96 newUserToRouterFlowRate, , ) = cfa.getFlowByID(_token, _agreementId);

        // get and set the new userToPipe flow rate using the new percentage and newly set flow rate
        int96 newUserToPipeFlowRate = mulDiv(_percentage, newUserToRouterFlowRate, ONE_HUNDRED_PERCENT);
        userAllocations[_sender].allocations[_pipeAddress] = Allocation(newUserToPipeFlowRate, _percentage);

        // set the new userToRouter flow rate
        userAllocations[_sender].totalFlowRate = newUserToRouterFlowRate;

        // get the new total flow rate from routerToPipe given the users' updated flow rate
        int96 newRouterToPipeFlowRate =
            superRouterToPipeFlowRates[_pipeAddress].sub(oldUserToPipeFlowRate, "Int96 Error: Could not subtract.").add(
                newUserToPipeFlowRate,
                "Int96 Error: Could not add."
            );

        // update the new router to pipe flow rate
        superRouterToPipeFlowRates[_pipeAddress] = newRouterToPipeFlowRate;

        // update the flow agreement between SuperRouter and pipe
        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.updateFlow.selector, _token, _pipeAddress, newRouterToPipeFlowRate, _ctx),
            "0x",
            _ctx
        );
    }

    /** @dev Updates the routerToPipe flowRate when a user chooses to remove their flow rate.
     * We update the local state to reflect the new flow rate from the SuperRouter to the pipe as well as removing
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

        // update the flow withdraw data in pipe for accounting purposes
        IPipe(_pipeAddress).setFlowWithdrawData(_sender, oldUserToPipeFlowRate);

        // get the new total flow rate from routerToPipe given the users flow rate is 0 now
        int96 newRouterToPipeFlowRate =
            superRouterToPipeFlowRates[_pipeAddress].sub(oldUserToPipeFlowRate, "Int96 Error: Could not subtract.");

        userAllocations[_sender].allocations[_pipeAddress] = Allocation(0, 0);
        userAllocations[_sender].totalFlowRate = 0;

        (newCtx, ) = host.callAgreementWithContext(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(
                cfa.updateFlow.selector,
                _token,
                _pipeAddress,
                newRouterToPipeFlowRate,
                _pipeAddress
            ),
            "0x",
            _ctx
        );
    }

    /** @dev This is called in our callback function and either creates (only once) or
     * updates the flow between the SuperRouter and a Pipe.
     */
    function _modifyFlowToPipes(
        ISuperToken _token,
        address _agreementClass,
        bytes32 _agreementId,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        bytes memory rawUserData = host.decodeCtx(newCtx).userData;
        address sender = host.decodeCtx(newCtx).msgSender;
        PipeFlowData[] memory pipeFlowData = abi.decode(rawUserData, (PipeFlowData[]));

        // get the old flow rate between user and SuperRouter
        int96 oldTotalUserToSuperRouterFlowRate = userAllocations[sender].totalFlowRate;

        // get the newly created/updated flow rate between the user and SuperRouter
        (, int96 newUserToSuperRouterFlowRate, , ) = cfa.getFlowByID(_token, _agreementId);

        // update the user total flow rate to the newly created/updated one
        userAllocations[sender].totalFlowRate = newUserToSuperRouterFlowRate;

        for (uint256 i; i < pipeFlowData.length; i++) {
            // check if an agreement exists between the SuperRouter and Pipe
            (uint256 timestamp, , , ) = cfa.getFlow(_token, address(this), pipeFlowData[i].pipeAddress);
            bool _agreementExists = timestamp > 0;

            if (
                // if the user doesn't want to create or update, we skip
                (pipeFlowData[i].percentage == 0 && !_agreementExists) ||
                // if the total flow rate is unchanged AND the percentage allocated to this pipe remains unchanged
                // we don't need to update anything
                (oldTotalUserToSuperRouterFlowRate == newUserToSuperRouterFlowRate &&
                    pipeFlowData[i].percentage ==
                    userAllocations[sender].allocations[pipeFlowData[i].pipeAddress].percentage)
            ) {
                continue;
            }
            if (!_agreementExists) {
                newCtx = _createFlowToPipe(
                    pipeFlowData[i].pipeAddress,
                    pipeFlowData[i].percentage,
                    newUserToSuperRouterFlowRate,
                    sender,
                    _agreementClass,
                    _ctx
                );
            } else {
                newCtx = _updateFlowToPipe(
                    pipeFlowData[i].pipeAddress,
                    pipeFlowData[i].percentage,
                    sender,
                    _token,
                    _agreementClass,
                    _agreementId,
                    _ctx
                );
            }
        }
    }

    /** @dev This is called in our callback function when a user terminates their agreement with the
     * SuperRouter.
     */
    function _stopFlowToPipes(
        ISuperToken _token,
        address _agreementClass,
        bytes calldata _ctx
    ) internal returns (bytes memory newCtx) {
        newCtx = _ctx;
        bytes memory rawUserData = host.decodeCtx(newCtx).userData;
        address sender = host.decodeCtx(newCtx).msgSender;
        PipeFlowData[] memory pipeFlowData = abi.decode(rawUserData, (PipeFlowData[]));
        for (uint256 i; i < pipeFlowData.length; i++) {
            bool hasFlowToCurrentPipe = userAllocations[sender].allocations[pipeFlowData[i].pipeAddress].flowRate > 0;

            // if the user has no flow to the pipe, we skip
            if (!hasFlowToCurrentPipe) {
                continue;
            }
            newCtx = _stopFlowToPipe(pipeFlowData[i].pipeAddress, sender, _token, _agreementClass, _ctx);
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
     * @dev After the user starts flowing funds into the SuperRouter, we redirect these flows through the
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
     * will udpate the total flowed from the SuperRouter to the Pipe.
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

    modifier isFullyAllocated(PipeFlowData[] memory _pipeFlowData) {
        int96 totalPercentage;
        for (uint256 i; i < _pipeFlowData.length; i++) {
            totalPercentage = totalPercentage + _pipeFlowData[i].percentage;
        }
        require(totalPercentage == ONE_HUNDRED_PERCENT, "Your flows don't add up to 100%.");
        _;
    }

    modifier validPipeAddress(address _pipeAddress) {
        require(validPipeAddresses[_pipeAddress] == true, "This is not a registered vault address.");
        _;
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
