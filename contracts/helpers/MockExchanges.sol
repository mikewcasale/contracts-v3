// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { EnumerableSet } from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import { ISwapRouter } from '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import { MockUniswapV2Pair } from './MockUniswapV2Pair.sol';

import { Token } from '../token/Token.sol';
import { TokenLibrary } from '../token/TokenLibrary.sol';

import { Utils } from '../utility/Utils.sol';
import { IBancorNetwork, IFlashLoanRecipient } from '../network/interfaces/IBancorNetwork.sol';

import { TestERC20Token } from './TestERC20Token.sol';
import { TestFlashLoanRecipient } from './TestIFlashLoanRecipient.sol';

contract MockExchanges is TestERC20Token, Utils {
	using SafeERC20 for IERC20;
	using TokenLibrary for Token;
	using EnumerableSet for EnumerableSet.AddressSet;

	Token public token0;
	Token public token1;

	MockUniswapV2Pair private immutable _weth;
	EnumerableSet.AddressSet private _tokens;

	constructor(uint256 totalSupply, MockUniswapV2Pair weth) TestERC20Token('MultiExchange', 'MULTI', totalSupply) {
		_weth = weth;
	}

	/**
	 * Bancor V3
	 * @dev takes a flash loan to perform the arbitrage trade
	 */
	function flashLoan(Token token, uint256 amount, IFlashLoanRecipient recipient, bytes calldata data) external {
		//		token.ensureApprove(msg.sender, amount);
		token.safeTransfer(address(recipient), amount);
	}

	function swap(address to, uint256 amount) public payable returns (uint) {
		Token[2] memory tokens = [token0, token1];
		for (uint256 i = 0; i < 2; i++) {
			if (address(tokens[i]) == address(_weth)) {
				payable(address(to)).transfer(amount);
			} else {
				tokens[i].ensureApprove(to, amount);
				tokens[i].safeTransfer(to, amount);
			}
		}
		return amount;
	}

	/**
	 * Bancor V3 trade
	 */
	function tradeBySourceAmount(
		Token sourceToken,
		Token targetToken,
		uint256 sourceAmount,
		uint256 minReturnAmount,
		uint256 deadline,
		address beneficiary
	) external payable returns (uint256) {
		return swap(beneficiary, sourceAmount);
	}

	/**
	 * Uniswap V3 trade
	 */
	function exactInputSingle(ISwapRouter.ExactInputSingleParams memory params) external returns (uint256 amountOut) {
		// mimic Uniswap swap
		return swap(params.recipient, params.amountIn);
	}

	/**
	 * Uniswap V2 + Sushiswap trades
	 */
	function swapExactTokensForTokens(
		uint amountIn,
		uint amountOutMin,
		address[] calldata path,
		address to,
		uint deadline
	) external returns (uint[] memory amounts) {
		// mimic swap
		uint[] memory amounts = new uint[](1);
		amounts[0] = uint(swap(to, amountIn));
		return amounts;
	}

	function swapExactETHForTokens(
		uint amountIn,
		address[] calldata path,
		address to,
		uint deadline
	) external payable returns (uint[] memory amounts) {
		// mimic swap
		uint[] memory amounts = new uint[](1);
		amounts[0] = uint(swap(to, amountIn));
		return amounts;
	}

	function swapExactTokensForETH(
		uint amountIn,
		uint amountOutMin,
		uint[] calldata path,
		address to,
		uint deadline
	) external returns (uint[] memory amounts) {
		// mimic swap
		uint[] memory amounts = new uint[](1);
		amounts[0] = uint(swap(to, amountIn));
		return amounts;
	}

	/**
	 * Bancor V2 trade
	 */
	function convertByPath(
		address[] memory _path,
		uint256 _amount,
		uint256 _minReturn,
		address _beneficiary,
		address _affiliateAccount,
		uint256 _affiliateFee
	) external payable returns (uint256) {
		uint256 res = swap(_beneficiary, _amount);
		return res;
	}

	/**
	 * Bancor V2
	 */
	function rateByPath(address[] memory _path, uint256 _amount) external view returns (uint256) {
		return _amount;
	}

	/**
	 * Bancor V2
	 */
	function conversionPath(Token sourceToken, Token targetToken) external view returns (address[] memory) {
		address[] memory path = new address[](3);
		path[0] = address(sourceToken);
		path[1] = address(0);
		path[2] = address(targetToken);

		return path;
	}

	//solhint-disable-next-line func-name-mixedcase
	function WETH() external view returns (address) {
		return address(_weth);
	}

	receive() external payable {}

	function getPair(address token0, address token1) external view returns (address) {
		if (_tokens.contains(token0) && _tokens.contains(token1)) {
			return address(_weth);
		}
		return address(0);
	}

	function setTokens(Token _token0, Token _token1) external {
		token0 = _token0;
		token1 = _token1;
		_tokens.add(address(token0));
		_tokens.add(address(token1));
	}
}
