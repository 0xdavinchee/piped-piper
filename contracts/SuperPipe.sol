// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
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

contract SuperPipe is SuperAppBase {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct UserWithdrawn {
        uint256 amount; // total amount user has withdrawn from vaults
        bool isFlowing;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;
    address private vault;

    mapping(address => UserWithdrawn) private userWithdrawnAmounts;

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
        return userWithdrawnAmounts[_address].isFlowing;
    }

    /**
     * @dev Adds _depositor if the _depositor does not have an open flow.
     */
    function _addDepositor(address _depositor) private {
        bool isDepositor = _isFlowing(_depositor);
        if (!isDepositor) {
            userWithdrawnAmounts[_depositor] = UserWithdrawn(0, true);
        }
    }

    /**
     * @dev Removes _depositor from the depositor mapping AND depositors array if they have an open flow.
     */
    function _removeDepositor(address _depositor) private {
        bool isDepositor = _isFlowing(_depositor);
        if (isDepositor) {
            delete userWithdrawnAmounts[_depositor];
        }
    }

    /**
     * @dev Returns the amount deposited into a vault by _depositor.
     */
    function depositBalanceOf(address _depositor) private view returns (uint256) {
        return userWithdrawnAmounts[_depositor].amount;
    }

    /**************************************************************************
     * Deposit/Withdraw Logic
     *************************************************************************/

    /**
     * @dev Called after someone makes a deposit into the SuperPipe Super App and updates
     * the internal state accordingly.
     */
    function _depositIntoSuperPipe(bytes calldata _ctx) private returns (bytes memory ctx) {
        ctx = _ctx;
        address depositor = host.decodeCtx(_ctx).msgSender;
        _addDepositor(depositor);
    }

    /**
     * @dev Called after someone makes a deposit into the SuperPipe Super App and updates
     * the internal state accordingly.
     */
    function _closeSuperPipeStream(bytes calldata _ctx) private returns (bytes memory ctx) {
        ctx = _ctx;
        address depositor = host.decodeCtx(_ctx).msgSender;
        _removeDepositor(depositor);
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
        uint256 amount = superPipeAvailableBalance.toUint256();

        // TODO: there is likely a missing step here where we actually move the available balance into the
        // ownership of the superPipe contract
        superToken.downgrade(amount);
        address underlyingToken = superToken.getUnderlyingToken();

        ISuperToken(underlyingToken).increaseAllowance(vault, amount);

        // TODO: This will be replaced by the vault deposit function
        ISuperToken(underlyingToken).transferFrom(address(this), vault, amount);
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdrawFromSuperApp() public {
        require(userWithdrawnAmounts[msg.sender].isFlowing == true, "Not a depositor.");
        uint256 totalVaultBalance = 0; // TODO: Get address(this) vault balance (likely requires Vault interface)
        uint256 withdrawerVaultAmount = vaultRewardBalanceOf(msg.sender, totalVaultBalance);

        // TODO: Requires the vault interface withdraw here.
        // vault.withdraw(withdrawerVaultAmount);

        // this will be a negative number (the net flow of the depositor)
        (int256 withdrawerAvailableBalance, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(msg.sender);

        // withdrawable vault amount (incl. rewards) - (-currrent negative stream net flow)
        uint256 withdrawAmount = withdrawerVaultAmount.sub(withdrawerAvailableBalance.toUint256());

        // update the user's deposit amount
        userWithdrawnAmounts[msg.sender].amount = userWithdrawnAmounts[msg.sender].amount.add(withdrawerVaultAmount);

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
     * calculated based on their share of the SuperPipe deposits.
     */
    function vaultRewardBalanceOf(address _withdrawer, uint256 _vaultBalance) public view returns (uint256) {
        // this will be 0 or a negative number
        (int256 withdrawerTotalStreamedToContract, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(_withdrawer);
        // this will be a negative number
        (int256 totalStreamedToContract, , , ) = ISuperToken(acceptedToken).realtimeBalanceOfNow(address(this));
        uint256 totalVaultWithdrawableAmount =
            withdrawerTotalStreamedToContract.div(totalStreamedToContract).toUint256().mul(_vaultBalance);

        return totalVaultWithdrawableAmount.sub(userWithdrawnAmounts[_withdrawer].amount);
    }

    /**************************************************************************
     * SuperApp callbacks
     *************************************************************************/

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
        return _depositIntoSuperPipe(_ctx);
    }

    /**
     * @dev Callback that is called after a new flow agreement is terminated.
     */
    function afterAgreementTerminated(
        ISuperToken _superToken,
        address _agreementClass,
        bytes32, // _agreementId
        bytes calldata, // _agreementData
        bytes calldata _ctx
    ) external returns (bytes memory) {
        if (!_isAccepted(_superToken) || !_isCFAv1(_agreementClass)) {
            return _ctx;
        }
        return _closeSuperPipeStream(_ctx);
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
