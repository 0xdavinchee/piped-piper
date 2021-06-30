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
        uint256 vaultWithdrawnAmount;
        uint256 flowUpdatedTimestamp;
        int256 flowAmountSinceUpdate;
        int256 totalFlowedToPipe;
    }
    struct InflowToPipeData {
        uint256 lastInflowToPipeFlowUpdate;
        int256 totalInflowToPipeFlow;
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

    event DepositFundsToVault(uint256 amount, uint256 timestamp);
    event WithdrawFromSuperApp(address indexed withdrawer, uint256 amount);

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
    function isDepositAfterUpdate(address _depositor) internal view returns (bool) {
        return lastVaultDepositTimestamp > userFlowData[_depositor].flowUpdatedTimestamp;
    }

    /**
     * @dev Returns the most recent of: the last time the user updated their flow rate,
     * when a batch vault deposit occurred, or the user withdrew.
     */
    function getLastUpdatedTime(address _depositor) internal view returns (uint256) {
        return
            isDepositAfterUpdate(_depositor)
                ? lastVaultDepositTimestamp
                : userFlowData[_depositor].flowUpdatedTimestamp;
    }

    /**
     * @dev Gets the amount flowed into Pipe available for withdrawal. Depending on whether the deposit or the time
     * since last flow is more recent, we either add the previous flowAmount or just get the flowAmount
     * since the deposit.
     */
    function _withdrawableFlowAmount(address _depositor, int96 _previousFlowRate) internal view returns (int256) {
        int256 addAmount = isDepositAfterUpdate(_depositor) ? 0 : userFlowData[_depositor].flowAmountSinceUpdate;
        block.timestamp.toInt256().sub(getLastUpdatedTime(_depositor).toInt256()).mul(_previousFlowRate).add(addAmount);
    }

    /**
     * @dev Updates the timestamp of the total amount the user has flowed into the Pipe,
     * when the user flow amount last updated as well as the amount of flow since the user
     * last updated their flow agreement.
     */
    function setUserFlowWithdrawData(address _depositor, int96 _previousFlowRate) external {
        userFlowData[_depositor].totalFlowedToPipe = userFlowData[_depositor].totalFlowedToPipe.add(
            block.timestamp.toInt256().sub(userFlowData[_depositor].flowUpdatedTimestamp.toInt256()).mul(
                _previousFlowRate
            )
        );
        userFlowData[_depositor].flowUpdatedTimestamp = block.timestamp;
        userFlowData[_depositor].flowAmountSinceUpdate = _withdrawableFlowAmount(_depositor, _previousFlowRate);
    }

    /**
     * @dev Updates the timestamp of the total amount that has flowed into the Pipe and
     * when the flow agreement was last updated.
     */
    function setPipeFlowData(int96 _newFlowRate) external {
        inflowToPipeData.totalInflowToPipeFlow = inflowToPipeData.totalInflowToPipeFlow.add(
            block.timestamp.toInt256().sub(inflowToPipeData.lastInflowToPipeFlowUpdate.toInt256()).mul(
                inflowToPipeData.inflowToPipeFlowRate
            )
        );
        inflowToPipeData.inflowToPipeFlowRate = _newFlowRate;
        inflowToPipeData.lastInflowToPipeFlowUpdate = block.timestamp;
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
        ISuperToken superToken = ISuperToken(acceptedToken);
        // this should get the current available balance/flowed in amount from users
        (int256 pipeAvailableBalance, , , ) = superToken.realtimeBalanceOfNow(address(this));
        require(pipeAvailableBalance > 0, "There is nothing to deposit into the vault");

        lastVaultDepositTimestamp = block.timestamp;

        uint256 amount = pipeAvailableBalance.toUint256();
        superToken.downgrade(amount);

        // deposit into the vault
        _depositToVault(amount);

        emit DepositFundsToVault(amount, block.timestamp);
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdraw(int96 _flowRate) external {
        _withdraw(_flowRate);
    }

    /**
     * @dev Withdraws any deposited tokens from a vault as well as the flow amount and updates the state accordingly.
     */
    function _withdraw(int96 _flowRate) internal {
        uint256 totalVaultBalance = _vaultBalanceOf(address(this));
        uint256 availableVaultWithdrawAmount = _vaultRewardBalanceOf(msg.sender, totalVaultBalance);
        int256 availableFlowWithdraw = _withdrawableFlowAmount(msg.sender, _flowRate);

        // withdrawable vault amount (incl. rewards) + user's _withdrawableFlowAmount
        uint256 withdrawableAmount = availableFlowWithdraw.toUint256();
        require(withdrawableAmount > 0 || availableVaultWithdrawAmount > 0, "There is nothing to withdraw.");

        // update the user's vault withdrawn amounts
        userFlowData[msg.sender].vaultWithdrawnAmount = userFlowData[msg.sender].vaultWithdrawnAmount.add(
            availableVaultWithdrawAmount
        );

        // since the user is withdrawing, we reset the flowAmount and the flow available for withdrawal
        userFlowData[msg.sender].flowAmountSinceUpdate = 0;
        userFlowData[msg.sender].flowUpdatedTimestamp = block.timestamp;

        if (availableVaultWithdrawAmount > 0) {
            // withdraw from the vault directly to user
            _withdrawFromVault(availableVaultWithdrawAmount);
        }

        // Transfer balance
        bool success = ISuperToken(acceptedToken).transfer(msg.sender, withdrawableAmount);
        require(success, "Unable to transfer tokens.");

        emit WithdrawFromSuperApp(msg.sender, withdrawableAmount);
    }

    /**************************************************************************
     * Getter Functions
     *************************************************************************/

    /** @dev Returns the amount of flowed tokens that are withdrawable by the _depositor.
     */
    function withdrawableFlowBalance(address _depositor, int96 _flowRate) external view returns (int256) {
        return _withdrawableFlowAmount(_depositor, _flowRate);
    }

    /** @dev Returns the total withdrawable balance, composed of the tokens deposited in the vault + rewards
     * as well as the amount of tokens that haven't been deposited but have been flowed into the Pipe.
     */
    function totalWithdrawableBalance(address _withdrawer, int96 _flowRate) external view returns (int256) {
        uint256 totalVaultBalance = _vaultBalanceOf(address(this));
        int256 availableFlowWithdraw = _withdrawableFlowAmount(_withdrawer, _flowRate);
        return availableFlowWithdraw.add(_vaultRewardBalanceOf(_withdrawer, totalVaultBalance).toInt256());
    }

    /**
     * @dev Returns _depositor deposit in a vault and any rewards accrued,
     * calculated based on their share of the Pipe deposits.
     */
    function _vaultRewardBalanceOf(address _withdrawer, uint256 _vaultBalance) internal view returns (uint256) {
        int256 userTotalFlowedToPipe = userFlowData[_withdrawer].totalFlowedToPipe;
        uint256 totalVaultWithdrawableAmount = userTotalFlowedToPipe
        .div(inflowToPipeData.totalInflowToPipeFlow)
        .toUint256()
        .mul(_vaultBalance);

        return
            totalVaultWithdrawableAmount > userFlowData[_withdrawer].vaultWithdrawnAmount
                ? totalVaultWithdrawableAmount.sub(userFlowData[_withdrawer].vaultWithdrawnAmount)
                : 0;
    }
}
