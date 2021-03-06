// SPDX-License-Identifier: MIT
pragma solidity >=0.7.1;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FakeVault is solely for testing purposes, this contract will
/// already be deployed, but this is a simple vault which allows you to
/// deposit tokens for vault tokens and redeem your original tokens for
/// the vault tokens.
contract FakeVault is ERC20 {
    address public owner;
    IERC20 public acceptedToken; // fToken

    constructor(
        address _acceptedToken,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        owner = msg.sender;
        acceptedToken = IERC20(_acceptedToken);
    }

    /** @dev User can use this function to deposits the acceptedToken, and receive
     * vault tokens in return.
     */
    function depositTokens(uint256 _amount, address _vaultPipe) public {
        _mint(_vaultPipe, _amount);
    }

    /** @dev User can use this function to deposit the vault token and receive the exact
     * number of accepted tokens in return. (Normally this number would be calculated based)
     * on a % share of the pool.
     */
    function withdrawTokens(uint256 _amount, address _user) public {
        _burn(address(this), _amount);
        bool withdrawSuccess = acceptedToken.transfer(_user, _amount);
        require(withdrawSuccess, "FakeVault: Withdraw transfer failed.");
    }
}
