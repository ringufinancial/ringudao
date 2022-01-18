// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IVault {
	function TVL() external view returns (uint256);

	function APR() external view returns (uint256);
}