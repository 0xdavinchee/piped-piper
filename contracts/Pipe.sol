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

contract Pipe is Vault {
    struct WithdrawnAmounts {
        uint256 vaultWithdrawnAmount;
        uint256 flowUpdatedTimestamp;
        int256 flowAmountSinceUpdate;
    }
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Int96SafeMath for int96;

    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;

    mapping(address => WithdrawnAmounts) private userWithdrawnAmounts;
    address private allowedVaultDepositorAddress;
    uint256 private lastVaultDepositTimestamp;

    event DepositFundsToVault(uint256 amount, uint256 timestamp);
    event WithdrawFromSuperApp(address indexed withdrawer, uint256 amount);
    event StopFlow();

    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken,
        address _vault
    ) Vault(_vault) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        require(address(_acceptedToken) != address(0), "Token is zero address.");
        host = _host;
        cfa = _cfa;
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
        return lastVaultDepositTimestamp > userWithdrawnAmounts[_depositor].flowUpdatedTimestamp;
    }

    /**
     * @dev Returns the most recent of: the last time the user updated their flow rate,
     * when a batch vault deposit occurred, or the user withdrew.
     */
    function getLastUpdatedTime(address _depositor) internal view returns (uint256) {
        return
            isDepositAfterUpdate(_depositor)
                ? lastVaultDepositTimestamp
                : userWithdrawnAmounts[_depositor].flowUpdatedTimestamp;
    }

    /**
     * @dev Gets the amount flowed into Pipe available for withdrawal. Depending on whether the deposit or the time
     * since last flow is more recent, we either add the previous flowAmount or just get the flowAmount
     * since the deposit.
     */
    function withdrawableFlowAmount(address _depositor, int96 _previousFlowRate) internal view returns (int256) {
        int256 addAmount =
            isDepositAfterUpdate(_depositor) ? 0 : userWithdrawnAmounts[_depositor].flowAmountSinceUpdate;
        block.timestamp.toInt256().sub(getLastUpdatedTime(_depositor).toInt256()).mul(_previousFlowRate).add(addAmount);
    }

    /**
     * @dev Sets the flowUpdatedTimestamp property of the userWithdrawnAmounts mapping.
     */
    function setFlowUpdateTimestamp(address _depositor) external {
        userWithdrawnAmounts[_depositor].flowUpdatedTimestamp = block.timestamp;
    }

    /**
     * @dev Updates the timestamp of when the user flow was last updated as well as the
     * amount of flow since the user last updated their flow rate.
     */
    function setFlowWithdrawData(address _depositor, int96 _previousFlowRate) external {
        userWithdrawnAmounts[_depositor].flowUpdatedTimestamp = block.timestamp;
        userWithdrawnAmounts[_depositor].flowAmountSinceUpdate = withdrawableFlowAmount(_depositor, _previousFlowRate);
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
        // this should get the available balance/flowed in amount from users
        (int256 pipeAvailableBalance, , , ) = superToken.realtimeBalanceOfNow(address(this));
        require(pipeAvailableBalance > 0, "There is nothing to deposit into the vault");

        lastVaultDepositTimestamp = block.timestamp;

        uint256 amount = pipeAvailableBalance.toUint256();
        superToken.downgrade(amount);

        address underlyingToken = superToken.getUnderlyingToken();
        ISuperToken(underlyingToken).increaseAllowance(vault, amount);

        // deposit into the vault
        _depositToVault(amount);

        emit DepositFundsToVault(amount, block.timestamp);
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdraw() external {
        _withdraw();
    }

    /**
     * @dev When the stops their flow and withdraws, this handles the logic of removing them as a depositor
     * and updating the state accordingly.
     */
    function _withdrawAndStopFlowing() private {
        _withdraw();
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.deleteFlow.selector, msg.sender, address(this), new bytes(0)),
            "0x"
        );
        emit StopFlow();
    }

    /**
     * @dev Withdraws the tokens from a vault as well as the flow amount and updates the state accordingly.
     */
    function _withdraw() internal {
        // gets the address of the vault
        uint256 totalVaultBalance = _vaultBalanceOf(address(this));

        uint256 withdrawerVaultAmount = vaultRewardBalanceOf(msg.sender, totalVaultBalance);

        // withdraw from the vault
        _withdrawFromVault(withdrawerVaultAmount);

        (, int96 flowRate, , ) = cfa.getFlow(acceptedToken, msg.sender, address(this));
        int256 availableFlowWithdraw = withdrawableFlowAmount(msg.sender, flowRate);

        // withdrawable vault amount (incl. rewards) + user's withdrawableFlowAmount
        uint256 withdrawableAmount = withdrawerVaultAmount.add(availableFlowWithdraw.toUint256());
        require(withdrawableAmount > 0, "There is nothing to withdraw.");

        // update the user's vault withdrawn amounts
        userWithdrawnAmounts[msg.sender].vaultWithdrawnAmount = userWithdrawnAmounts[msg.sender]
            .vaultWithdrawnAmount
            .add(withdrawerVaultAmount);

        // since the user is withdrawing, we reset the flowAmount and the flow available for withdrawal
        userWithdrawnAmounts[msg.sender].flowAmountSinceUpdate = 0;
        userWithdrawnAmounts[msg.sender].flowUpdatedTimestamp = block.timestamp;

        // Transfer balance
        bool success = ISuperToken(acceptedToken).transfer(msg.sender, withdrawableAmount);
        require(success, "Unable to transfer tokens.");

        emit WithdrawFromSuperApp(msg.sender, withdrawableAmount);
    }

    /**
     * @dev Returns the amount of acceptedToken flowed into the pipe. This will be used to determine
     * whether it is appropriate to deposit funds into the vault.
     */
    function pipeFlowBalance() external view returns (int256) {
        (int256 availableBalance, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(address(this));
        return availableBalance;
    }

    /**
     * @dev Returns _depositor deposit in a vault and any rewards accrued,
     * calculated based on their share of the Pipe deposits.
     */
    function vaultRewardBalanceOf(address _withdrawer, uint256 _vaultBalance) internal view returns (uint256) {
        // this will be 0 or a negative number
        (int256 withdrawerTotalFlowedToContract, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(_withdrawer);
        // this will be a negative number
        (int256 totalFlowedToContract, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(address(this));
        uint256 totalVaultWithdrawableAmount =
            withdrawerTotalFlowedToContract.div(totalFlowedToContract).toUint256().mul(_vaultBalance);

        return totalVaultWithdrawableAmount.sub(userWithdrawnAmounts[_withdrawer].vaultWithdrawnAmount);
    }
}
