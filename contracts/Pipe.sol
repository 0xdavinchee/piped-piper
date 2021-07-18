// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";

import { Int96SafeMath } from "@superfluid-finance/ethereum-contracts/contracts/utils/Int96SafeMath.sol";
import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import {
    ISuperfluid,
    ISuperToken
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Vault } from "./Vault.sol";

/// @author Piped-Piper ETHGlobal Hack Money Team
/// @title Pipe takes a single flow and periodically sends these funds into an existing yield generating farm or
/// any other type of contract. You can use this contract by inheriting it and overriding the functions in the
/// abstract contract to implement the deposit, withdraw and balanceOf functions of the respective vaults.
/// Input: A flow of SuperTokens from a single address.
/// Output: The underlying token to a single address.
/// Caveat: Certain variables are set to public for testing purposes.
contract Pipe is Vault {
    struct UserFlowData {
        uint256 flowUpdatedTimestamp;
        int256 flowAmountSinceUpdate;
        int256 flowBalance;
    }
    struct InflowToPipeData {
        uint256 lastInflowToPipeFlowUpdate;
        int256 pipeFlowBalance;
        int96 inflowToPipeFlowRate;
    }

    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Int96SafeMath for int96;

    ISuperToken public acceptedToken; // private

    mapping(address => UserFlowData) public userFlowData; // private
    address public allowedVaultDepositorAddress; // private
    uint256 public lastVaultDepositTimestamp; // private
    InflowToPipeData public inflowToPipeData; // private

    event DepositableFunds(int256 amount);
    event DepositFundsToVault(uint256 amount, uint256 timestamp);
    event WithdrawFromVault(address withdrawer, uint256 amount);
    event WithdrawPipeFlow(address indexed withdrawer, uint256 amount);
    event UserToPipeFlowDataUpdated(
        address user,
        int96 previousFlowRate,
        int256 flowBalance,
        uint256 flowUpdatedTimestamp,
        int256 flowAmountSinceUpdate
    );
    event ValveToPipeFlowDataUpdated(int96 newFlowRate, int256 pipeFlowBalance, uint256 lastInflowToPipeFlow);

    constructor(ISuperToken _acceptedToken) Vault() {
        require(address(_acceptedToken) != address(0), "Token is zero address.");
        acceptedToken = _acceptedToken;
        allowedVaultDepositorAddress = msg.sender;
    }

    /**************************************************************************
     * Withdrawn Amounts Logic
     *************************************************************************/

    /**
     * @dev Returns whether a batch deposit is more recent than a flow create/update.
     */
    function isDepositAfterUpdate(address _user) internal view returns (bool) {
        return lastVaultDepositTimestamp > userFlowData[_user].flowUpdatedTimestamp;
    }

    /**
     * @dev Returns the most recent of: the last time the user updated their flow rate,
     * when a batch vault deposit occurred, or the user withdrew.
     */
    function getLastUpdatedTime(address _user) internal view returns (uint256) {
        return isDepositAfterUpdate(_user) ? lastVaultDepositTimestamp : userFlowData[_user].flowUpdatedTimestamp;
    }

    /**
     * @dev Gets the amount flowed into Pipe available for withdrawal. Depending on whether the deposit or the time
     * since last flow is more recent, we either add the previous flowAmount or just get the flowAmount
     * since the deposit.
     */
    function _withdrawableFlowAmount(address _user, int96 _flowRate) internal view returns (int256) {
        int256 addAmount = isDepositAfterUpdate(_user) ? 0 : userFlowData[_user].flowAmountSinceUpdate;
        return block.timestamp.toInt256().sub(getLastUpdatedTime(_user).toInt256()).mul(_flowRate).add(addAmount);
    }

    function _getCurrentFlowBalance(address _user, int96 _previousFlowRate) internal view returns (int256) {
        return
            userFlowData[_user].flowBalance.add(
                block.timestamp.toInt256().sub(userFlowData[_user].flowUpdatedTimestamp.toInt256()).mul(
                    _previousFlowRate
                )
            );
    }

    /**
     * @dev Updates the timestamp of the total amount the user has flowed into the Pipe,
     * when the user flow amount last updated as well as the amount of flow since the user
     * last updated their flow agreement.
     */
    function setUserFlowWithdrawData(address _user, int96 _previousFlowRate) external {
        int256 flowBalance = _getCurrentFlowBalance(_user, _previousFlowRate);
        userFlowData[_user].flowAmountSinceUpdate = _withdrawableFlowAmount(_user, _previousFlowRate);
        userFlowData[_user].flowBalance = flowBalance;
        userFlowData[_user].flowUpdatedTimestamp = block.timestamp;

        emit UserToPipeFlowDataUpdated(
            _user,
            _previousFlowRate,
            flowBalance,
            block.timestamp,
            _withdrawableFlowAmount(_user, _previousFlowRate)
        );
    }

    /**
     * @dev Updates the timestamp of the total amount that has flowed into the Pipe and
     * when the flow agreement was last updated.
     */
    function setPipeFlowData(int96 _newFlowRate) external {
        int256 pipeFlowBalance =
            inflowToPipeData.pipeFlowBalance.add(
                block.timestamp.toInt256().sub(inflowToPipeData.lastInflowToPipeFlowUpdate.toInt256()).mul(
                    inflowToPipeData.inflowToPipeFlowRate
                )
            );
        inflowToPipeData.pipeFlowBalance = pipeFlowBalance;
        inflowToPipeData.inflowToPipeFlowRate = _newFlowRate;
        inflowToPipeData.lastInflowToPipeFlowUpdate = block.timestamp;

        emit ValveToPipeFlowDataUpdated(_newFlowRate, pipeFlowBalance, block.timestamp);
    }

    /**************************************************************************
     * Deposit/Withdraw Logic
     *************************************************************************/

    /**
     * @dev Gets the total amount flowed into the Pipe based on the current block.timestamp
     * downgrades all the supertokens and deposits them into a vault.
     */
    function depositFundsIntoVault() public {
        require(msg.sender == allowedVaultDepositorAddress, "You don't have permission to deposit into the vault.");
        // this should get the current available balance/flowed in amount from users
        (int256 pipeAvailableBalance, , , ) = acceptedToken.realtimeBalanceOfNow(address(this));
        emit DepositableFunds(pipeAvailableBalance);
        require(pipeAvailableBalance > 0, "There is nothing to deposit into the vault");

        lastVaultDepositTimestamp = block.timestamp;

        uint256 amount = pipeAvailableBalance.toUint256();
        acceptedToken.downgrade(amount);

        address underlying = acceptedToken.getUnderlyingToken();

        // deposit into the vault
        _depositToVault(underlying, amount, address(this));

        emit DepositFundsToVault(amount, block.timestamp);
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdraw(int96 _flowRate, address _user) external returns (uint256) {
        return _withdraw(_flowRate, _user);
    }

    /**
     * @dev Withdraws any deposited tokens from a vault as well as the flow amount and updates the state accordingly.
     */
    function _withdraw(int96 _flowRate, address _user) internal returns (uint256) {
        uint256 availableVaultWithdrawAmount = _vaultRewardBalanceOf(_user, _flowRate);
        int256 availableFlowWithdraw = _withdrawableFlowAmount(_user, _flowRate);

        // withdrawable vault amount (incl. rewards) + user's _withdrawableFlowAmount
        uint256 withdrawableFlowAmount = availableFlowWithdraw.toUint256();
        require(withdrawableFlowAmount > 0 || availableVaultWithdrawAmount > 0, "There is nothing to withdraw.");

        // subtract whatever the user is withdrawing from the valve balance
        inflowToPipeData.pipeFlowBalance.sub(availableFlowWithdraw.add(availableVaultWithdrawAmount.toInt256()));

        // since the user is withdrawing, we reset the flowAmount since update as well as the user's flowBalance
        userFlowData[_user].flowAmountSinceUpdate = 0;
        userFlowData[_user].flowBalance = 0;
        userFlowData[_user].flowUpdatedTimestamp = block.timestamp;

        if (availableVaultWithdrawAmount > 0) {
            // withdraw from the vault directly to user
            _withdrawFromVault(availableVaultWithdrawAmount, _user);
            emit WithdrawFromVault(_user, availableVaultWithdrawAmount);
        }

        // Transfer balance
        bool success = ISuperToken(acceptedToken).transfer(_user, withdrawableFlowAmount);
        require(success, "Unable to transfer tokens.");

        emit WithdrawPipeFlow(_user, withdrawableFlowAmount);
        return withdrawableFlowAmount.add(availableVaultWithdrawAmount);
    }

    /**************************************************************************
     * Getter Functions
     *************************************************************************/

    /** @dev Returns the amount of flowed tokens that are withdrawable by the _depositor.
     */
    function withdrawableFlowBalance(address _user, int96 _flowRate) external view returns (int256) {
        return _withdrawableFlowAmount(_user, _flowRate);
    }

    /** @dev Returns the total withdrawable balance, composed of the tokens deposited in the vault + rewards
     * as well as the amount of tokens that haven't been deposited but have been flowed into the Pipe.
     */
    function totalWithdrawableBalance(address _withdrawer, int96 _flowRate) external view returns (int256) {
        int256 availableFlowWithdraw = _withdrawableFlowAmount(_withdrawer, _flowRate);
        int256 vaultReward = _vaultRewardBalanceOf(_withdrawer, _flowRate).toInt256();
        return availableFlowWithdraw.add(vaultReward);
    }

    /**
     * @dev Returns _depositor deposit. Note: this only allows the user to withdraw what they deposited in,
     * it does not work in the case where the vault accrues interest.
     */
    function _vaultRewardBalanceOf(address _withdrawer, int96 _flowRate) internal view returns (uint256) {
        int256 currentFlowBalance = _getCurrentFlowBalance(_withdrawer, _flowRate);
        uint256 totalVaultWithdrawableAmount =
            currentFlowBalance < _withdrawableFlowAmount(_withdrawer, _flowRate)
                ? 0
                : currentFlowBalance.sub(_withdrawableFlowAmount(_withdrawer, _flowRate)).toUint256();
        return totalVaultWithdrawableAmount;
    }
}
