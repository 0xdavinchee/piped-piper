// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;

import "hardhat/console.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
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

    struct Deposit {
        uint256 amount;
        bool isDepositor;
    }

    ISuperfluid private host;
    IConstantFlowAgreementV1 private cfa;
    ISuperToken private acceptedToken;
    address private vault;

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
                SuperAppDefinitions.AFTER_AGREEMENT_UPDATED_NOOP;

        host.registerApp(configWord);
    }

    /**************************************************************************
     * Staking Logic
     *************************************************************************/

    /**
     * @dev Returns whether _address is a depositor and the index of the depositor.
     */
    function _isDepositor(address _address) private view returns (bool) {
        return userDepositedAmounts[_address].isDepositor;
    }

    /**
     * @dev Adds _depositor if the _depositor is not currently one.
     */
    function _addDepositor(address _depositor) private {
        bool isDepositor = _isDepositor(_depositor);
        if (!isDepositor) {
            userDepositedAmounts[_depositor] = Deposit(0, true);
        }
    }

    /**
     * @dev Removes _depositor from depositor the depositors array if _depositor is one.
     */
    function removeDepositor(address _depositor) private {
        bool isDepositor = _isDepositor(_depositor);
        if (isDepositor) {
            delete userDepositedAmounts[_depositor];
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
        // TODO: user deposits into super app
        // add them to list of depositors
    }

    /**
     * @dev Gets the total amount flowed into the SuperPipe based on the current block.timestamp
     * downgrades all the supertokens and deposits them into a vault. Then we update the deposit
     * amount of all the depositors who now have a deposit staked in a vault.
     */
    function depositFundsIntoVault() private {
        // TODO: get total flowed amount of users
        // downgrade the supertokens of all flows and send into vault
        // update the deposit amount of all the users who have streamed in any real amount
        // into the super pipe
    }

    /**
     * @dev Withdraws the tokens from a vault and updates the state accordingly.
     */
    function withdrawFromSuperApp(uint256 _amount) external {}

    /**
     * @dev When the stops their stream and withdraws, this handles the logic of removing the depositor
     * and updating the state accordingly.
     */
    function _withdrawFromSuperAppAndStopFlowing(uint256 _amount) private {}

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
    // function afterAgreementCreated(
    //     ISuperToken _superToken,
    //     address _agreementClass,
    //     bytes32 _agreementId,
    //     bytes calldata _agreementData,
    //     bytes calldata _ctx
    // ) external override onlyExpected(_superToken, _agreementClass) onlyHost returns (bytes memory) {
    //     // TODO: user creates flow
    //     // we add them to array of stakers
    // }

    /**
     * @dev Callback that is called before a new flow agreement is terminated.
     */
    // function beforeAgreementTerminated(
    //     ISuperToken _superToken,
    //     address _agreementClass,
    //     bytes32 _agreementId,
    //     bytes calldata _agreementData,
    //     bytes calldata _ctx
    // ) external override returns (bytes memory) {
    //     // TODO: user creates flow
    //     // we add them to array of stakers
    // }

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
