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

import { IBancorNetwork, IFlashLoanRecipient } from "../network/interfaces/IBancorNetwork.sol";
import { INetworkSettings } from "../network/interfaces/INetworkSettings.sol";
import { IPoolToken } from "../pools/interfaces/IPoolToken.sol";

import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import { IBNTPool } from "../pools/interfaces/IBNTPool.sol";

error InvalidTokenFirst();
error InvalidTokenLast();

struct tradeParams {
    Token sourceToken;
    Token targetToken;
    uint256 sourceAmount;
    uint256 minReturnAmount;
    uint256 deadline;
    uint exchangeId;
}

struct ArbitrageSettings {
    // the percentage of arbitrage profits to be sent to the initiator of the arbitrage event (in units of PPM)
    uint32 arbitrageProfitPercentagePPM;
    // the maximum arbitrage profit to be sent to the initiator of the arbitrage event
    uint256 arbitrageProfitMaxAmount;
}

interface IUniswapV3Router is ISwapRouter {
    function refundETH() external payable;
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

    uint32 private constant MAX_DEADLINE = 10000;

    // the network contract
    IBancorNetwork private immutable _network;

    // the network settings contract
    INetworkSettings private immutable _networkSettings;

    // the settings for the ArbitrageProfits
    ArbitrageSettings private _arbitrageSettings;

    // the bnt contract
    IERC20 private immutable _bnt;

    // the BNT pool contract
    IBNTPool internal _bntPool;

    // Uniswap v2 router contract
    IUniswapV2Router02 private immutable _uniswapV2Router;

    // Uniswap v2 factory contract
    IUniswapV2Factory private immutable _uniswapV2Factory;

    // Uniswap v3 factory contract
    ISwapRouter private immutable _uniswapV3Router;

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
    event ArbitrageExecuted(
        address indexed caller,
        Token indexed sourceToken,
        Token indexed targetToken,
        uint256 sourceTokenAmount,
        uint256 callerProfit,
        uint256 burnAmount,
        uint256 profit,
        uint256 arbitrageProfitPercentagePPM,
        uint256 arbitrageProfitMaxAmount
    );

    /**
     * @dev triggered when the settings of the contract are updated
     */
    event ArbitrageSettingsUpdated(
        uint32 prevProfitPercentagePPM,
        uint32 newProfitPercentagePPM,
        uint256 prevProfitMaxAmount,
        uint256 newProfitMaxAmount
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
        ISwapRouter initUniswapV3Router,
        IUniswapV2Router02 initUniswapV2Router,
        IUniswapV2Factory initUniswapV2Factory,
        IUniswapV2Router02 initSushiSwapRouter,
        IUniswapV2Factory initSushiSwapFactory
    )
        validAddress(address(initNetwork))
        validAddress(address(initNetworkSettings))
        validAddress(address(initBnt))
        validAddress(address(initUniswapV3Router))
        validAddress(address(initUniswapV2Router))
        validAddress(address(initUniswapV2Factory))
        validAddress(address(initSushiSwapRouter))
        validAddress(address(initSushiSwapFactory))
    {
        _network = initNetwork;
        _networkSettings = initNetworkSettings;
        _bnt = initBnt;
        _uniswapV3Router = initUniswapV3Router;
        _uniswapV2Router = initUniswapV2Router;
        _uniswapV2Factory = initUniswapV2Factory;
        _sushiSwapRouter = initSushiSwapRouter;
        _sushiSwapFactory = initSushiSwapFactory;
        _weth = IERC20(initUniswapV2Router.WETH());
        _arbitrageSettings = ArbitrageSettings({
            arbitrageProfitPercentagePPM: 10,
            arbitrageProfitMaxAmount: 100
        });
    }

