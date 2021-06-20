// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

interface IPipe {
    /**
     * @dev Withdraws funds from the vault and any existing stream to the caller.
     */
    function withdraw() external;

    /**
     * @dev Get the balance that currently belongs to the pipe.
     */
    function pipeFlowBalance() external view returns (uint256);

    /**
     * @dev Sets the flowUpdatedTimestamp property of the userWithdrawnAmounts mapping.
     */
    function setFlowUpdateTimestamp(address _depositor) external;

    /**
     * @dev Updates the flowUpdatedTimestamp and flowAmountSinceUpdate properties
     * of the userWithdrawnAmounts mapping.
     */
    function setFlowWithdrawData(address _depositor, int96 _previousFlowRate) external;
}
