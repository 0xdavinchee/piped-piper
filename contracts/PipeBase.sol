// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IPipe.sol";

contract PipeBase is Ownable, IPipe {
	using SafeERC20 for IERC20;
	using Math for uint256;

	address public controlValve;

	ISuperToken public inputToken; 
	IERC20 public outputToken;
	IVault public vault;
	uint256 public roundSizeInputAmount;
	
	constructor(address _valve, address _inputToken, address _outputToken, uint256 _roundSizeInputAmount, address _vault) {
		require(_valve != address(0), "SuperValve address is undefined");
		require(_inputToken != address(0), "Input token address is undefined");
    require(_outputToken != address(0), "Output token address is undefined");
    require(_vault != address(0), "Vault address is undefined");

		inputToken = ISuperToken(_inputToken);
    outputToken = IERC20(_outputToken);

		require(inputToken.getUnderlyingToken() == address(outputToken),
			"Underlying input token does not match output token");

    roundSizeInputAmount = _roundSizeInputAmount;
    vault = IVault(_vault);
		controlValve = _valve;
	}

	//******************
	// Public functions
	//******************

	function deposit(uint256 _amount) external override onlyOwner {
		_depositToVault(_amount);
	}

	// @dev Deposit all pending SuperTokens currently in contract
	function depositAll() external override onlyOwner {
		uint256 amount = inputToken.balanceOf(address(this));
		_depositToVault(amount);
	}

	function withdraw(uint256 _amount, address _to) external override onlyOwner {
		_withdrawFromVault(_amount, _to);
	}

	//******************
	// Private functions
	//******************

	// @dev Downgrades streamed SuperTokens and deposits into vault. User allocations
	//			are tracked in associated SuperValve.
	function _depositToVault(uint256 _amount) internal {
		uint256 superTokenAmount = inputToken.balanceOf(address(this));
		require(superTokenAmount >= _amount, "Requested amount of tokens are not available to deposit");

		inputToken.downgrade(_amount);
		vault.deposit(_amount);

		// TODO emit deposit event
	}


	// @dev Withdraws amount to user. Called by user. Amount is calculated in ControlValve
	// based on	user's stream amounts.
	function _withdrawFromVault(uint256 _amount, address _to) internal onlyValve {
		require(IERC20(address(vault)).balanceOf(address(this)) > _amount,
			"Not enough tokens in vault to withdraw this amount");

		// Withdraws outputToken to this contract
		vault.withdraw(_amount);

		// Transfer to user
		outputToken.safeTransfer(_to, _amount);

		// TODO emit withdrawal event
	}

	modifier onlyValve() {
		require(msg.sender == controlValve, "Only associated ControlValve is allowed to call this");
		_;
	}
}