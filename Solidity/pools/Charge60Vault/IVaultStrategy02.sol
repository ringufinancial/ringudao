pragma solidity 0.8.4;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './IVaultStrategy.sol';

interface IVaultStrategy02 is IVaultStrategy {
	function _deposit(uint256 amount) external;
}