// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/Pausable.sol';

import '../Interfaces/IZapper.sol';
import '../Interfaces/IPancakeRouter02.sol';
import '../Interfaces/IPancakePair.sol';
import '../ContractWhitelisted.sol';

/**
 * A zapper implementation which converts a single asset into
 * a BTS/BUSD or BTD/BUSD liquidity pair. And breaks a liquidity pair to single assets
 *
 */
contract Zapper is Ownable, IZapper, Pausable, ContractWhitelisted {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	address public immutable WBNB;

	IPancakeRouter02 private ROUTER;

	/*
	 * ====================
	 *    STATE VARIABLES
	 * ====================
	 */

	/**
	 * @dev Stores intermediate route information to convert a token to WBNB
	 */
	mapping(address => address) private routePairAddresses;

	/*
	 * ====================
	 *        INIT
	 * ====================
	 */

	constructor(
		address _router,
		address _WBNB,
		address _BTD,
		address _BTS,
		address _BUSD,
		address _BTDBUSD,
		address _BTSBUSD
	) {
		ROUTER = IPancakeRouter02(_router);

		WBNB = _WBNB;

		// approve our main input tokens
		IERC20(_BTD).safeApprove(address(ROUTER), type(uint256).max);
		IERC20(_BTS).safeApprove(address(ROUTER), type(uint256).max);
		IERC20(_BUSD).safeApprove(address(ROUTER), type(uint256).max);

		//approve to breakLP
		IERC20(_BTDBUSD).safeApprove(address(ROUTER), type(uint256).max);
		IERC20(_BTSBUSD).safeApprove(address(ROUTER), type(uint256).max);

		// set route pairs for our tokens
		routePairAddresses[_BTS] = _BUSD;
		routePairAddresses[_BTD] = _BUSD;
	}

	receive() external payable {}

	/*
	 * ====================
	 *    VIEW FUNCTIONS
	 * ====================
	 */

	function routePair(address _address) external view returns (address) {
		return routePairAddresses[_address];
	}

	/*
	 * =========================
	 *     EXTERNAL FUNCTIONS
	 * =========================
	 */

	function zapBNBToLP(address _to)
		external
		payable
		override
		whenNotPaused
		isAllowedContract(msg.sender)
	{
		_swapBNBToLP(_to, msg.value, msg.sender);
	}

	function zapTokenToLP(
		address _from,
		uint256 amount,
		address _to
	) external override whenNotPaused isAllowedContract(msg.sender) {
		IERC20(_from).safeTransferFrom(msg.sender, address(this), amount);

		IPancakePair pair = IPancakePair(_to);
		address token0 = pair.token0();
		address token1 = pair.token1();

		// BTS, BTD, BUSD to create BTS-BUSD or BTD-BUSD will hit this if
		if (_from == token0 || _from == token1) {
			// Swap half amount for other
			address other = _from == token0 ? token1 : token0;
			uint256 sellAmount = amount.div(2);
			_swap(_from, sellAmount, other, address(this));

			uint256 token0Amount = IERC20(token0).balanceOf(address(this));
			uint256 token1Amount = IERC20(token1).balanceOf(address(this));
			ROUTER.addLiquidity(
				token0,
				token1,
				token0Amount,
				token1Amount,
				0,
				0,
				msg.sender,
				block.timestamp + 600
			);
		} else {
			// Unknown future input tokens will make use of this
			uint256 bnbAmount = _swapTokenForBNB(_from, amount, address(this));
			_swapBNBToLP(_to, bnbAmount, msg.sender);
		}
	}

	function breakLP(address _from, uint256 amount)
		external
		override
		whenNotPaused
		isAllowedContract(msg.sender)
	{
		IERC20(_from).safeTransferFrom(msg.sender, address(this), amount);

		IPancakePair pair = IPancakePair(_from);
		address token0 = pair.token0();
		address token1 = pair.token1();
		ROUTER.removeLiquidity(
			token0,
			token1,
			amount,
			0,
			0,
			msg.sender,
			block.timestamp + 600
		);
	}

	/*
	 * =========================
	 *     PRIVATE FUNCTIONS
	 * =========================
	 */

	function _swapBNBToLP(
		address lp,
		uint256 amount,
		address receiver
	) private {
		IPancakePair pair = IPancakePair(lp);
		address token0 = pair.token0();
		address token1 = pair.token1();

		uint256 swapValue = amount.div(2);
		_swapBNBForToken(token0, swapValue, address(this));
		_swapBNBForToken(token1, amount.sub(swapValue), address(this));

		uint256 token0Amount = IERC20(token0).balanceOf(address(this));
		uint256 token1Amount = IERC20(token1).balanceOf(address(this));

		ROUTER.addLiquidity(
			token0,
			token1,
			token0Amount,
			token1Amount,
			0,
			0,
			receiver,
			block.timestamp + 600
		);
	}

	function _swapBNBForToken(
		address token,
		uint256 value,
		address receiver
	) private returns (uint256) {
		address[] memory path;

		if (routePairAddresses[token] != address(0)) {
			// E.g. [WBNB, BUSD, BTS/BTD]
			path = new address[](3);
			path[0] = WBNB;
			path[1] = routePairAddresses[token];
			path[2] = token;
		} else {
			path = new address[](2);
			path[0] = WBNB;
			path[1] = token;
		}

		uint256[] memory amounts = ROUTER.swapExactETHForTokens{value: value}(
			0,
			path,
			receiver,
			block.timestamp + 600
		);
		return amounts[amounts.length - 1];
	}

	function _swapTokenForBNB(
		address token,
		uint256 amount,
		address receiver
	) private returns (uint256) {
		address[] memory path;
		if (routePairAddresses[token] != address(0)) {
			// E.g. [BTD/BTS, BUSD, WBNB]
			path = new address[](3);
			path[0] = token;
			path[1] = routePairAddresses[token];
			path[2] = WBNB;
		} else {
			path = new address[](2);
			path[0] = token;
			path[1] = WBNB;
		}

		uint256[] memory amounts = ROUTER.swapExactTokensForETH(
			amount,
			0,
			path,
			receiver,
			block.timestamp + 600
		);
		return amounts[amounts.length - 1];
	}

	/*
	 * Generic swap function that can swap between any two tokens with a maximum of three intermediate hops
	 * Not very useful for our current use case as bolt input currencies will only be BUSD, WBNB, BTD, BTS
	 * However having this function helps us open up to more input currencies
	 */
	function _swap(
		address _from,
		uint256 amount,
		address _to,
		address receiver
	) private returns (uint256) {
		address intermediate = routePairAddresses[_from];
		if (intermediate == address(0)) {
			intermediate = routePairAddresses[_to];
		}

		address[] memory path;
		if (intermediate != address(0) && (_from == WBNB || _to == WBNB)) {
			// E.g. [WBNB, BUSD, BTS/BTD] or [BTS/BTD, BUSD, WBNB]
			path = new address[](3);
			path[0] = _from;
			path[1] = intermediate;
			path[2] = _to;
		} else if (
			intermediate != address(0) &&
			(_from == intermediate || _to == intermediate)
		) {
			// E.g. [BUSD, BTS/BTD] or [BTS/BTD, BUSD]
			path = new address[](2);
			path[0] = _from;
			path[1] = _to;
		} else if (
			intermediate != address(0) &&
			routePairAddresses[_from] == routePairAddresses[_to]
		) {
			// E.g. [BTD, BUSD, BTS] or [BTS, BUSD, BTD]
			path = new address[](3);
			path[0] = _from;
			path[1] = intermediate;
			path[2] = _to;
		} else if (
			routePairAddresses[_from] != address(0) &&
			routePairAddresses[_to] != address(0) &&
			routePairAddresses[_from] != routePairAddresses[_to]
		) {
			// E.g. routePairAddresses[xToken] = xRoute
			// [BTS/BTS, BUSD, WBNB, xRoute, xToken]
			path = new address[](5);
			path[0] = _from;
			path[1] = routePairAddresses[_from];
			path[2] = WBNB;
			path[3] = routePairAddresses[_to];
			path[4] = _to;
		} else if (
			intermediate != address(0) &&
			routePairAddresses[_from] != address(0)
		) {
			// E.g. [BTS/BTD, BUSD, WBNB, xTokenWithWBNBLiquidity]
			path = new address[](4);
			path[0] = _from;
			path[1] = intermediate;
			path[2] = WBNB;
			path[3] = _to;
		} else if (
			intermediate != address(0) && routePairAddresses[_to] != address(0)
		) {
			// E.g. [xTokenWithWBNBLiquidity, WBNB, BUSD, BTS/BTD]
			path = new address[](4);
			path[0] = _from;
			path[1] = WBNB;
			path[2] = intermediate;
			path[3] = _to;
		} else if (_from == WBNB || _to == WBNB) {
			// E.g. [WBNB, xTokenWithWBNBLiquidity] or [xTokenWithWBNBLiquidity, WBNB]
			path = new address[](2);
			path[0] = _from;
			path[1] = _to;
		} else {
			// E.g. [xTokenWithWBNBLiquidity, WBNB, yTokenWithWBNBLiquidity]
			path = new address[](3);
			path[0] = _from;
			path[1] = WBNB;
			path[2] = _to;
		}

		uint256[] memory amounts = ROUTER.swapExactTokensForTokens(
			amount,
			0,
			path,
			receiver,
			block.timestamp + 600
		);
		return amounts[amounts.length - 1];
	}

	/*
	 * ========================
	 *     OWNER FUNCTIONS
	 * ========================
	 */

	/**
	 * Helps store intermediate route information to convert a token to WBNB
	 */
	function setRoutePairAddress(address asset, address route)
		external
		onlyOwner
	{
		routePairAddresses[asset] = route;
	}

	/**
	 * Approves a new input token for the zapper.
	 * Use this method to add new input tokens to be accepted by the zapper
	 */
	function approveNewInputToken(address token) external onlyOwner {
		if (IERC20(token).allowance(address(this), address(ROUTER)) == 0) {
			IERC20(token).safeApprove(address(ROUTER), type(uint256).max);
		}
	}

	/**
	 *
	 *  Recovers stuck tokens in the contract
	 *
	 */
	function withdraw(address token) external onlyOwner {
		if (token == address(0)) {
			payable(owner()).transfer(address(this).balance);
			return;
		}

		IERC20(token).safeTransfer(
			owner(),
			IERC20(token).balanceOf(address(this))
		);
	}

	function pause() external onlyOwner {
		_pause();
	}

	function unpause() external onlyOwner {
		_unpause();
	}
}