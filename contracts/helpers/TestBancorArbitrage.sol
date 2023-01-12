// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import '../arbitrage/BancorArbitrage.sol';

contract TestBancorArbitrage is BancorArbitrage {
	using SafeERC20 for IERC20;
	using SafeERC20 for IPoolToken;
	using TokenLibrary for Token;
	using Address for address payable;

	constructor(
		IBancorNetwork initNetwork,
		INetworkSettings initNetworkSettings,
		IERC20 initBnt,
		ISwapRouter initUniswapV3Router,
		IUniswapV2Router02 initUniswapV2Router,
		IUniswapV2Factory initUniswapV2Factory,
		IUniswapV2Router02 initSushiSwapRouter,
		IBancorNetworkV2 initBancorNetworkV2
	)
		BancorArbitrage(
			initNetwork,
			initNetworkSettings,
			initBnt,
			initUniswapV3Router,
			initUniswapV2Router,
			initUniswapV2Factory,
			initSushiSwapRouter,
			initBancorNetworkV2
		)
	{}

	/**
	 * @dev tests the arbitrage trade on Bancor V3
	 */
	function testTradeBancorV3(
		Token sourceToken,
		Token targetToken,
		uint256 sourceTokenAmount,
		uint256 minTargetTokenAmount,
		uint256 minReturn,
		uint256 deadline
	) public returns (uint256) {
		return
			_tradeBancorV3(
				sourceToken,
				targetToken,
				sourceTokenAmount,
				minTargetTokenAmount,
				minReturn,
				deadline,
				address(this)
			);
	}

	/**
	 * @dev tests the arbitrage trade on Bancor V2
	 */
	function testTradeBancorV2(
		Token sourceToken,
		Token targetToken,
		uint256 amountIn,
		uint256 amountOutMin
	) public returns (uint256) {
		return _tradeBancorV2(sourceToken, targetToken, amountIn, amountOutMin);
	}

	/**
	 * @dev trades on Uniswap V2
	 */
	function testTradeUniswapV2(
		Token sourceToken,
		Token targetToken,
		uint256 sourceAmount,
		address caller
	) public returns (uint256 targetTokenAmount) {
		return _tradeUniswapV2(_uniswapV2Router, _uniswapV2Factory, sourceToken, targetToken, sourceAmount, caller);
	}

	/**
	 * @dev tests the arbitrage trade on Uniswap V3
	 */
	function testTradeUniswapV3(
		Token sourceToken,
		Token targetToken,
		uint256 sourceAmount,
		uint256 minTargetAmount,
		uint256 minReturnAmount,
		uint256 deadline
	) public returns (uint256) {
		return
			_tradeUniswapV3(
				_uniswapV3Router,
				sourceToken,
				targetToken,
				sourceAmount,
				minTargetAmount,
				minReturnAmount,
				deadline
			);
	}

	/**
	 * @dev test trade on SushiSwap
	 */
	function testTradeSushiSwap(
		Token sourceToken,
		Token targetToken,
		uint256 sourceAmount,
		uint256 minTargetAmount,
		uint256 minReturnAmount,
		uint256 deadline
	) public returns (uint256) {
		return
			_tradeSushiSwap(
				_sushiSwapRouter,
				sourceToken,
				targetToken,
				sourceAmount,
				minTargetAmount,
				minReturnAmount,
				deadline
			);
	}
}
