// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { ReentrancyGuardUpgradeable } from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { Address } from '@openzeppelin/contracts/utils/Address.sol';

import { IUniswapV2Pair } from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import { IUniswapV2Factory } from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import { IUniswapV2Router02 } from '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import { ISwapRouter } from '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

import { Token } from '../token/Token.sol';
import { TokenLibrary } from '../token/TokenLibrary.sol';

import { IVersioned } from '../utility/interfaces/IVersioned.sol';
import { Upgradeable } from '../utility/Upgradeable.sol';
import { Utils } from '../utility/Utils.sol';

import { IBancorNetwork, IFlashLoanRecipient } from '../network/interfaces/IBancorNetwork.sol';
import { INetworkSettings } from '../network/interfaces/INetworkSettings.sol';

import { IPoolToken } from '../pools/interfaces/IPoolToken.sol';
import { IBNTPool } from '../pools/interfaces/IBNTPool.sol';

//The interface supports Uniswap V3 trades.
interface IUniswapV3Router is ISwapRouter {
	function refundETH() external payable;
}

//The interface supports Bancor V2 trades.
interface IBancorNetworkV2 {
	function convertByPath(
		address[] memory _path,
		uint256 _amount,
		uint256 _minReturn,
		address _beneficiary,
		address _affiliateAccount,
		uint256 _affiliateFee
	) external payable returns (uint256);

	function rateByPath(address[] memory _path, uint256 _amount) external view returns (uint256);

	function conversionPath(Token _sourceToken, Token _targetToken) external view returns (address[] memory);
}

/**
 * @dev BancorArbitrage contract
 *
 * The BancorArbitrage contract provides the ability to perform arbitrage between Bancor and various DEXs.
 */
