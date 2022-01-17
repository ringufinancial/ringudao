// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import './Boardroom.sol';

contract SingleTokenBoardroom is Boardroom {
	constructor(
		IERC20 _cash,
		IERC20 _share,
		IERC20 _wantToken,
		ITreasury _treasury,
		IPancakeRouter02 _router,
		address[] memory _cashToStablePath,
		address[] memory _shareToStablePath
	)
		Boardroom(
			_cash,
			_share,
			_wantToken,
			_treasury,
			_router,
			_cashToStablePath,
			_shareToStablePath
		)
	{}
}