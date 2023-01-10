// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";

import { Utils } from "../utility/Utils.sol";
import { TestERC20Token } from "./TestERC20Token.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { TestFlashLoanRecipient } from "./TestIFlashLoanRecipient.sol";

import { IBancorNetwork, IFlashLoanRecipient } from "../network/interfaces/IBancorNetwork.sol";

struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 deadline;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

contract MockExchanges is TestERC20Token, Utils {
    using SafeERC20 for IERC20;
    using TokenLibrary for Token;

    Token public token0;
    Token public token1;
    Token public token2;
    Token public route0;
    Token public route1;
    Token public route2;
    uint256 routeNumber = 0;

    IBancorNetwork private immutable _network;
    address private immutable _baseToken;

    constructor(
        uint256 totalSupply,
        address baseToken,
        IBancorNetwork initNetwork
    )
        TestERC20Token("MultiExchange", "MULTI", totalSupply)
    {
        _baseToken = baseToken;
        _network = initNetwork;
    }

    /**
     * Bancor V3
     * @dev takes a flash loan to perform the arbitrage trade
     */
    function takeFlashLoan(uint256 _amount) public {
//        TestFlashLoanRecipient flashLoanRecipient = new TestFlashLoanRecipient(_network);
        _network.flashLoan(Token(address(_baseToken)), _amount, IFlashLoanRecipient(address(this)), "0x");
    }

    function swap(address to, uint256 amount) public payable returns (uint) {
        Token[2] memory tokens = [token0, token1];
        for (uint256 i = 0; i < 2; i++) {
            if (address(tokens[i]) == _baseToken) {
                payable(address(to)).transfer(amount);
            } else {
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
    ) external returns (uint[] memory amounts)
    {
        // mimic swap
        uint[] memory amounts = new uint[](1);
        amounts[0] = uint(swap(to, amountIn));
        return amounts;
    }
    function swapExactETHForTokens(uint amountIn, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts)
    {
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
    ) external returns (uint[] memory amounts)
    {
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
    function rateByPath(
        address[] memory _path,
        uint256 _amount
    ) external view returns (uint256) {
        return _amount;
    }

    /**
     * Bancor V2
     */
    function conversionPath(Token sourceToken, Token targetToken)
    external
    view
    returns (address[] memory)
    {
        address[] memory path = new address[](3);
        path[0] = address(sourceToken);
        path[1] = address(0);
        path[2] = address(targetToken);

        return path;
    }

    //solhint-disable-next-line func-name-mixedcase
    function WETH() external view returns (address) {
        return address(_baseToken);
    }

    receive() external payable {}

    function setTokens(Token _token0, Token _token1) external {
        token0 = _token0;
        token1 = _token1;

    }

//    function nextRoute() external {
//        routeNumber = routeNumber + 1;
//        if (routeNumber == 1) {
//            token0 = route1;
//            token1 = route2;
//        } else if (routeNumber == 2) {
//            route0 = token1;
//            route1 = token0;
//        }
//    }
}
