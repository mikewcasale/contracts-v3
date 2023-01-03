// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IUniswapV2Pair } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";
import { IVersioned } from "../utility/interfaces/IVersioned.sol";
import { Upgradeable } from "../utility/Upgradeable.sol";
import { Utils } from "../utility/Utils.sol";

import { IBancorNetwork } from "../network/interfaces/IBancorNetwork.sol";
import { INetworkSettings } from "../network/interfaces/INetworkSettings.sol";
import { IPoolToken } from "../pools/interfaces/IPoolToken.sol";

import { IBancorArbitrage, TradeParams} from "./interfaces/IBancorArbitrage.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "../../../arb_bot/contracts/exchanges/interfaces/IAbstractBaseExchange.sol";

error InvalidTokenFirst();
error InvalidTokenLast();


/**
 * @dev one click liquidity migration between other DEXes into Bancor v3
 */
contract BancorArbitrage is IBancorArbitrage, ReentrancyGuardUpgradeable, Utils, Upgradeable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IPoolToken;
    using TokenLibrary for Token;
    using Address for address payable;
    uint256[2] memory profits;

    // using 'seconds' for convenience, for mainnet pass deadline from frontend!
    uint256 deadline = block.timestamp + 15;

    uint32 private constant MAX_DEADLINE = 10800;

    // the network contract
    IBancorNetwork private immutable _network;

    // the network settings contract
    INetworkSettings private immutable _networkSettings;

    // the bnt contract
    IERC20 private immutable _bnt;

    // Uniswap v2 router contract
    IUniswapV2Router02 private immutable _uniswapV2Router;

    // Uniswap v2 factory contract
    IUniswapV2Factory private immutable _uniswapV2Factory;

    // SushiSwap router contract
    IUniswapV2Router02 private immutable _sushiSwapRouter;

    // SushiSwap factory contract
    IUniswapV2Factory private immutable _sushiSwapFactory;

    // WETH9 contract
    IERC20 private immutable _weth;

    // upgrade forward-compatibility storage gap
    uint256[MAX_GAP - 0] private __gap;

    /**
     * @dev triggered after a successful Uniswap V2 Arbitrage Closed
     */
    event UniswapV2ArbClosed(
        address indexed caller,
        IUniswapV2Pair poolToken,
        Token indexed sourceToken,
        Token indexed targetToken,
        uint256 sourceTokenAmt,
        uint256 targetTokenAmt,
        bool depositedA,
        bool depositedB
    );

    error UnsupportedTokens();
    error NoPairForTokens();

    /**
     * @dev a "virtual" constructor that is only used to set immutable state variables
     */
    constructor(
        IBancorNetwork initNetwork,
        INetworkSettings initNetworkSettings,
        IERC20 initBnt,
        IUniswapV3Factory initUniswapV3Factory,
        IUniswapV2Router02 initUniswapV2Router,
        IUniswapV2Factory initUniswapV2Factory,
        IUniswapV2Router02 initSushiSwapRouter,
        IUniswapV2Factory initSushiSwapFactory
    )
        validAddress(address(initNetwork))
        validAddress(address(initNetworkSettings))
        validAddress(address(initBnt))
        validAddress(address(initUniswapV3Factory))
        validAddress(address(initUniswapV2Router))
        validAddress(address(initUniswapV2Factory))
        validAddress(address(initSushiSwapRouter))
        validAddress(address(initSushiSwapFactory))
    {
        _network = initNetwork;
        _networkSettings = initNetworkSettings;
        _bnt = initBnt;
        _uniswapV3Factory = initUniswapV3Factory;
        _uniswapV2Router = initUniswapV2Router;
        _uniswapV2Factory = initUniswapV2Factory;
        _sushiSwapRouter = initSushiSwapRouter;
        _sushiSwapFactory = initSushiSwapFactory;
        _weth = IERC20(initUniswapV2Router.WETH());
    }

    /**
     * @inheritdoc Upgradeable
     */
    function version() public pure override(IVersioned, Upgradeable) returns (uint16) {
        return 1;
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
     * @inheritdoc IBancorArbitrage
     */
    function tradeUniswapV2(
        Token sourceToken,
        Token targetToken,
        uint256 sourceTokenAmount
    )
        external
        nonReentrant
        validAddress(address(sourceToken))
        validAddress(address(targetToken))
        greaterThanZero(sourceTokenAmount)
        returns (uint256 targetTokenAmount)
    {
        uint256 res = _tradeUniswapV2(
            _uniswapV2Router,
            _uniswapV2Factory,
            sourceToken,
            targetToken,
            sourceTokenAmount
        );

        return res;
    }

    /**
     * @dev trades on Uniswap V2
     */
    function _tradeUniswapV2(
        IUniswapV2Router02 router,
        IUniswapV2Factory factory,
        Token sourceToken,
        Token targetToken,
        uint256 sourceTokenAmount,
        address caller
    ) private returns (uint256 targetTokenAmount) {

        uint24 fee = 3000;
        address recipient = address(this);
        uint160 sqrtPriceLimitX96 = 0;

        // arrange tokens in an array, replace WETH with the native token
        Token[2] memory tokens = [
            _isWETH(sourceToken) ? TokenLibrary.NATIVE_TOKEN : sourceToken,
            _isWETH(targetToken) ? TokenLibrary.NATIVE_TOKEN : targetToken
        ];

        // get Uniswap's pair
        IUniswapV2Pair pair = _getUniswapV2Pair(factory, tokens);
        if (address(pair) == address(0)) {
            revert NoPairForTokens();
        }

        // transfer the tokens from the caller
        Token(address(pair)).safeTransferFrom(caller, address(this), sourceTokenAmount);

        // save states
        uint256[2] memory previousBalances = [tokens[0].balanceOf(address(this)), tokens[1].balanceOf(address(this))];

        // look for relevant whitelisted pools, revert if there are none
        bool[2] memory whitelist;
        for (uint256 i = 0; i < 2; i++) {
            Token token = tokens[i];
            whitelist[i] = token.isEqual(_bnt) || _networkSettings.isTokenWhitelisted(token);
        }
        if (!whitelist[0] && !whitelist[1]) {
            revert UnsupportedTokens();
        }

        // trade on UniswapV2
        _uniV2Swap(router, pair, tokens, sourceTokenAmount, fee, recipient, sqrtPriceLimitX96);

        // calculate the amount of target tokens received
        uint256 targetTokenAmount = tokens[1].balanceOf(address(this)) - previousBalances[1];
        return targetTokenAmount;
    }


    /**
     * @dev removes liquidity from Uniswap's pair, transfer funds to self
     */
    function _uniV2Swap(
        IUniswapV2Router02 router,
        IUniswapV2Pair pair,
        Token[2] memory tokens,
        uint256 sourceTokenAmount,
        uint24 fee,
        address recipient,
        uint160 sqrtPriceLimitX96
    ) private {
        IERC20(address(pair)).safeApprove(address(router), sourceTokenAmount);
        uint256 deadline = block.timestamp + MAX_DEADLINE;

        if (tokens[0].isNative()) {
            router.swapExactETHForTokens(sourceTokenAmount, 0, address(pair), recipient, deadline);
        } else if (tokens[1].isNative()) {
            router.swapExactTokensForETH(sourceTokenAmount, 0, address(pair), recipient, deadline);
        } else {
            router.swapExactTokensForTokens(sourceTokenAmount, 0, address(pair), recipient, deadline);
        }
    }

    /**
     * @dev transfer given amount of given token to the caller
     */
    function _transferToCaller(
        Token token,
        uint256 amount,
        address caller
    ) private {
        if (token.isNative()) {
            payable(caller).sendValue(amount);
        } else {
            token.toIERC20().safeTransfer(caller, amount);
        }
    }

    /**
     * @dev fetches a UniswapV2 pair
     */
    function _getUniswapV2Pair(IUniswapV2Factory factory, Token[2] memory tokens)
        private
        view
        returns (IUniswapV2Pair)
    {
        // Uniswap does not support ETH input, transform to WETH if necessary
        address sourceTokenAddress = tokens[0].isNative() ? address(_weth) : address(tokens[0]);
        address targetTokenAddress = tokens[1].isNative() ? address(_weth) : address(tokens[1]);

        address pairAddress = factory.getPair(sourceTokenAddress, targetTokenAddress);
        return IUniswapV2Pair(pairAddress);
    }

    /**
     * @dev returns true if given token is WETH
     */
    function _isWETH(Token token) private view returns (bool) {
        return address(token) == address(_weth);
    }

    /**
     * @dev executes the arbitrage trade
     */
    function execute(tradeParams[] memory _trades) external payable returns (uint256) {

        bool isFirstValid = _trades[0].sourceToken.isEqual(_bnt);
        require(isFirstValid, "First trade source token must be BNT");

        bool isLastValid = _trades[_trades.length - 1].targetToken.isEqual(_bnt);
        require(isLastValid, "Last trade target token must be BNT");

        // perform the trades
        for (uint i=0; i< _trades.length; i++) {
            Token sourceToken = _trades[i].sourceToken;
            Token targetToken = _trades[i].targetToken;
            uint256 sourceAmount = _trades[i].sourceAmount;
            uint256 minReturnAmount = _trades[i].minReturnAmount;
            uint256 deadline = _trades[i].deadline;
            uint exchangeId = _trades[i].exchangeId;

            if (exchangeId == 0) {
                uint256 res = tradeBancorV3(sourceToken, targetToken, sourceAmount, minReturnAmount, deadline, address(this));
            } else if (exchangeId == 1) {
                uint256 res = tradeSushiSwap(sourceToken, targetToken, sourceAmount, minReturnAmount, deadline, address(this));
            } else if (exchangeId == 2) {
                uint256 res = tradeUniswapV2(sourceToken, targetToken, sourceAmount, minReturnAmount, deadline, address(this));
            } else if (exchangeId == 3) {
                uint256 res = tradeUniswapV3(sourceToken, targetToken, sourceAmount, minReturnAmount, deadline, address(this));
            } else {
                revert("invalid exchangeId");
            }

            if (i == _trades.length - 1) {
                uint256 profit = res - _trades[0].sourceAmount;
                _transferToCaller(targetToken, res, msg.sender);
            }
        }
        return profit;
    }
}
