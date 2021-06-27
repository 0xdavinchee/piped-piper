// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;

interface IVault {
  function deposit(uint256) external;

  function depositAll() external;

  function withdraw(uint256) external;

  function withdrawAll() external;

  function getPricePerFullShare() external view returns (uint256);

  // Return address of token taken by vault
  function token() external view returns (address);
}
