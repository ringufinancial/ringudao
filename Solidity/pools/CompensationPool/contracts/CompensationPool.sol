// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '../Interfaces/IMintableToken.sol';
import 'hardhat/console.sol';

/*
 * @dev Contract to yield shares from compensation hack
 *
 */
contract CompensationPool is AccessControlEnumerable, ReentrancyGuard {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;
	using SafeERC20 for IERC20Metadata;

	// The block number when reward mining ends.
	uint256 public bonusEndBlock;

	// The block number when reward mining starts.
	uint256 public startBlock;

	// reward tokens created per block.
	uint256 public rewardPerBlock;

	// The precision factor
	uint256 public PRECISION_FACTOR;

	// The reward token
	IERC20Metadata public rewardToken;

	// Total allocation points. Must be the sum of all allocation points
	uint256 public totalAllocPoint = 0;

	// Info of each user that stakes tokens (stakedToken)
	mapping(uint256 => mapping(address => UserInfo)) public userInfo;

	// Info of each staking pool
	PoolInfo[] public poolInfo;

	// address to pull funds from
	address public fundAddress;

	struct UserInfo {
		uint256 amount; // How many staked tokens the user has provided
		uint256 rewardDebt; // Reward debt
	}

	struct PaymentInfo {
		address payable payee;
		uint256 amount;
	}

	struct PoolInfo {
		uint256 allocPoint; // How many allocation points assigned to this pool.
		uint256 lastRewardBlock; // The block number of the last pool update
		uint256 accTokenPerShare; // Accrued token per share
		uint256 totalBalance; //the total balance in one pool
	}

	event AddPool(uint256 allocPoint);
	event Claim(address indexed user, uint256 indexed pid, uint256 amount);
	event UpdatePool(uint256 indexed pid, uint256 allocPoint);
	event UpdateBalance(
		address indexed user,
		uint256 indexed pid,
		uint256 rewardAmount
	);
	event AdminTokenRecovery(address tokenRecovered, uint256 amount);
	event EmergencyWithdraw(
		address indexed user,
		uint256 indexed pid,
		uint256 amount
	);
	event NewStartAndEndBlocks(uint256 startBlock, uint256 endBlock);
	event NewRewardPerBlock(uint256 rewardPerBlock);
	event RewardsStop(uint256 blockNumber);
	event NewFundAddress(address indexed fundAddress);

	constructor(
		IERC20Metadata _rewardToken,
		uint256 _rewardPerBlock,
		uint256 _startBlock,
		uint256 _bonusEndBlock,
		address _fundAddress
	) {
		_setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

		rewardToken = _rewardToken;
		rewardPerBlock = _rewardPerBlock;
		startBlock = _startBlock;
		bonusEndBlock = _bonusEndBlock;
		fundAddress = _fundAddress;

		uint256 decimalsRewardToken = uint256(rewardToken.decimals());
		require(decimalsRewardToken < 30, 'Must be inferior to 30');

		PRECISION_FACTOR = uint256(10**(uint256(30).sub(decimalsRewardToken)));
	}

	modifier poolExists(uint256 pid) {
		require(pid < poolInfo.length, 'Pool does not exist');
		_;
	}

	/*
	 * @notice Updates a users balances
	 * @param _amount: amount of balance for user
	 * @param _pid: The id of the pool
	 */
	function updateUserBalance(
		address _user,
		uint256 _amount,
		uint256 _pid
	) external nonReentrant poolExists(_pid) onlyRole(DEFAULT_ADMIN_ROLE) {
		require(block.number < startBlock, 'Pool has started');
		UserInfo storage user = userInfo[_pid][_user];
		PoolInfo storage pool = poolInfo[_pid];

		pool.totalBalance = pool.totalBalance.sub(user.amount).add(_amount);
		user.amount = _amount;

		user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(
			PRECISION_FACTOR
		);

		emit UpdateBalance(_user, _pid, _amount);
	}

	function updateUserBalances(PaymentInfo[] calldata info, uint256 _pid)
		external
		nonReentrant
		poolExists(_pid)
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(block.number < startBlock, 'Pool has started');

		PoolInfo storage pool = poolInfo[_pid];

		for (uint256 i = 0; i < info.length; i++) {
			UserInfo storage user = userInfo[_pid][info[i].payee];

			pool.totalBalance = pool.totalBalance.sub(user.amount).add(
				info[i].amount
			);
			user.amount = info[i].amount;

			user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(
				PRECISION_FACTOR
			);
		}
	}

	/*
	 * @notice Claims reward tokens
	 * @param _amount: amount to deposit (in stakedToken)
	 * @param _pid: The id of the pool
	 */
	function claim(uint256 _pid) external nonReentrant poolExists(_pid) {
		UserInfo storage user = userInfo[_pid][msg.sender];
		PoolInfo storage pool = poolInfo[_pid];

		console.log('block number %s %s', block.number, startBlock);

		require(user.amount > 0, 'no user balance');

		_updatePool(_pid);

		uint256 pending = user
			.amount
			.mul(pool.accTokenPerShare)
			.div(PRECISION_FACTOR)
			.sub(user.rewardDebt);

		require(pending > 0, 'Nothing to claim');
		_safeRewardTransfer(address(msg.sender), pending);

		user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(
			PRECISION_FACTOR
		);

		emit Claim(msg.sender, _pid, pending);
	}

	// Update reward variables for all pools. Be careful of gas spending!
	function massUpdatePools() public onlyRole(DEFAULT_ADMIN_ROLE) {
		uint256 length = poolInfo.length;
		for (uint256 pid = 0; pid < length; ++pid) {
			_updatePool(pid);
		}
	}

	/**
	 * @notice It allows the admin to recover wrong tokens sent to the contract
	 * @param _tokenAddress: the address of the token to withdraw
	 * @param _tokenAmount: the number of tokens to withdraw
	 * @dev This function is only callable by admin.
	 */
	function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);
		emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
	}

	/*
	 * @notice Stop rewards
	 * @dev Only callable by owner
	 */
	function stopReward() external onlyRole(DEFAULT_ADMIN_ROLE) {
		bonusEndBlock = block.number;
	}

	/**
	 * @notice Allows admin to add a pool
	 * @param _allocPoint: the allocation points for the pool
	 * @param _withUpdate: weather to update pools
	 * @dev This function is only callable by admin. Do not call more than once for a single token
	 */
	function addPool(uint256 _allocPoint, bool _withUpdate)
		external
		nonReentrant
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 lastRewardBlock = block.number > startBlock
			? block.number
			: startBlock;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		poolInfo.push(
			PoolInfo({
				allocPoint: _allocPoint,
				lastRewardBlock: lastRewardBlock,
				accTokenPerShare: 0,
				totalBalance: 0
			})
		);

		emit AddPool(_allocPoint);
	}

	/**
	 * @notice Allows admin to update a pool
	 * @param _pid: pool id
	 * @param _allocPoint: the allocation points for the pool
	 * @param _withUpdate: weather to update pools
	 * @dev This function is only callable by admin
	 */
	function updatePool(
		uint256 _pid,
		uint256 _allocPoint,
		bool _withUpdate
	) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) poolExists(_pid) {
		if (_withUpdate) {
			massUpdatePools();
		}
		totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
			_allocPoint
		);
		poolInfo[_pid].allocPoint = _allocPoint;
		emit UpdatePool(_pid, _allocPoint);
	}

	/*
	 * @notice Update reward per block
	 * @dev Only callable by owner.
	 * @param _rewardPerBlock: the reward per block
	 */
	function updateRewardPerBlock(uint256 _rewardPerBlock)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		rewardPerBlock = _rewardPerBlock;
		emit NewRewardPerBlock(_rewardPerBlock);
	}

	/**
	 * @notice It allows the admin to update start and end blocks
	 * @dev This function is only callable by owner.
	 * @param _startBlock: the new start block
	 * @param _bonusEndBlock: the new end block
	 */
	function updateStartAndEndBlocks(
		uint256 _startBlock,
		uint256 _bonusEndBlock
	) external onlyRole(DEFAULT_ADMIN_ROLE) {
		require(block.number < startBlock, 'Pool has started');
		require(
			_startBlock < _bonusEndBlock,
			'New startBlock must be lower than new endBlock'
		);
		require(
			block.number < _startBlock,
			'New startBlock must be higher than current block'
		);

		startBlock = _startBlock;
		bonusEndBlock = _bonusEndBlock;

		// Set the lastRewardBlock as the startBlock
		uint256 length = poolInfo.length;
		for (uint256 pid = 0; pid < length; ++pid) {
			poolInfo[pid].lastRewardBlock = startBlock;
		}

		emit NewStartAndEndBlocks(_startBlock, _bonusEndBlock);
	}

	/*
	 * @notice Update fund address
	 * @dev Only callable by owner.
	 * @param _fundAddress: the new fund address
	 */
	function updateFundAddress(address _fundAddress)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		fundAddress = _fundAddress;
		emit NewFundAddress(_fundAddress);
	}

	/*
	 * @notice View function to see pending reward on frontend.
	 * @param _user: user address
	 * @param _pid: pool id
	 * @return Pending reward for a given user
	 */
	function pendingReward(address _user, uint256 _pid)
		external
		view
		returns (uint256)
	{
		UserInfo storage user = userInfo[_pid][_user];
		PoolInfo storage pool = poolInfo[_pid];

		if (block.number > pool.lastRewardBlock && pool.totalBalance != 0) {
			uint256 multiplier = _getMultiplier(
				pool.lastRewardBlock,
				block.number
			);
			uint256 reward = multiplier
				.mul(rewardPerBlock)
				.mul(pool.allocPoint)
				.div(totalAllocPoint);
			uint256 adjustedTokenPerShare = pool.accTokenPerShare.add(
				reward.mul(PRECISION_FACTOR).div(pool.totalBalance)
			);
			return
				user
					.amount
					.mul(adjustedTokenPerShare)
					.div(PRECISION_FACTOR)
					.sub(user.rewardDebt);
		} else {
			return
				user
					.amount
					.mul(pool.accTokenPerShare)
					.div(PRECISION_FACTOR)
					.sub(user.rewardDebt);
		}
	}

	/*
	 * @notice View function to see number of pools.
	 * @return Number of pools
	 */
	function numPools() external view returns (uint256) {
		return poolInfo.length;
	}

	/*
	 * @notice Update reward variables of the given pool to be up-to-date.
	 * @param _pid: The pool id
	 */
	function _updatePool(uint256 _pid) internal {
		PoolInfo storage pool = poolInfo[_pid];
		if (block.number <= pool.lastRewardBlock) {
			return;
		}

		if (pool.totalBalance == 0) {
			pool.lastRewardBlock = block.number;
			return;
		}

		uint256 multiplier = _getMultiplier(pool.lastRewardBlock, block.number);
		uint256 reward = multiplier
			.mul(rewardPerBlock)
			.mul(pool.allocPoint)
			.div(totalAllocPoint);
		pool.accTokenPerShare = pool.accTokenPerShare.add(
			reward.mul(PRECISION_FACTOR).div(pool.totalBalance)
		);
		pool.lastRewardBlock = block.number;

		if (reward > 0) {
			rewardToken.safeTransferFrom(fundAddress, address(this), reward);
		}
	}

	/*
	 * @notice Safe transfer function, just in case if rounding error causes pool to not have enough
	 */
	function _safeRewardTransfer(address _to, uint256 _amount) internal {
		_amount = Math.min(_amount, rewardToken.balanceOf(address(this)));
		rewardToken.safeTransfer(_to, _amount);
	}

	/*
	 * @notice Return reward multiplier over the given _from to _to block.
	 * @param _from: block to start
	 * @param _to: block to finish
	 */
	function _getMultiplier(uint256 _from, uint256 _to)
		internal
		view
		returns (uint256)
	{
		if (_to <= bonusEndBlock) {
			return _to.sub(_from);
		} else if (_from >= bonusEndBlock) {
			return 0;
		} else {
			return bonusEndBlock.sub(_from);
		}
	}
}