// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import './MasterCharge.sol';

contract FundedMasterCharge is MasterCharge {
	using SafeERC20 for IERC20Metadata;

	event AdminRewardRecovery();

	constructor(
		IERC20Metadata _rewardToken,
		uint256 _rewardPerBlock,
		uint256 _startBlock,
		uint256 _bonusEndBlock,
		IPancakeRouter02 _router,
		address[] memory _rewardToStablePath
	)
		MasterCharge(
			_rewardToken,
			_rewardPerBlock,
			_startBlock,
			_bonusEndBlock,
			_router,
			_rewardToStablePath
		)
	{}

	/*
	 * @dev This method does nothing as this contract is prefunded
	 */
	function _fundRewardTokens(address recipient, uint256 amount)
		internal
		override
	{
		if (recipient != address(this)) {
			_safeRewardTransfer(recipient, amount);
		}
	}

	/**
	 * @notice It allows the admin to recover reward funds
	 * @dev This function is only callable by admin.
	 */
	function recoverRewardFunds() external onlyRole(DEFAULT_ADMIN_ROLE) {
		rewardToken.safeTransfer(
			address(msg.sender),
			rewardToken.balanceOf(address(this))
		);
		emit AdminRewardRecovery();
	}
}