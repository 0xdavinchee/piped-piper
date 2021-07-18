// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

interface IPipe {
    /**
     * @dev Withdraws funds from the vault and any existing flows to the caller.
     */
    function withdraw(int96 _flowRate, address _user) external returns (uint256);

    /**
     * @dev Get the balance that currently belongs to the pipe.
     */
    function pipeFlowBalance() external view returns (int256);

    /**
     * @dev Get the total withdrawable balance of _withdrawer: the flowed in amount +
     * their deposit/rewards in the vault.
     */
    function totalWithdrawableBalance(address _withdrawer, int96 _flowRate) external view returns (int256);

    /**
     * @dev Updates the timestamp of the total amount the valve has flowed into this pipe,
     * when the valve flow was last updated.
     */
    function setPipeFlowData(int96 _newFlowRate) external;

    /**
     * @dev Updates the flowUpdatedTimestamp and flowAmountSinceUpdate properties
     * of the userWithdrawData mapping.
     */
    function setUserFlowWithdrawData(address _depositor, int96 _previousFlowRate) external;
}