contract BancorArbitrage is ReentrancyGuardUpgradeable, Utils, Upgradeable {
	using SafeERC20 for IERC20;
	using SafeERC20 for IPoolToken;
	using TokenLibrary for Token;
	using Address for address payable;

	error UnsupportedTokens();
	error NoPairForTokens();
	error InvalidExchangeId();
	error InvalidTokenFirst();
	error InvalidTokenLast();
	error FirstTradeSourceMustBeBNT();
	error LastTradeTargetMustBeBNT();

	// Defines the trade parameters.
	struct TradeParams {
		Token sourceToken;
		Token targetToken;
		uint256 sourceAmount;
		uint256 minReturnAmount;
		uint256 deadline;
		uint256 exchangeId;
	}

	// Defines the arbitrage event to be emitted.
	struct ArbitrageEvent {
		address caller;
		address sourceToken;
		address targetToken;
		uint256 sourceTokenAmount;
		uint256 totalProfit;
		uint256 callerProfit;
		uint256 burnAmount;
	}

	// Defines the contract rewards configurable parameters.
	struct ArbitrageRewards {
		uint32 arbitrageProfitPercentagePPM;
		uint256 arbitrageProfitMaxAmount;
	}

	// Defines the maximum number of blocks to wait for a transaction to be mined.
	uint32 private constant MAX_DEADLINE = 10000;

	// the network contract
	IBancorNetwork internal immutable _bancorNetworkV3;

	// the network settings contract
	INetworkSettings internal immutable _networkSettings;

	// the bnt contract
	IERC20 internal immutable _bnt;

	// Uniswap v2 router contract
	IUniswapV2Router02 internal immutable _uniswapV2Router;

	// Uniswap v2 factory contract
	IUniswapV2Factory internal immutable _uniswapV2Factory;

	// Uniswap v3 factory contract
	ISwapRouter internal immutable _uniswapV3Router;

	// SushiSwap router contract
	IUniswapV2Router02 internal immutable _sushiSwapRouter;

	// the Bancor v2 network contract
	IBancorNetworkV2 internal immutable _bancorNetworkV2;

	// WETH9 contract
	IERC20 internal immutable _weth;

	// the settings for the ArbitrageProfits
	ArbitrageRewards internal _arbitrageRewards;

	// upgrade forward-compatibility storage gap
	uint256[MAX_GAP] private __gap;

	/**
	 * @dev triggered after a successful Uniswap V2 Arbitrage Closed
	 */
	event ArbitrageExecuted(ArbitrageEvent _event);

	/**
	 * @dev triggered when the settings of the contract are updated
	 */
	event ArbitrageSettingsUpdated(
		uint32 prevProfitPercentagePPM,
		uint32 newProfitPercentagePPM,
		uint256 prevProfitMaxAmount,
		uint256 newProfitMaxAmount
	);

	/**
	 * @dev a "virtual" constructor that is only used to set immutable state variables
	 */
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
		validAddress(address(initNetwork))
		validAddress(address(initNetworkSettings))
		validAddress(address(initBnt))
		validAddress(address(initUniswapV3Router))
		validAddress(address(initUniswapV2Router))
		validAddress(address(initUniswapV2Factory))
		validAddress(address(initSushiSwapRouter))
		validAddress(address(initBancorNetworkV2))
	{
		_bancorNetworkV3 = initNetwork;
		_networkSettings = initNetworkSettings;
		_bnt = initBnt;
		_uniswapV3Router = initUniswapV3Router;
		_uniswapV2Router = initUniswapV2Router;
		_uniswapV2Factory = initUniswapV2Factory;
		_sushiSwapRouter = initSushiSwapRouter;
		_bancorNetworkV2 = initBancorNetworkV2;
		_weth = IERC20(initUniswapV2Router.WETH());
		_arbitrageRewards = ArbitrageRewards({ arbitrageProfitPercentagePPM: 10, arbitrageProfitMaxAmount: 100 });
	}

	/**
	 * @dev fully initializes the contract and its parents
	 */
	function initialize() external initializer {
		__BancorArbitrage_init();
	}

	// solhint-disable func-name-mixedcase

	/**
	 * @dev initializes the contract and its parents
	 */
	function __BancorArbitrage_init() internal onlyInitializing {
		__ReentrancyGuard_init();
		__Upgradeable_init();

		__BancorArbitrage_init_unchained();
	}

	/**
	 * @dev performs contract-specific initialization
	 */
	function __BancorArbitrage_init_unchained() internal onlyInitializing {}

	/**
	 * @dev authorize the contract to receive the native token
	 */
	receive() external payable {}

	/**
	 * @inheritdoc Upgradeable
	 */
	function version() public pure override(Upgradeable) returns (uint16) {
		return 1;
	}

	/**
	 * @dev sets the settings of the ArbitrageTrade contract
	 *
	 * requirements:
	 *s
	 * - the caller must be the admin of the contract
	 */
	function setRewards(
		ArbitrageRewards calldata settings
	)
		external
		onlyAdmin
		validFee(settings.arbitrageProfitPercentagePPM)
		greaterThanZero(settings.arbitrageProfitMaxAmount)
	{
		uint32 prevArbitrageProfitPercentagePPM = _arbitrageRewards.arbitrageProfitPercentagePPM;
		uint256 prevArbitrageProfitMaxAmount = _arbitrageRewards.arbitrageProfitMaxAmount;

		if (
			prevArbitrageProfitPercentagePPM == settings.arbitrageProfitPercentagePPM &&
			prevArbitrageProfitMaxAmount == settings.arbitrageProfitMaxAmount
		) {
			return;
		}

		_arbitrageRewards = settings;

		emit ArbitrageSettingsUpdated({
			prevProfitPercentagePPM: prevArbitrageProfitPercentagePPM,
			newProfitPercentagePPM: settings.arbitrageProfitPercentagePPM,
			prevProfitMaxAmount: prevArbitrageProfitMaxAmount,
			newProfitMaxAmount: settings.arbitrageProfitMaxAmount
		});
	}

	/**
	 * @dev takes a flash loan to perform the arbitrage trade
	 */
	function takeFlashLoan(uint256 _amount) internal {
		_bancorNetworkV3.flashLoan(Token(address(_bnt)), _amount, IFlashLoanRecipient(address(this)), '0x');
	}

	/**
	 * @dev repays the flash loan to perform the arbitrage trade
	 */
	function repayFlashLoan(Token bnt, uint256 _amount) internal {
		_transferTo(bnt, _amount, address(_bancorNetworkV3));
	}

	/**
	 * @dev performs the arbitrage trade on Bancor V3
	 */
	function _tradeBancorV3(
		Token sourceToken,
		Token targetToken,
		uint256 sourceTokenAmount,
		uint256 minTargetTokenAmount,
		uint256 minReturn,
		uint256 deadline,
		address caller
	) internal returns (uint256) {
		return
			_bancorNetworkV3.tradeBySourceAmount(
				sourceToken,
				targetToken,
				sourceTokenAmount,
				minTargetTokenAmount,
				deadline,
				caller
			);
	}

	/**
	 * @dev performs the arbitrage trade on Bancor V2
	 */
	function _tradeBancorV2(
		Token sourceToken,
		Token targetToken,
		uint256 amountIn,
		uint256 amountOutMin
	) internal returns (uint256) {
		address[] memory path = _bancorNetworkV2.conversionPath(sourceToken, targetToken);
		return
			_bancorNetworkV2.convertByPath{ value: msg.value }(
				path,
				amountIn,
				amountOutMin,
				address(this),
				address(this),
				0
			);
	}

	/**
	 * @dev performs the arbitrage trade on Uniswap V3
	 */
	function _tradeUniswapV3(
		ISwapRouter router,
		Token sourceToken,
		Token targetToken,
		uint256 sourceTokenAmount,
		uint256 minTargetTokenAmount,
		uint256 minReturn,
		uint256 deadline
	) internal returns (uint256) {
		uint24 fee = 0;
		address recipient = address(this);
		uint160 sqrtPriceLimitX96 = 0;

		ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
			address(sourceToken),
			address(targetToken),
			fee,
			recipient,
			deadline,
			sourceTokenAmount,
			minTargetTokenAmount,
			sqrtPriceLimitX96
		);

		uint256 res = router.exactInputSingle(params);
		return res;
	}

	/**
	 * @dev performs the arbitrage trade on SushiSwap
	 */
	function _tradeSushiSwap(
		IUniswapV2Router02 router,
		Token sourceToken,
		Token targetToken,
		uint256 sourceTokenAmount,
		uint256 minTargetTokenAmount,
		uint256 minReturn,
		uint256 deadline
	) internal returns (uint256) {
		address recipient = address(this);
		uint[] memory amounts;
		address[] memory path = new address[](2);
		path[0] = address(sourceToken);
		path[1] = address(targetToken);

		if (sourceToken.isNative()) {
			amounts = router.swapExactETHForTokens(sourceTokenAmount, path, recipient, deadline);
		} else if (targetToken.isNative()) {
			amounts = router.swapExactTokensForETH(sourceTokenAmount, 0, path, recipient, deadline);
		} else {
			amounts = router.swapExactTokensForTokens(sourceTokenAmount, 0, path, recipient, deadline);
		}
		return uint256(amounts[amounts.length - 1]);
	}

	function processUniswapV2(
		IUniswapV2Pair pair,
		uint256 sourceTokenAmount,
		IUniswapV2Router02 router,
		Token[2] memory tokens,
		address recipient
	) internal returns (uint256) {
		// trade on UniswapV2
		IERC20(address(pair)).safeApprove(address(router), sourceTokenAmount);
		uint256 deadline = block.timestamp + MAX_DEADLINE;
		address[] memory path = new address[](2);
		path[0] = address(tokens[0]);
		path[1] = address(tokens[1]);

		if (tokens[0].isNative()) {
			router.swapExactETHForTokens(sourceTokenAmount, path, recipient, deadline);
		} else if (tokens[1].isNative()) {
			router.swapExactTokensForETH(sourceTokenAmount, 0, path, recipient, deadline);
		} else {
			router.swapExactTokensForTokens(sourceTokenAmount, 0, path, recipient, deadline);
		}

		// save states
		uint256[2] memory previousBalances = [tokens[0].balanceOf(recipient), tokens[1].balanceOf(recipient)];

		// calculate the amount of target tokens received
		uint256 targetTokenAmount = tokens[1].balanceOf(recipient) - previousBalances[1];
		return targetTokenAmount;
	}

	/**
	 * @dev tratradedes on Uniswap V2
	 */
	function _tradeUniswapV2(
		IUniswapV2Router02 router,
		IUniswapV2Factory factory,
		Token sourceToken,
		Token targetToken,
		uint256 sourceTokenAmount,
		address caller
	) internal returns (uint256 targetTokenAmount) {
		// arrange tokens in an array, replace WETH with the native token
		Token[2] memory tokens = [
			_isWETH(sourceToken) ? TokenLibrary.NATIVE_TOKEN : sourceToken,
			_isWETH(targetToken) ? TokenLibrary.NATIVE_TOKEN : targetToken
		];

		// Uniswap does not support ETH input, transform to WETH if necessary
		address sourceTokenAddress = tokens[0].isNative() ? address(_weth) : address(tokens[0]);
		address targetTokenAddress = tokens[1].isNative() ? address(_weth) : address(tokens[1]);
		address pairAddress = _uniswapV2Factory.getPair(sourceTokenAddress, targetTokenAddress);

		// get Uniswap's pair
		IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

		if (address(pair) == address(0)) {
			revert NoPairForTokens();
		}

		return processUniswapV2(pair, sourceTokenAmount, router, tokens, address(this));
	}

	/**
	 * @dev transfer given amount of given token to the caller
	 */
	function _transferTo(Token token, uint256 amount, address to) private {
		token.safeTransfer(to, amount);
	}

	/**
	 * @dev returns true if given token is WETH
	 */
	function _isWETH(Token token) internal view returns (bool) {
		return address(token) == address(_weth);
	}

	function allocateProfits(TradeParams[] memory _routes, uint256 res, address caller) internal {
		ArbitrageRewards memory settings = _arbitrageRewards;

		// get the settings for the current transaction
		uint256 burnAmount = 0;
		uint256 totalProfit = 0;
		uint256 callerProfit = 0;

		// calculate the profit
		totalProfit = res - _routes[0].sourceAmount;

		// calculate the proportion of the profit to send to the caller
		callerProfit = (totalProfit * settings.arbitrageProfitPercentagePPM) / 1000000;

		// calculate the proportion of the profit to burn
		if (callerProfit > settings.arbitrageProfitMaxAmount) {
			callerProfit = settings.arbitrageProfitMaxAmount;
			burnAmount = totalProfit - callerProfit;
		} else {
			burnAmount = totalProfit - callerProfit;
		}

		// transfer the appropriate profit to the caller
		_transferTo(_routes[0].sourceToken, callerProfit, caller);

		// burn the rest TODO: check if this is the way to burn BNT
		_transferTo(_routes[0].sourceToken, burnAmount, address(_routes[0].sourceToken));

		emit ArbitrageExecuted(
			ArbitrageEvent(
				address(msg.sender),
				address(_routes[0].sourceToken),
				address(_routes[_routes.length - 1].targetToken),
				_routes[0].sourceAmount,
				totalProfit,
				callerProfit,
				burnAmount
			)
		);
	}

	function executeSwaps(TradeParams[] memory _routes) internal returns (uint256 res) {
		uint256 res = 0;
		uint256 minTargetTokenAmount = 0;
		uint256 minReturn = 0;

		// perform the trade routes
		for (uint i = 0; i < _routes.length; i++) {
			uint exchangeId = _routes[i].exchangeId;

			// route the trade to the correct exchange
			if (exchangeId == 0) {

				// Bancor V3
				res = _tradeBancorV3(
					_routes[i].sourceToken,
					_routes[i].targetToken,
					_routes[i].sourceAmount,
					minTargetTokenAmount,
					_routes[i].minReturnAmount,
					_routes[i].deadline,
					address(this)
				);
			} else if (exchangeId == 1) {
				// SushiSwap
				res = _tradeSushiSwap(
					_sushiSwapRouter,
					_routes[i].sourceToken,
					_routes[i].targetToken,
					_routes[i].sourceAmount,
					minTargetTokenAmount,
					_routes[i].minReturnAmount,
					_routes[i].deadline
				);
			} else if (exchangeId == 2) {
				// Uniswap V2
				res = _tradeUniswapV2(
					_uniswapV2Router,
					_uniswapV2Factory,
					_routes[i].sourceToken,
					_routes[i].targetToken,
					_routes[i].sourceAmount,
					address(this)
				);
			} else if (exchangeId == 3) {
				// Uniswap V3
				res = _tradeUniswapV3(
					_uniswapV3Router,
					_routes[i].sourceToken,
					_routes[i].targetToken,
					_routes[i].sourceAmount,
					minTargetTokenAmount,
					_routes[i].minReturnAmount,
					_routes[i].deadline
				);
			} else if (exchangeId == 4) {
				// Bancor IBancorNetworkV2
				res = _tradeBancorV2(_routes[i].sourceToken, _routes[i].targetToken, res, _routes[i].minReturnAmount);
			} else {
				revert InvalidExchangeId();
			}

			// on the last trade, transfer the appropriate BNT profit to the caller and burn the rest
			if (i == _routes.length - 1) {
				return res;
			}
		}
		return res;
	}

	/**
	 * @dev execute multi-step arbitrage trade between Bancor V3 and another exchange
	 */
	function execute(
		Token sourceToken1,
		Token targetToken1,
		uint256 sourceAmount1,
		Token sourceToken2,
		Token targetToken2,
		uint16 exchangeId2,
		Token sourceToken3,
		Token targetToken3,
		uint256 deadline
	) public {
		address caller = msg.sender;

		// parse the trade params
		TradeParams[] memory _routes = new TradeParams[](3);
		_routes[0] = TradeParams(sourceToken1, targetToken1, sourceAmount1, 0, deadline, 0);
		_routes[1] = TradeParams(sourceToken2, targetToken2, sourceAmount1, 0, deadline, exchangeId2);
		_routes[2] = TradeParams(sourceToken3, targetToken3, sourceAmount1, 0, deadline, 0);

		// check if the initial trade source token is BNT
		bool isFirstValid = _routes[0].sourceToken.isEqual(_bnt);
		if (!isFirstValid) {
			revert FirstTradeSourceMustBeBNT();
		}

		// check if the last trade target token is BNT
		bool isLastValid = _routes[_routes.length - 1].targetToken.isEqual(_bnt);
		if (!isLastValid) {
			revert LastTradeTargetMustBeBNT();
		}

		// take a flashloan for the source amount on Bancor V3
		takeFlashLoan(_routes[0].sourceAmount);

		// execute the swaps
		uint res = executeSwaps(_routes);

		// return the flashloan
		repayFlashLoan(_routes[0].sourceToken, _routes[0].sourceAmount);

		// allocate the profit
		allocateProfits(_routes, res, caller);

	}
}
