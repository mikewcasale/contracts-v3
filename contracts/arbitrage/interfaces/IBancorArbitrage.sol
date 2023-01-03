// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { IUpgradeable } from "../../utility/interfaces/IUpgradeable.sol";
import { Token } from "../../token/Token.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../network/interfaces/IBancorNetwork.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

struct TradeParams {
    Token sourceToken;
    Token targetToken;
    uint256 sourceAmount;
    uint256 minReturnAmount;
    uint256 deadline;
    uint exchangeId;
}

interface IUniswapV3Router is ISwapRouter {
    function refundETH() external payable;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}


interface IBancorArbitrage is IUpgradeable {
    /**
     * @dev trades on UniswapV2 and returns the token1 amount
     */
    function tradeUniswapV2(
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minReturnAmount,
        uint256 deadline,
        address beneficiary
    ) external returns (uint256);

    /**
     * @dev trades on UniswapV3 and returns the token1 amount
     */
    function tradeUniswapV3(
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minReturnAmount,
        uint256 deadline,
        address beneficiary
    ) external returns (uint256);

    /**
     * @dev trades on SushiSwap and returns the token1 amount
     */
    function tradeSushiSwap(
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minReturnAmount,
        uint256 deadline,
        address beneficiary
    ) external returns (uint256);

    /**
     * @dev trades on BancorV3 and returns the token1 amount
     */
    function tradeBancorV3(
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minReturnAmount,
        uint256 deadline
    ) external returns (uint256);

    /**
     * @dev takes out a flash loan of BNT on BancorV3
     */
    function takeFlashLoan(
        Token token,
        uint256 amount,
        IFlashLoanRecipient recipient,
        bytes calldata data
    ) external;

    /**
     * @dev executes the arbitrage trades according to a list of routes, return the amount of profits sent to the
     * caller and burns the remaining BNT amount
     */
    function execute(TradeParams[] memory _trades
    ) external payable returns (uint256);
}
