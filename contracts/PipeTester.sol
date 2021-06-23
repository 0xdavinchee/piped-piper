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
/// @title This contract is used for testing/interacting with the Pipe contract. A lot of the logic is
/// similar to the logic in SuperValve and almost behaves like SuperValve, but is simplified as there
/// is no need to keep track of different users' allocations or different allocations to multiple
/// addresses.

contract PipeTester {
    ISuperfluid private host;
    IConstantFlowAgreementV1 public cfa; // private

    constructor(ISuperfluid _host, IConstantFlowAgreementV1 _cfa) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        host = _host;
        cfa = _cfa;
    }

    event ModifyFlowAgreement(
        address pipeAddress,
        int96 oldFlowRate,
        int96 newFlowRate,
        address sender,
        address agreementClass
    );
    event Withdraw(address pipeAddress, int96 flowRate);

    /** @dev Withdraws your funds from a single vault/pipe.
     */
    function withdrawFromVault(address _pipeAddress, ISuperToken _token) public {
        IPipe pipe = IPipe(_pipeAddress);
        (, int96 flowRate, , ) = cfa.getFlow(_token, address(this), _pipeAddress);

        if (pipe.totalWithdrawableBalance(msg.sender, flowRate) > 0) {
            // update the valveToPipeData in IPipe (same flow rate, but need to calculate total flow
            // before withdrawal)
            pipe.setPipeFlowData(flowRate);
            pipe.withdraw(flowRate);
            emit Withdraw(_pipeAddress, flowRate);
        }
    }

    /** @dev Creates a flow from User to Pipe.
     * A pipe should only take flows from one parent contract.
     */
    function _createUserToPipeFlow(
        address _pipeAddress,
        int96 _newUserToPipeFlowRate,
        ISuperToken _token,
        address _agreementClass
    ) external {
        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(_pipeAddress).setUserFlowWithdrawData(msg.sender, 0);
        // update the valveToPipeData in IPipe
        IPipe(_pipeAddress).setPipeFlowData(_newUserToPipeFlowRate);

        // create the flow agreement between the SuperValve and Pipe
        host.callAgreement(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.createFlow.selector, _token, _pipeAddress, _newUserToPipeFlowRate, new bytes(0)),
            "0x"
        );
        emit ModifyFlowAgreement(_pipeAddress, 0, _newUserToPipeFlowRate, msg.sender, _agreementClass);
    }

    /** @dev Updates the valveToPipe flowRate when a user updates their flow rate.
     * We will update the state to reflect the new flow rate from the SuperValve to the Pipe as well
     * as the users' updated allocation data.
     */
    function _updateUserToPipeFlow(
        address _pipeAddress,
        int96 _newUserToPipeFlowRate,
        ISuperToken _token,
        address _agreementClass
    ) external {
        address pipeAddress = _pipeAddress;

        // get the old userToPipe flow rate
        (, int96 oldUserToPipeFlowRate, , ) = cfa.getFlow(_token, msg.sender, _pipeAddress);

        // update the user flow withdraw data in Pipe for accounting purposes
        IPipe(pipeAddress).setUserFlowWithdrawData(msg.sender, oldUserToPipeFlowRate);

        // update the valveToPipeData in IPipe
        IPipe(_pipeAddress).setPipeFlowData(_newUserToPipeFlowRate);

        // update the flow agreement between SuperValve and Pipe
        host.callAgreement(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.updateFlow.selector, _token, pipeAddress, _newUserToPipeFlowRate, new bytes(0)),
            "0x"
        );
        emit ModifyFlowAgreement(
            _pipeAddress,
            oldUserToPipeFlowRate,
            _newUserToPipeFlowRate,
            msg.sender,
            _agreementClass
        );
    }

    /** @dev Updates the valveToPipe flowRate when a user chooses to remove their flow rate.
     * We update the local state to reflect the new flow rate from the SuperValve to the pipe as well as removing
     * the users' allocations.
     */
    function _stopFlowToPipe(
        address _pipeAddress,
        int96 _newUserToPipeFlowRate, // this will always be 0
        ISuperToken _token,
        address _agreementClass
    ) internal {
        // get the old userToPipe flow rate
        (, int96 oldUserToPipeFlowRate, , ) = cfa.getFlow(_token, msg.sender, _pipeAddress);

        // update the user flow withdraw data in pipe for accounting purposes
        IPipe(_pipeAddress).setUserFlowWithdrawData(msg.sender, oldUserToPipeFlowRate);

        // update the valveToPipeData in IPipe
        IPipe(_pipeAddress).setPipeFlowData(_newUserToPipeFlowRate);

        // update the flow agreement between SuperValve and Pipe
        host.callAgreement(
            ISuperAgreement(_agreementClass),
            abi.encodeWithSelector(cfa.updateFlow.selector, _token, _pipeAddress, _newUserToPipeFlowRate, new bytes(0)),
            "0x"
        );
        emit ModifyFlowAgreement(
            _pipeAddress,
            oldUserToPipeFlowRate,
            _newUserToPipeFlowRate,
            msg.sender,
            _agreementClass
        );
    }
}
