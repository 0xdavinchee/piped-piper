// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";

import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import {
    ISuperfluid,
    ISuperToken
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import { Vault } from "./Vault.sol";

contract Pipe is Vault {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;

    mapping(address => uint256) private userWithdrawnAmounts;

    event DepositorAdded(address depositor);
    event DepositorRemoved(address depositor);

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
    }

    /**************************************************************************
     * Deposit/Withdraw Logic
     *************************************************************************/

    /**
     * @dev Gets the total amount flowed into the Pipe based on the current block.timestamp
     * downgrades all the supertokens and deposits them into a vault.
     */
    function depositFundsIntoVault() private {
        ISuperToken superToken = ISuperToken(acceptedToken);
        // this should get the available current streamed in amount from users
        (int256 pipeAvailableBalance, , , ) = superToken.realtimeBalanceOfNow(address(this));
        require(pipeAvailableBalance > 0, "There is nothing to deposit into the vault");

        uint256 amount = pipeAvailableBalance.toUint256();
        superToken.downgrade(amount);

        address underlyingToken = superToken.getUnderlyingToken();
        ISuperToken(underlyingToken).increaseAllowance(vault, amount);

        // deposit into the vault
        _depositToVault(amount);
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdrawFromSuperApp() public {
        // gets the address of the vault
        uint256 totalVaultBalance = _vaultBalanceOf(address(this));

        uint256 withdrawerVaultAmount = vaultRewardBalanceOf(msg.sender, totalVaultBalance);
        require(withdrawerVaultAmount > 0, "Nothing to withdraw.");

        // withdraw from the vault
        _withdrawFromVault(withdrawerVaultAmount);

        // this will be a negative number (the net flow of the depositor)
        (int256 withdrawerAvailableBalance, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(msg.sender);

        // withdrawable vault amount (incl. rewards) - (-currrent negative stream net flow)
        uint256 withdrawAmount = withdrawerVaultAmount.sub(withdrawerAvailableBalance.toUint256());
        require(withdrawAmount > 0, "There is nothing to withdraw.");

        // update the user's deposit amount
        userWithdrawnAmounts[msg.sender] = userWithdrawnAmounts[msg.sender].add(withdrawerVaultAmount);

        // Withdraw vault balance
        bool success = ISuperToken(acceptedToken).transfer(msg.sender, withdrawAmount);
        require(success, "Unable to transfer tokens.");
    }

    /**
     * @dev When the stops their stream and withdraws, this handles the logic of removing them as a depositor
     * and updating the state accordingly.
     */
    function _withdrawFromSuperAppAndStopFlowing() private {
        withdrawFromSuperApp();
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.deleteFlow.selector, msg.sender, address(this), new bytes(0)),
            "0x"
        );
    }

    /**
     * @dev Returns _depositor deposit in a vault and any rewards accrued,
     * calculated based on their share of the Pipe deposits.
     */
    function vaultRewardBalanceOf(address _withdrawer, uint256 _vaultBalance) public view returns (uint256) {
        // this will be 0 or a negative number
        (int256 withdrawerTotalStreamedToContract, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(_withdrawer);
        // this will be a negative number
        (int256 totalStreamedToContract, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(address(this));
        uint256 totalVaultWithdrawableAmount =
            withdrawerTotalStreamedToContract.div(totalStreamedToContract).toUint256().mul(_vaultBalance);

        return totalVaultWithdrawableAmount.sub(userWithdrawnAmounts[_withdrawer]);
    }
}
