// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IUniswapV2Pair } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IWETH } from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import { TransferHelper } from "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "hardhat/console.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";
import { IVersioned } from "../utility/interfaces/IVersioned.sol";
import { Upgradeable } from "../utility/Upgradeable.sol";
import { Utils } from "../utility/Utils.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../network/interfaces/IBancorNetwork.sol";
import { INetworkSettings } from "../network/interfaces/INetworkSettings.sol";
import { IPoolToken } from "../pools/interfaces/IPoolToken.sol";
import { IBNTPool } from "../pools/interfaces/IBNTPool.sol";
import { PPM_RESOLUTION } from "../utility/Constants.sol";
import { MathEx } from "../utility/MathEx.sol";

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
    error InvalidRouteLength();
    error InvalidInitialAndFinalTokens();
    error InvalidFlashLoanCaller();

    // Defines the trade parameters.
    struct Route {
        Token sourceToken;
        Token targetToken;
        uint256 minTargetAmount;
        uint256 exchangeId;
        address customAddress;
        uint256 deadline;
    }

    // Defines the contract rewards configurable parameters.
    struct Rewards {
        uint32 percentagePPM;
        uint256 maxAmount;
    }

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

    // SushiSwap router contract
    IUniswapV2Router02 internal immutable _sushiSwapRouter;

    // Uniswap v3 factory contract
    ISwapRouter internal immutable _uniswapV3Router;

    // the Bancor v2 network contract
    IBancorNetworkV2 internal immutable _bancorNetworkV2;

    // WETH9 contract
    IERC20 internal immutable _weth;

    // the settings for the ArbitrageRewards
    Rewards internal _rewards;

    // upgrade forward-compatibility storage gap
    uint256[MAX_GAP] private __gap;

    // the maximum number of trade routes supported
    uint256 private constant MAX_ROUTE_LENGTH = 10;

    // mock profit amount for testing
    uint256 internal constant TEST_PROFIT = 100;

    /**
     * @dev triggered after a successful Arbitrage Executed
     */
    event ArbitrageExecuted(
        address caller,
        address sourceToken,
        address targetToken,
        uint256 sourceAmount,
        uint256 totalRewards,
        uint256 callerRewards,
        uint256 burnAmount
    );

    /**
     * @dev triggered when the settings of the contract are updated
     */
    event RewardsUpdated(
        uint32 prevPercentagePPM,
        uint32 newPercentagePPM,
        uint256 prevMaxAmount,
        uint256 newMaxAmount
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
        IBancorNetworkV2 initBancorNetworkV2,
        IUniswapV2Router02 initSushiSwapRouter
    )
        validAddress(address(initNetwork))
        validAddress(address(initNetworkSettings))
        validAddress(address(initBnt))
        validAddress(address(initUniswapV3Router))
        validAddress(address(initUniswapV2Router))
        validAddress(address(initUniswapV2Factory))
        validAddress(address(initBancorNetworkV2))
        validAddress(address(initSushiSwapRouter))
    {
        _bancorNetworkV3 = initNetwork;
        _networkSettings = initNetworkSettings;
        _bnt = initBnt;
        _uniswapV3Router = initUniswapV3Router;
        _uniswapV2Router = initUniswapV2Router;
        _uniswapV2Factory = initUniswapV2Factory;
        _bancorNetworkV2 = initBancorNetworkV2;
        _sushiSwapRouter = initSushiSwapRouter;
        _weth = IERC20(initUniswapV2Router.WETH());
        _rewards = Rewards({ percentagePPM: 30000, maxAmount: 100 });
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
     * @dev checks whether the specified number of routes is supported
     */
    modifier validRouteLength(Route[] memory routes) {
        // validate inputs
        _validRouteLength(routes);

        _;
    }

    function _validRouteLength(Route[] memory routes) internal pure {
        if (routes.length > MAX_ROUTE_LENGTH) {
            revert InvalidRouteLength();
        }
    }

    /**
     * @dev returns true if given token is WETH
     */
    function _isWETH(Token token) internal view returns (bool) {
        return address(token) == address(_weth);
    }

    /**
     * @dev sets the rewards parameters
     *
     * requirements:
     *
     * - the caller must be the admin of the contract
     */
    function setRewards(
        Rewards calldata settings
    ) external onlyAdmin validFee(settings.percentagePPM) greaterThanZero(settings.maxAmount) {
        uint32 prevPercentagePPM = _rewards.percentagePPM;
        uint256 prevMaxAmount = _rewards.maxAmount;

        // return if the settings are the same
        if (prevPercentagePPM == settings.percentagePPM && prevMaxAmount == settings.maxAmount) {
            return;
        }

        // update the settings
        _rewards = settings;

        // emit event
        emit RewardsUpdated({
            prevPercentagePPM: prevPercentagePPM,
            newPercentagePPM: settings.percentagePPM,
            prevMaxAmount: prevMaxAmount,
            newMaxAmount: settings.maxAmount
        });
    }

    /**
     * @dev returns the rewards settings
     */
    function getRewards() external view returns (Rewards memory) {
        return _rewards;
    }

    /**
     * @dev encodes the trade data for bancor V3 flashloan
     */
    function encodeFlashloan(
        Route[] memory routes,
        uint256 sourceAmount,
        address trader
    ) internal pure returns (bytes memory) {
        return abi.encode(routes, sourceAmount, trader);
    }

    /**
     * @dev decodes the trade data for bancor V3 flashloan
     */
    function decodeFlashloan(
        bytes memory data
    ) internal pure returns (Route[] memory routes, uint256 sourceAmount, address trader) {
        return abi.decode(data, (Route[], uint256, address));
    }

    /**
     * @dev callback function for bancor V3 flashloan
     */
    function onFlashLoan(
        address caller,
        IERC20 erc20Token,
        uint256 amount,
        uint256 feeAmount,
        bytes memory data
    ) external {
        Token token = Token(address(erc20Token));
        uint256 previousBalance;

        // validate inputs
        if (msg.sender != address(_bancorNetworkV3)) {
            revert InvalidFlashLoanCaller();
        } else if (caller != address(this)) {
            revert InvalidFlashLoanCaller();
        }

        // decode the data
        (Route[] memory routes, uint256 targetAmount, address trader) = decodeFlashloan(data);

        // perform the trade routes
        for (uint i = 0; i < routes.length; i++) {
            // save states
            previousBalance = routes[i].targetToken.balanceOf(address(this));

            // perform the trade
            _trade(
                routes[i].sourceToken,
                routes[i].targetToken,
                targetAmount,
                routes[i].minTargetAmount,
                routes[i].deadline,
                routes[i].exchangeId,
                routes[i].customAddress
            );

            // calculate the amount of target tokens received
            targetAmount = routes[i].targetToken.balanceOf(address(this)) - previousBalance;
        }

        // return the flashloan
        token.safeTransfer(msg.sender, amount + feeAmount);

        // allocate the Rewards
        allocateRewards(routes, targetAmount, trader, amount + feeAmount);
    }

    /**
     * @dev handles the trade logic per route
     */
    function _trade(
        Token sourceToken,
        Token targetToken,
        uint256 targetAmount,
        uint256 minTargetAmount,
        uint256 deadline,
        uint256 exchangeId,
        address customAddress
    ) private {
        // perform the trade
        if (exchangeId == 0) {
            // Bancor v3
            sourceToken.safeApprove(address(_bancorNetworkV3), targetAmount);

            // perform the trade
            _bancorNetworkV3.tradeBySourceAmount(
                sourceToken,
                targetToken,
                targetAmount,
                minTargetAmount,
                deadline,
                address(0x0)
            );
        } else if (exchangeId == 1) {
            // Bancor v2
            sourceToken.safeApprove(address(_bancorNetworkV2), targetAmount);

            // build the path
            address[] memory path = new address[](3);
            path[0] = address(sourceToken);
            path[1] = address(customAddress);
            path[2] = address(targetToken);

            // perform the trade
            _bancorNetworkV2.convertByPath{ value: msg.value }(
                path,
                targetAmount,
                minTargetAmount,
                address(this),
                address(this),
                0
            );
        } else if (exchangeId == 2 || exchangeId == 3) {
            // Uniswap V2 or Sushiswap
            IUniswapV2Router02 router = exchangeId == 2 ? _sushiSwapRouter : _uniswapV2Router;

            // approve the router to spend the source token
            sourceToken.safeApprove(address(router), targetAmount);

            // build the path
            address[] memory path = new address[](2);
            path[0] = address(sourceToken);
            path[1] = address(targetToken);

            // perform the trade
            if (sourceToken.isNative()) {
                router.swapExactETHForTokens{ value: targetAmount }(targetAmount, path, address(this), deadline);
            } else if (targetToken.isNative()) {
                router.swapExactTokensForETH(targetAmount, minTargetAmount, path, address(this), deadline);
            } else {
                router.swapExactTokensForTokens(targetAmount, minTargetAmount, path, address(this), deadline);
            }
        } else if (exchangeId == 4) {
            // Uniswap V3
            sourceToken.safeApprove(address(_uniswapV3Router), targetAmount);

            // build the params
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(sourceToken),
                tokenOut: address(targetToken),
                fee: 0,
                recipient: address(this),
                deadline: deadline,
                amountIn: targetAmount,
                amountOutMinimum: minTargetAmount,
                sqrtPriceLimitX96: 0
            });

            // perform the trade
            _uniswapV3Router.exactInputSingle(params);
        } else {
            revert InvalidExchangeId();
        }
    }

    /**
     * @dev execute multi-step arbitrage trade between Banroutesher exchange
     */
    function execute(
        Route[] memory routes,
        uint256 sourceAmount
    )
        public
        payable
        // validate the number of trade routes
        validRouteLength(routes)
        // enforce the initial sourceAmount to be greater than the minimum
        greaterThanZero(sourceAmount)
    {
        if (
            (address(routes[0].sourceToken) != address(routes[routes.length - 1].targetToken)) ||
            (address(routes[routes.length - 1].targetToken) != address(_bnt))
        ) {
            revert InvalidInitialAndFinalTokens();
        }

        // take a flashloan for the source amount on Bancor V3
        _bancorNetworkV3.flashLoan(
            Token(address(_bnt)),
            sourceAmount,
            IFlashLoanRecipient(address(this)),
            encodeFlashloan(routes, sourceAmount, msg.sender)
        );
    }

    /**
     * @dev Allocates the Rewards to the caller and burns the rest
     */
    function allocateRewards(
        Route[] memory routes,
        uint256 targetAmount,
        address caller,
        uint256 sourceAmount
    ) internal {
        Rewards memory settings = _rewards;

        uint256 burnAmount = 0;
        Token sourceToken = routes[0].sourceToken;

        // add the profits for testing
        targetAmount += TEST_PROFIT;

        // calculate the Rewards
        uint256 totalRewards = targetAmount - sourceAmount;

        // calculate the proportion of the Rewards to send to the caller
        uint256 callerRewards = MathEx.mulDivF(totalRewards, settings.percentagePPM, PPM_RESOLUTION);

        // calculate the proportion of the Rewards to burn
        if (callerRewards > settings.maxAmount) {
            callerRewards = settings.maxAmount;
            burnAmount = totalRewards - callerRewards;
        } else {
            burnAmount = totalRewards - callerRewards;
        }

        // transfer the appropriate Rewards to the caller
        uint remainingBalance = sourceToken.balanceOf(address(this));
        if (callerRewards < remainingBalance) {
            sourceToken.safeTransfer(caller, callerRewards);
            remainingBalance = sourceToken.balanceOf(address(this));
        }

        // burn the rest
        if (burnAmount < remainingBalance) {
            sourceToken.safeTransfer(address(_bnt), burnAmount);
        }

        //emit the Rewards event
        emit ArbitrageExecuted(
            caller,
            address(routes[0].sourceToken),
            address(routes[routes.length - 1].targetToken),
            sourceAmount,
            totalRewards,
            callerRewards,
            burnAmount
        );
    }
}
