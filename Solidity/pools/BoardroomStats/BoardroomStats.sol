// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '../Interfaces/IBoardroom02.sol';
import '../util/PriceCalculator.sol';
import '../Interfaces/ITreasury.sol';

/*
 * @notice Contract to compute TVL and APR of boardrooms
 * @dev This assumes only two types of boardrooms - share & cash-stable boardroom.
 * Anything else will need a new contract.
 */
contract BoardroomStats is PriceCalculator {
	using SafeMath for uint256;

	ITreasury public treasury;
	IPancakeRouter02 public router;

	address[] public cashToStablePath;
	address[] public shareToStablePath;
	address[] public cashLP0ToStable;
	address[] public cashLP1ToStable;

	constructor(
		ITreasury _treasury,
		IPancakeRouter02 _router,
		address[] memory _cashToStablePath,
		address[] memory _shareToStablePath,
		address[] memory _cashLP0ToStable,
		address[] memory _cashLP1ToStable
	) {
		treasury = _treasury;
		router = _router;
		cashToStablePath = _cashToStablePath;
		shareToStablePath = _shareToStablePath;
		cashLP0ToStable = _cashLP0ToStable;
		cashLP1ToStable = _cashLP1ToStable;
	}

	function APR(IBoardroom02 _boardroom) external view returns (uint256) {
		(bool success, uint256 latestSnapshotIndex) = _tryLatestSnapshotIndex(
			_boardroom
		);
		if (!success) return 0;

		uint256 prevCRPS = 0;
		uint256 prevSRPS = 0;

		if (latestSnapshotIndex >= 1) {
			prevCRPS = _boardroom
				.boardHistory(latestSnapshotIndex - 1)
				.cashRewardPerShare;
			prevSRPS = _boardroom
				.boardHistory(latestSnapshotIndex - 1)
				.shareRewardPerShare;
		}

		uint256 epochCRPS = _boardroom
			.boardHistory(latestSnapshotIndex)
			.cashRewardPerShare
			.sub(prevCRPS);

		uint256 epochSRPS = _boardroom
			.boardHistory(latestSnapshotIndex)
			.shareRewardPerShare
			.sub(prevSRPS);

		// 31536000 = seconds in a year
		return
			(epochCRPS.mul(_getTokenPrice(router, cashToStablePath)) +
				epochSRPS.mul(_getTokenPrice(router, shareToStablePath)))
				.mul(31536000)
				.div(treasury.PERIOD())
				.div(stakedTokenPrice(_boardroom));
	}

	function TVL(IBoardroom02 _boardroom) external view returns (uint256) {
		return
			_boardroom.totalSupply().mul(stakedTokenPrice(_boardroom)).div(
				1e18
			);
	}

	function stakedTokenPrice(IBoardroom02 _boardroom)
		public
		view
		returns (uint256)
	{
		if (address(_boardroom.wantToken()) == address(_boardroom.share()))
			return _getTokenPrice(router, shareToStablePath);
		else
			return
				_getLPTokenPrice(
					router,
					cashLP0ToStable,
					cashLP1ToStable,
					_boardroom.wantToken()
				);
	}

	function _tryLatestSnapshotIndex(IBoardroom02 _boardroom)
		internal
		view
		returns (bool, uint256)
	{
		(bool success, bytes memory returnData) = address(_boardroom)
			.staticcall(
				abi.encodeWithSelector(_boardroom.latestSnapshotIndex.selector)
			);
		if (success) {
			return (true, abi.decode(returnData, (uint256)));
		} else {
			return (false, 0);
		}
	}
}