    /**
     * @inheritdoc Upgradeable
     */
    function version() public pure override(Upgradeable) returns (uint16) {
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
     * @dev gets the arbitrage settings
     */
    function getSettings() external view returns (ArbitrageSettings memory) {
        return _arbitrageSettings;
    }

    /**
     * @dev sets the settings of the ArbitrageTrade contract
     *
     * requirements:
     *s
     * - the caller must be the admin of the contract
     */
    function setArbitrageSettings(
        ArbitrageSettings calldata settings
    )
    external
    onlyAdmin
    validFee(settings.arbitrageProfitPercentagePPM)
    greaterThanZero(settings.arbitrageProfitMaxAmount)
    {
        uint32 prevArbitrageProfitPercentagePPM = _arbitrageSettings.arbitrageProfitPercentagePPM;
        uint256 prevArbitrageProfitMaxAmount = _arbitrageSettings.arbitrageProfitMaxAmount;

        if (
            prevArbitrageProfitPercentagePPM == settings.arbitrageProfitPercentagePPM &&
            prevArbitrageProfitMaxAmount == settings.arbitrageProfitMaxAmount
        ) {
            return;
        }

        _arbitrageSettings = settings;

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
    function takeFlashLoan(uint256 _amount) private {
        _network.flashLoan(Token(address(_bnt)), _amount, IFlashLoanRecipient(address(this)), "0x");
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
    )
        private
        returns (uint256)
    {
        return _network.tradeBySourceAmount(
            sourceToken,
            targetToken,
            sourceTokenAmount,
            minTargetTokenAmount,
            deadline,
            address(this)
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
    )
        private
        returns (uint256)
    {
        uint24 fee = 3000;
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
    )
        private
        returns (uint256)
    {
        address[] memory path = new address[](2);
        path[0] = address(sourceToken);
        path[1] = address(targetToken);

        uint[] memory amounts = router.swapExactTokensForTokens(
            sourceTokenAmount,
            minTargetTokenAmount,
            path,
            address(this),
            deadline
        );

        uint256 res = amounts[1];
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

        // calculate the amount of target tokens received
        uint256 targetTokenAmount = tokens[1].balanceOf(address(this)) - previousBalances[1];
        return targetTokenAmount;
    }


    /**
     * @dev transfer given amount of given token to the caller
     */
    function _transferToCaller(Token token, uint256 amount, address caller) private {
        if (token.isNative()) {
            payable(caller).sendValue(amount);
        } else {
            token.toIERC20().safeTransfer(caller, amount);
        }
    }

    /**
     * @dev fetches a UniswapV2 pair
     */
    function _getUniswapV2Pair(
        IUniswapV2Factory factory,
        Token[2] memory tokens
    ) private view returns (IUniswapV2Pair) {
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
    function execute(tradeParams[] memory _trades, ArbitrageSettings memory settings) external payable {

        // get the settings for the current transaction
        uint256 burnAmount = 0;
        uint256 totalProfit = 0;
        uint256 res = 0;
        uint256 callerProfit = 0;

        // check if the initial trade source token is BNT
        bool isFirstValid = _trades[0].sourceToken.isEqual(_bnt);
        require(isFirstValid, "First trade source token must be BNT");

        // check if the last trade target token is BNT
        bool isLastValid = _trades[_trades.length - 1].targetToken.isEqual(_bnt);
        require(isLastValid, "Last trade target token must be BNT");

        // perform the trades
        for (uint i = 0; i < _trades.length; i++) {

            // parse the trade params
            Token sourceToken = _trades[i].sourceToken;
            Token targetToken = _trades[i].targetToken;
            uint256 sourceAmount = _trades[i].sourceAmount;
            uint256 minReturnAmount = _trades[i].minReturnAmount;
            uint256 deadline = _trades[i].deadline;
            uint exchangeId = _trades[i].exchangeId;

            // route the trade to the correct exchange
            if (exchangeId == 0) {
                // Bancor V3
                res = _tradeBancorV3(
                    sourceToken,
                    targetToken,
                    sourceAmount,
                    0,
                    minReturnAmount,
                    deadline,
                    msg.sender
                );
            } else if (exchangeId == 1) {
                // SushiSwap
                res = _tradeSushiSwap(
                    _sushiSwapRouter,
                    sourceToken,
                    targetToken,
                    sourceAmount,
                    0,
                    minReturnAmount,
                    deadline
                );
            } else if (exchangeId == 2) {
                // Uniswap V2
                res = _tradeUniswapV2(
                    _uniswapV2Router,
                    _uniswapV2Factory,
                    sourceToken,
                    targetToken,
                    sourceAmount,
                    address(this)
                );
            } else if (exchangeId == 3) {
                // Uniswap V3
                res = _tradeUniswapV3(
                    _uniswapV3Router,
                    sourceToken,
                    targetToken,
                    sourceAmount,
                    0,
                    minReturnAmount,
                    deadline
                );
            } else {
                revert("invalid exchangeId");
            }

            // on the last trade, transfer the appropriate BNT profit to the caller and burn the rest
            if (i == _trades.length - 1) {

                // calculate the profit
                totalProfit = res - _trades[0].sourceAmount;

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
                _transferToCaller(Token(address(_bnt)), callerProfit, msg.sender);

                // burn the rest
                _bntPool.burnFromVault(burnAmount);
            }
        }

    // emit the event
    emit ArbitrageExecuted(
        msg.sender,
        _trades[1].sourceToken,
        _trades[1].targetToken,
        _trades[0].sourceAmount,
        callerProfit,
        burnAmount,
        totalProfit,
        settings.arbitrageProfitPercentagePPM,
        settings.arbitrageProfitMaxAmount
    );

    }
}
