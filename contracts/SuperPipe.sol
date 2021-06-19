// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";

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

// TODO: User should be able to stop flow without withdrawing.
// TODO: Refactor the code so that it doesn't use a depositors array
// and we track userWithdrawnAmounts rather than userDepositedAmounts
// using the [(totalUserStream/grandTotal)*vault_balance ]- userWithdrawnAmounts[user]

contract SuperPipe is SuperAppBase {
    using SafeMath for uint256;
    using SafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct Deposit {
        uint256 amount;
        bool isFlowing;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;
    address private vault;

    address[] private depositors;
    mapping(address => Deposit) private userDepositedAmounts;
    uint256 private totalDeposited;

    event DepositorAdded(address depositor);
    event DepositorRemoved(address depositor);

    // TODO: add vault to constructor, deploy script and .env
    constructor(
        ISuperfluid _host,
        IConstantFlowAgreementV1 _cfa,
        ISuperToken _acceptedToken
    ) {
        require(address(_host) != address(0), "Host is zero address.");
        require(address(_cfa) != address(0), "CFA is zero address.");
        require(address(_acceptedToken) != address(0), "Token is zero address.");
        host = _host;
        cfa = _cfa;
        acceptedToken = _acceptedToken;

        uint256 configWord =
            SuperAppDefinitions.APP_LEVEL_FINAL |
                SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
                SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
                SuperAppDefinitions.AFTER_AGREEMENT_UPDATED_NOOP |
                SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;

        host.registerApp(configWord);
    }

    /**************************************************************************
     * Staking Logic
     *************************************************************************/

    /**
     * @dev Returns whether _address has a flow open into the SuperPipe and the index of the depositor.
     */
    function _isFlowing(address _address) private view returns (bool) {
        return userDepositedAmounts[_address].isFlowing;
    }

    /**
     * @dev Adds _depositor if the _depositor does not have an open flow.
     */
    function _addDepositor(address _depositor) private {
        bool isDepositor = _isFlowing(_depositor);
        if (!isDepositor) {
            userDepositedAmounts[_depositor] = Deposit(0, true);
            depositors.push(_depositor);
        }
    }

    /**
     * @dev Removes _depositor from the depositor mapping AND depositors array if they have an open flow.
     */
    function removeDepositor(address _depositor) private {
        bool isDepositor = _isFlowing(_depositor);
        if (isDepositor) {
            delete userDepositedAmounts[_depositor];
            uint256 index;

            // TODO: We can prevent looping here by keeping the index
            // of the depositor in the mapping.
            for (uint256 i = 0; i < depositors.length; i++) {
                if (_depositor == depositors[i]) {
                    index = i;
                    break;
                }
            }
            depositors[index] = depositors[depositors.length - 1];
            depositors.pop();
        }
    }

    /**
     * @dev Returns the amount deposited into a vault by _depositor.
     */
    function depositBalanceOf(address _depositor) private view returns (uint256) {
        return userDepositedAmounts[_depositor].amount;
    }

    /**************************************************************************
     * Deposit/Withdraw Logic
     *************************************************************************/

    /**
     * @dev Called after someone makes a deposit into the SuperPipe Super App and updates
     * the internal state accordingly.
     */
    function _depositIntoSuperApp(bytes calldata _ctx) private returns (bytes memory ctx) {
        ctx = _ctx;
        address depositor = host.decodeCtx(_ctx).msgSender;
        _addDepositor(depositor);
    }

    /**
     * @dev Gets the total amount flowed into the SuperPipe based on the current block.timestamp
     * downgrades all the supertokens and deposits them into a vault. Then we update the deposit
     * amount of all the depositors who now have a deposit staked in a vault.
     */
    function depositFundsIntoVault() private {
        ISuperToken superToken = ISuperToken(acceptedToken);
        // this should get the available current streamed in amount from users
        (int256 superPipeAvailableBalance, , , ) = superToken.realtimeBalanceOfNow(address(this));

        // TODO: call the function w/ the VaultInterface to send funds from SuperPipe to vault.
        for (uint256 i; i < depositors.length; i++) {
            // this will be negative as the users are streaming money out to the superpipe
            (int256 realtimeBalance, , , ) = superToken.realtimeBalanceOfNow(depositors[i]);
            if (realtimeBalance < 0) {
                userDepositedAmounts[depositors[i]].amount = realtimeBalance.toUint256();
            }
        }
        // require(superPipeAvailableBalance == totalAmountAfterIncrementingOverDepositors)

        // TODO: there is likely a missing step here where we actually move the available balance into the
        // ownership of the superPipe contract
        superToken.downgrade(superPipeAvailableBalance.toUint256());
        address underlyingToken = superToken.getUnderlyingToken();

        // TODO: Look into using safeIncreaseAllowance
        ISuperToken(underlyingToken).increaseAllowance(vault, superPipeAvailableBalance.toUint256());

        // TODO: get total flowed amount of users
        // downgrade the supertokens of all flows and send into vault
        // update the deposit amount of all the users who have streamed in any real amount
        // into the super pipe
        // increment totalDeposited
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdrawFromSuperApp() external {
        require(userDepositedAmounts[msg.sender].isFlowing == true, "Not a depositor.");
        uint256 totalVaultBalance = 0; // TODO: Get address(this) vault balance (likely requires Vault interface)
        uint256 withdrawerVaultBalance = vaultRewardBalanceOf(msg.sender, totalVaultBalance);

        // this will be a negative number
        (int256 withdrawerAvailableBalance, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(msg.sender);

        // deposited vault amount (incl. rewards) + current stream balance
        uint256 withdrawAmount = withdrawerVaultBalance.add(withdrawerAvailableBalance.toUint256());

        // update the user's deposit amount
        userDepositedAmounts[msg.sender].amount = 0;

        // Withdraw vault balance
        bool success = ISuperToken(acceptedToken).transfer(msg.sender, withdrawAmount);
        require(success, "Unable to transfer tokens.");
    }

    /**
     * @dev When the stops their stream and withdraws, this handles the logic of removing the depositor
     * and updating the state accordingly.
     */
    function _withdrawFromSuperAppAndStopFlowing() private {
        host.callAgreement(
            cfa,
            abi.encodeWithSelector(cfa.deleteFlow.selector, msg.sender, address(this), new bytes(0)),
            "0x"
        );
    }

    /**
     * @dev Returns _depositor deposit in a vault and any rewards accrued,
     * calculated based on their share of the SuperPipe deposits.
     */
    function vaultRewardBalanceOf(address _depositor, uint256 _vaultBalance) private view returns (uint256) {
        return totalDeposited == 0 ? 0 : userDepositedAmounts[_depositor].amount.div(totalDeposited).mul(_vaultBalance);
    }

    /**************************************************************************
     * SuperApp callbacks
     *************************************************************************/

    // TODO: Consider any checks that may need to be made beforeAgreementCreated.

    /**
     * @dev Callback that is called once a new flow agreement being created.
     */
    function afterAgreementCreated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId
        bytes calldata, // _agreementData
        bytes calldata _ctx
    ) external onlyExpected(_superToken, _agreementClass) onlyHost returns (bytes memory) {
        return _depositIntoSuperApp(_ctx);
    }

    /**
     * @dev Callback that is called after a new flow agreement is terminated.
     */
    // function afterAgreementTerminated(
    //     ISuperToken _superToken,
    //     address _agreementClass,
    //     bytes32 _agreementId,
    //     bytes calldata _agreementData,
    //     bytes calldata _ctx
    // ) external override returns (bytes memory) {
    //     // TODO: user creates flow
    //     // we add them to array of stakers
    // }

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

    modifier onlyHost() {
        require(msg.sender == address(host), "RedirectAll: support only one host");
        _;
    }

    modifier onlyExpected(ISuperToken _superToken, address _agreementClass) {
        require(_isAccepted(_superToken), "Auction: not accepted tokens");
        require(_isCFAv1(_agreementClass), "Auction: only CFAv1 supported");
        _;
    }
}
