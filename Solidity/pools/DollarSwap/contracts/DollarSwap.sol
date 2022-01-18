// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import './@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import './@openzeppelin/contracts/access/AccessControlEnumerable.sol';
import './@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './@openzeppelin/contracts/security/ReentrancyGuard.sol';
import './@openzeppelin/contracts/utils/math/Math.sol';

import './Interfaces/IDollarSwap.sol';
import './Interfaces/IShare.sol';
import './Interfaces/IPancakeRouter02.sol';
import './Interfaces/ITreasury.sol';
import './Interfaces/IBasisAsset.sol';
import './util/PriceCalculator.sol';

/**
 * @notice Implementation of swapping dollars to reward, without a router
 *
 * @dev This is essentially treated like a pool minting rewards per epoch. This rewards minted is used for the swap
 **/
contract DollarSwap is
	IDollarSwap,
	AccessControlEnumerable,
	ReentrancyGuard,
	PriceCalculator
{
	using SafeERC20 for IERC20;
	using SafeERC20 for IERC20Metadata;
	using SafeERC20 for IBasisAsset;

	bytes32 public constant dollarWithdrawerRole =
		keccak256('dollarWithdrawer');
	bytes32 public constant burnerRole = keccak256('burner');

	// The treasury address to get epoch info
	ITreasury public treasury;

	// Router to get price
	IPancakeRouter02 public router;

	// The token to be swapped to
	IERC20Metadata public rewardToken;

	// The token dollar token
	IBasisAsset public dollarToken;

	// The epoch when reward mining for swap stops
	uint256 public bonusEndEpoch;

	// reward tokens created per epoch
	uint256 public rewardPerEpoch;

	// The epoch when reward mining for swap stops
	uint256 public startEpoch;

	// The epoch number of the last reward update
	uint256 public lastRewardEpoch;

	// The path to get dollar price
	address[] public dollarToStablePath;

	// The path to get reward price
	address[] public rewardToStablePath;

	// The precision factor
	uint256 public PRECISION_FACTOR;

	// true if dollar swapped should be burned
	bool public autoBurnDollar;

	event DollarSwapped(
		uint256 indexed epoch,
		address indexed account,
		uint256 dollarAmount,
		uint256 shareAmount
	);
	event AdminTokenRecovery(address tokenRecovered, uint256 amount);
	event WithdrawDollar(address indexed account, uint256 amount);
	event BurnDollar(uint256 amount);
	event NewStartAndEndEpochs(uint256 startEpoch, uint256 endEpoch);
	event NewRewardPerEpoch(uint256 rewardPerEpoch);
	event NewAutoBurnDollar(bool burnEnabled);
	event RewardsStop(uint256 blockNumber);
	event NewTreasury(address indexed newTreasury);

	constructor(
		ITreasury _treasury,
		IPancakeRouter02 _router,
		uint256 _rewardPerEpoch,
		uint256 _startEpoch,
		uint256 _bonusEndEpoch,
		address[] memory _dollarToStablePath,
		address[] memory _rewardToStablePath
	) {
		_setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
		treasury = _treasury;
		router = _router;
		rewardPerEpoch = _rewardPerEpoch;
		startEpoch = _startEpoch;
		bonusEndEpoch = _bonusEndEpoch;
		dollarToStablePath = _dollarToStablePath;
		rewardToStablePath = _rewardToStablePath;
		rewardToken = IERC20Metadata(address(_rewardToStablePath[0]));
		dollarToken = IBasisAsset(address(_dollarToStablePath[0]));
		autoBurnDollar = false;

		uint256 decimalsRewardToken = uint256(rewardToken.decimals());
		require(decimalsRewardToken < 30, 'Must be inferior to 30');

		PRECISION_FACTOR = uint256(10**(uint256(30) - decimalsRewardToken));
	}

	/**
	 * @notice Swaps dollar to rewards
	 * @dev The _dollarAmount is burned and rewards from the reward fund are used to the swap
	 * @param _dollarAmount The amount of dollar to swap
	 *
	 * Requirements:
	 *
	 * - `_dollarAmount` must be gt 0.
	 * - must have enough shares available for swap this epoch
	 */
	function swap(uint256 _dollarAmount) external override nonReentrant {
		require(_dollarAmount > 0, 'Cannot swap 0');
		require(canSwap(_dollarAmount), 'Max shares minted this epoch');
		uint256 reward = rewardExpected(_dollarAmount);

		_updateRewardFund();

		if (autoBurnDollar) {
			dollarToken.burnFrom(_msgSender(), _dollarAmount);
		} else {
			dollarToken.safeTransferFrom(
				_msgSender(),
				address(this),
				_dollarAmount
			);
		}

		rewardToken.safeTransfer(_msgSender(), reward);

		emit DollarSwapped(
			treasury.epoch(),
			_msgSender(),
			_dollarAmount,
			reward
		);
	}

	/**
	 * @notice It allows the withdrawal of stored dollars
	 * @param _tokenAmount: the number of tokens to withdraw
	 * @dev This function is only callable by `dollarWithdrawerRole`.
	 */
	function withdrawDollar(address _account, uint256 _tokenAmount)
		external
		nonReentrant
		onlyRole(dollarWithdrawerRole)
	{
		require(_tokenAmount > 0, 'Cannot withdraw 0');
		emit WithdrawDollar(_account, _tokenAmount);
		dollarToken.safeTransfer(_account, _tokenAmount);
	}

	/**
	 * @notice It allows the burning of stored dollars
	 * @param _tokenAmount: the number of tokens to burn
	 * @dev This function is only callable by `burnerRole`.
	 */
	function burnDollar(uint256 _tokenAmount)
		external
		nonReentrant
		onlyRole(burnerRole)
	{
		require(_tokenAmount > 0, 'Cannot burn 0');
		emit BurnDollar(_tokenAmount);
		dollarToken.burn(_tokenAmount);
	}

	/**
	 * @notice It allows the admin to recover wrong tokens sent to the contract
	 * @param _tokenAddress: the address of the token to withdraw
	 * @param _tokenAmount: the number of tokens to withdraw
	 * @dev This function is only callable by admin.
	 */
	function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
		external
		nonReentrant
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(
			_tokenAddress != address(rewardToken),
			'Cannot be reward token'
		);

		emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
		IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);
	}

	/*
	 * @notice Stop rewards
	 * @dev Only callable by DEFAULT_ADMIN_ROLE
	 */
	function stopReward() external onlyRole(DEFAULT_ADMIN_ROLE) {
		bonusEndEpoch = treasury.epoch();
	}

	/*
	 * @notice Update reward per epoch
	 * @dev Only callable by DEFAULT_ADMIN_ROLE.
	 * @param _rewardPerBlock: the reward per block
	 */
	function updateRewardPerEpoch(uint256 _rewardPerEpoch)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		rewardPerEpoch = _rewardPerEpoch;
		emit NewRewardPerEpoch(_rewardPerEpoch);
	}

	/**
	 * @notice It allows the admin to update start and end blocks
	 * @dev This function is only callable by DEFAULT_ADMIN_ROLE.
	 * @param _startEpoch: the new start block
	 * @param _bonusEndEpoch: the new end block
	 */
	function updateStartAndEndEpochs(
		uint256 _startEpoch,
		uint256 _bonusEndEpoch
	) external onlyRole(DEFAULT_ADMIN_ROLE) {
		require(treasury.epoch() < startEpoch, 'Swap has started');
		require(
			_startEpoch < _bonusEndEpoch,
			'New startEpoch must be lower than new endEpoch'
		);
		require(
			treasury.epoch() < _startEpoch,
			'New startEpoch must be higher than current epoch'
		);

		startEpoch = _startEpoch;
		bonusEndEpoch = _bonusEndEpoch;

		// Set the lastRewardEpoch as the startEpoch
		lastRewardEpoch = startEpoch;

		emit NewStartAndEndEpochs(_startEpoch, _bonusEndEpoch);
	}

	/**
	 * @notice It allows the admin to update the treasury address
	 * @dev This function is only callable by DEFAULT_ADMIN_ROLE.
	 * @param _treasury: the new treasury
	 */
	function updateTreasury(ITreasury _treasury)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(_treasury != treasury, 'Same treasury address');
		treasury = _treasury;
		emit NewTreasury(address(_treasury));
	}

	/**
	 * @notice It allows the admin to update whether dollars are burned
	 * @dev This function is only callable by DEFAULT_ADMIN_ROLE.
	 * @param _autoBurnDollar: the new bool for auto dollar burning
	 */
	function updateAutoBurnDollar(bool _autoBurnDollar)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(_autoBurnDollar != autoBurnDollar, 'Same burn value');
		autoBurnDollar = _autoBurnDollar;
		emit NewAutoBurnDollar(autoBurnDollar);
	}

	/**
	 * @dev Checks if enough shares are available to swap for an epoch
	 * @param _dollarAmount The amount of dollar to swap
	 *
	 */
	function canSwap(uint256 _dollarAmount)
		public
		view
		override
		returns (bool)
	{
		uint256 reward = rewardExpected(_dollarAmount);
		return
			reward > 0 &&
			IShare(address(rewardToken)).canMint(address(this), reward) &&
			pendingReward() >= reward;
	}

	/**
	 * @dev Computes the amount of shares to swap for dollar
	 * @param _dollarAmount The amount of dollar to swap
	 *
	 */
	function rewardExpected(uint256 _dollarAmount)
		public
		view
		override
		returns (uint256)
	{
		return
			(_getTokenPrice(router, dollarToStablePath) * _dollarAmount) /
			_getTokenPrice(router, rewardToStablePath);
	}

	/*
	 * @notice View function to see pending reward on frontend.
	 * @return Pending reward for the community to use
	 */
	function pendingReward() public view returns (uint256) {
		uint256 rewardTokenSupply = rewardToken.balanceOf(address(this));
		if (treasury.epoch() > lastRewardEpoch) {
			uint256 multiplier = _getMultiplier(
				lastRewardEpoch,
				treasury.epoch()
			);
			uint256 reward = multiplier * rewardPerEpoch;
			return rewardTokenSupply + reward;
		} else {
			return rewardTokenSupply;
		}
	}

	/*
	 * @notice Update reward variables to be up-to-date.
	 */
	function _updateRewardFund() internal {
		if (treasury.epoch() <= lastRewardEpoch) {
			return;
		}

		uint256 multiplier = _getMultiplier(lastRewardEpoch, treasury.epoch());
		uint256 reward = multiplier * rewardPerEpoch;
		lastRewardEpoch = treasury.epoch();
		IMintableToken(address(rewardToken)).mint(address(this), reward);
	}

	/*
	 * @notice Return reward multiplier over the given _from to _to epoch.
	 * @param _from: epoch to start
	 * @param _to: epoch to finish
	 */
	function _getMultiplier(uint256 _from, uint256 _to)
		internal
		view
		returns (uint256)
	{
		if (_to <= bonusEndEpoch) {
			return _to - _from;
		} else if (_from >= bonusEndEpoch) {
			return 0;
		} else {
			return bonusEndEpoch - _from;
		}
	}
}