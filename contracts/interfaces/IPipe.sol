// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IPipe {
  function deposit(uint256) external;

  function depositAll() external;

  function withdraw(uint256 _amount, address _to) external;
}
