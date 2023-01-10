import Contracts, {
    BancorNetworkInfo,
    BancorArbitrage,
    IERC20,
    MockBancorNetworkV2,
    MockBancorNetworkV3,
    MockExchanges,
    MockuniswapV2RouterFactory,
    MockuniswapV2RouterPair,
    MockuniswapV2RouterRouter02,
    MockuniswapV3RouterRouter,
    MockuniswapV3RouterPool,
    NetworkSettings,
    PoolToken,
    TestBancorNetwork,
    TestPoolCollection
} from '../../components/Contracts';
import { MAX_UINT256, ZERO_ADDRESS } from '../../utils/Constants';
import { NATIVE_TOKEN_ADDRESS, TokenData, TokenSymbol } from '../../utils/TokenData';
import { Addressable, toWei } from '../../utils/Types';
import {
    createProxy,
    createSystem,
    createTestToken,
    createToken,
    PoolSpec,
    setupFundedPool,
    TokenWithAddress
} from '../helpers/Factory';
import { shouldHaveGap } from '../helpers/Proxy';
import { getBalances, getTransactionCost, toAddress } from '../helpers/Utils';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { BigNumber, BigNumberish, ContractTransaction, utils } from 'ethers';
import { waffle, ethers } from 'hardhat';
const { deployMockContract, provider } = waffle;

const { formatBytes32String } = utils;

describe('BancorArbitrage', () => {
    interface ReserveTokenAndPoolTokenBundle {
        reserveToken: TokenWithAddress;
        poolToken?: PoolToken;
    }

    let network: TestBancorNetwork;
    let networkInfo: BancorNetworkInfo;
    let bnt: IERC20;
    let bntPoolToken: PoolToken;
    let networkSettings: NetworkSettings;
    let poolCollection: TestPoolCollection;
    let bancorArbitrage: BancorArbitrage;

    let deployer: SignerWithAddress;
    let user: SignerWithAddress;

    let exchanges: MockExchanges;
    let bancorV2: MockExchanges;
    let bancorV3: MockExchanges;
    let uniswapV2Router: MockExchanges;
    let uniswapV2Factory: MockExchanges;
    let uniswapV3Router: MockExchanges;
    let sushiSwap: MockExchanges;

    let baseToken: TokenWithAddress;

    const BNT_VIRTUAL_BALANCE = 1;
    const BASE_TOKEN_VIRTUAL_BALANCE = 2;
    const FUNDING_LIMIT = toWei(10_000_000);
    const CONTEXT_ID = formatBytes32String('CTX');
    const MIN_RETURN_AMOUNT = BigNumber.from(1);
    const DEFAULT_POOL_DEPTH = BigNumber.from(100000000);
    const MAX_SOURCE_AMOUNT = 100000000;
    const ARBITRAGE_PROFIT_PERCENTAGE_PPM = 10;
    const ARBITRAGE_PROFIT_MAX_AMOUNT = 100;
    const DEADLINE = MAX_UINT256;
    const GAS_LIMIT = 227440;
    const MIN_LIQUIDITY_FOR_TRADING = toWei(1000);

    type TradeParams = {
        sourceToken: Token;
        targetToken: Token;
        sourceAmount: uint256;
        minReturnAmount: uint256;
        deadline: uint256;
        exchangeId: uint256;
    };

    const AMOUNT = 1000;

    shouldHaveGap('BancorArbitrage');

    before(async () => {
        [deployer, user] = await ethers.getSigners();
    });

    beforeEach(async () => {
        ({ network, networkSettings, baseToken, bnt, poolCollection, networkInfo, bntPoolToken } = await createSystem());

        baseToken = await createTestToken();
        exchanges = bancorV2 = bancorV3 = uniswapV2Router = uniswapV2Factory = uniswapV3Router = sushiSwap = await Contracts.MockExchanges.deploy(
            100_000_000, baseToken.address, network.address
        );

        bancorArbitrage = await createProxy(Contracts.BancorArbitrage, {
            ctorArgs: [
                bancorV3.address,
                networkSettings.address,
                bnt.address,
                uniswapV3Router.address,
                uniswapV2Router.address,
                uniswapV2Factory.address,
                sushiSwap.address,
                bancorV2.address
            ]
        });

        await exchanges.transfer(user.address, 100_000_000);
    });

    describe('construction', () => {
        it('should revert when initializing with an invalid network contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    ZERO_ADDRESS,
                    networkSettings.address,
                    bnt.address,
                    uniswapV3Router.address,
                    uniswapV2Router.address,
                    uniswapV2Factory.address,
                    sushiSwap.address,
                    bancorV2.address
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should revert when initializing with an invalid networkSettings contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    bancorV3.address,
                    ZERO_ADDRESS,
                    bnt.address,
                    uniswapV3Router.address,
                    uniswapV2Router.address,
                    uniswapV2Factory.address,
                    sushiSwap.address,
                    bancorV2.address
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should revert when initializing with an invalid bnt contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    bancorV3.address,
                    networkSettings.address,
                    ZERO_ADDRESS,
                    uniswapV3Router.address,
                    uniswapV2Router.address,
                    uniswapV2Factory.address,
                    sushiSwap.address,
                    bancorV2.address
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should revert when initializing with an invalid uniswapV2RouterRouter contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    bancorV3.address,
                    networkSettings.address,
                    bnt.address,
                    ZERO_ADDRESS,
                    uniswapV2Router.address,
                    uniswapV2Factory.address,
                    sushiSwap.address,
                    bancorV2.address
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should revert when initializing with an invalid sushiSwapV2Router contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    bancorV3.address,
                    networkSettings.address,
                    bnt.address,
                    uniswapV3Router.address,
                    uniswapV2Router.address,
                    ZERO_ADDRESS,
                    sushiSwap.address,
                    bancorV2.address
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should revert when initializing with an invalid sushiSwapV2Factory contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    bancorV3.address,
                    networkSettings.address,
                    bnt.address,
                    uniswapV3Router.address,
                    uniswapV2Router.address,
                    uniswapV2Factory.address,
                    ZERO_ADDRESS,
                    bancorV2.address
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should revert when initializing with an invalid network contract', async () => {
            await expect(
                Contracts.BancorArbitrage.deploy(
                    bancorV3.address,
                    networkSettings.address,
                    bnt.address,
                    uniswapV3Router.address,
                    uniswapV2Router.address,
                    uniswapV2Factory.address,
                    sushiSwap.address,
                    ZERO_ADDRESS
                )
            ).to.be.revertedWithError('InvalidAddress');
        });

        it('should be initialized', async () => {
            expect(await bancorArbitrage.version()).to.equal(1);
        });

        it('should revert when attempting to reinitialize', async () => {
            await expect(bancorArbitrage.initialize()).to.be.revertedWithError(
                'Initializable: contract is already initialized'
            );
        });
    });

    describe('trades', () => {
        beforeEach(async () => {
            await exchanges.connect(user).approve(bancorArbitrage.address, MAX_SOURCE_AMOUNT);
        });

        it("should trade on Uniswap V3", async () => {
            const { poolToken: poolToken1, token: sourceToken } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: targetToken } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(sourceToken.address, targetToken.address);
            let exchangeId = 2;
            await testTrade(sourceToken, targetToken, exchangeId);
        });

        it("should trade on Bancor V2", async () => {
            const { poolToken: poolToken1, token: sourceToken } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: targetToken } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(sourceToken.address, targetToken.address);
            let exchangeId = 1;
            await testTrade(sourceToken, targetToken, exchangeId);
        });

        it("should trade on Bancor V3", async () => {
            const { poolToken: poolToken1, token: sourceToken } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: targetToken } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(sourceToken.address, targetToken.address);
            let exchangeId = 3;
            await testTrade(sourceToken, targetToken, exchangeId);
        });

        it("should trade on SushiSwap", async () => {
            const { poolToken: poolToken1, token: sourceToken } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: targetToken } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(sourceToken.address, targetToken.address);
            let exchangeId = 4;
            await testTrade(sourceToken, targetToken, exchangeId);
        });

        it("should revert when first trade source token is not BNT", async () => {
            const { poolToken: poolToken3, token: token3 } = await preparePoolAndToken(TokenSymbol.TKN);
            const { poolToken: poolToken1, token: token1 } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: token2 } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(token1.address, token2.address);

            let route0 = {
                sourceToken: token1,
                targetToken: token2,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 0,
            };
            let route1 = {
                sourceToken: token2,
                targetToken: token3,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 2,
            };
            let route2 = {
                sourceToken: token3,
                targetToken: token1,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 0,
            };
            let params = [
                route0,
                route1,
                route2
            ];
            await expect(testTradeMultiRoute(params)).to.be.revertedWithError('FirstTradeSourceMustBeBNT');
        });

        it("should revert when last trade target token is not BNT", async () => {
            const { poolToken: poolToken3, token: token3 } = await preparePoolAndToken(TokenSymbol.TKN);
            const { poolToken: poolToken1, token: token1 } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: token2 } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(token1.address, token2.address);

            let route0 = {
                sourceToken: bnt,
                targetToken: token2,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 0,
            };
            let route1 = {
                sourceToken: token2,
                targetToken: token3,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 2,
            };
            let route2 = {
                sourceToken: token3,
                targetToken: token1,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 0,
            };
            let params = [
                route0,
                route1,
                route2
            ];
            await expect(testTradeMultiRoute(params)).to.be.revertedWithError('LastTradeTargetMustBeBNT');
        });

        it("should trade", async () => {
            const { poolToken: poolToken1, token: token1 } = await preparePoolAndToken(TokenSymbol.TKN1);
            const { poolToken: poolToken2, token: token2 } = await preparePoolAndToken(TokenSymbol.TKN2);
            await exchanges.setTokens(bnt.address, token1.address);

            let route0 = {
                sourceToken: bnt,
                targetToken: token1,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 0,
            };
            let route1 = {
                sourceToken: token1,
                targetToken: token2,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 4,
            };
            let route2 = {
                sourceToken: token2,
                targetToken: bnt,
                sourceAmount: AMOUNT,
                minReturnAmount: 0,
                deadline: 0,
                exchangeId: 0,
            };
            let params = [
                route0,
                route1,
                route2
            ];
            await testTradeMultiRoute(params)
        });

    });

    const getPoolTokenBalances = async (
        poolToken1?: PoolToken,
        poolToken2?: PoolToken
    ): Promise<Record<string, BigNumber>> => {
        const balances: Record<string, BigNumber> = {};
        for (const t of [poolToken1, poolToken2]) {
            if (t) {
                balances[t.address] = await t.balanceOf(user.address);
            }
        }
        return balances;
    };

    const getStakedBalances = async (
        token1: TokenWithAddress,
        token2: TokenWithAddress
    ): Promise<Record<string, BigNumber>> => {
        const balances: { [address: string]: BigNumber } = {};
        for (const t of [token1, token2]) {
            if (isBNT(t)) {
                continue;
            }

            balances[t.address] = (await poolCollection.poolData(t.address)).liquidity[2];
        }
        return balances;
    };

    const getWhitelist = async (
        token1: TokenWithAddress,
        token2: TokenWithAddress
    ): Promise<Record<string, boolean>> => {
        return {
            [token1.address]: isBNT(token1) || (await networkSettings.isTokenWhitelisted(token1.address)),
            [token2.address]: isBNT(token2) || (await networkSettings.isTokenWhitelisted(token2.address))
        };
    };

    const preparePoolAndToken = async (symbol: TokenSymbol) => {
        const balance = toWei(100_000_000);
        const { poolToken, token } = await setupFundedPool(
            {
                tokenData: new TokenData(symbol),
                balance,
                requestedFunding: balance.mul(1000),
                bntVirtualBalance: BNT_VIRTUAL_BALANCE,
                baseTokenVirtualBalance: BASE_TOKEN_VIRTUAL_BALANCE
            },
            deployer as any as SignerWithAddress,
            network,
            networkInfo,
            networkSettings,
            poolCollection
        );

        return { poolToken, token };
    };

    const isNativeToken = (token: TokenWithAddress): boolean => {
        return token.address === NATIVE_TOKEN_ADDRESS;
    };

    const isBNT = (token: TokenWithAddress): boolean => {
        return token.address === bnt.address;
    };

    const testTrade = async (token1: TokenWithAddress, token2: TokenWithAddress, exchangeId: number) => {

        // prepare Uniswap mocks
        await transfer(deployer, token1, exchanges.address, AMOUNT + GAS_LIMIT);
        await transfer(deployer, token2, exchanges.address, AMOUNT + GAS_LIMIT);

        // save state
        const previousBalances = await getBalances([token1, token2], bancorArbitrage.address);

        // execute
        if (exchangeId == 1)
        {
            // execute BancorV2 trade
            const res = await bancorArbitrage.connect(user).tradeBancorV2(
                token1.address,
                token2.address,
                AMOUNT,
                MIN_RETURN_AMOUNT,
                {
                    gasLimit: GAS_LIMIT
                }
            );
        }
        else if (exchangeId == 2)
        {
            // execute uniswapV3Router trade
            const res = await bancorArbitrage.connect(user).tradeUniswapV3(
                token1.address,
                token2.address,
                AMOUNT,
                MIN_RETURN_AMOUNT,
                MIN_RETURN_AMOUNT,
                DEADLINE,
                {
                    gasLimit: GAS_LIMIT
                }
            );
        }
        else if (exchangeId == 3)
        {
            // execute BancorV3 trade
            const res = await bancorArbitrage.connect(user).tradeBancorV3(
                token1.address,
                token2.address,
                AMOUNT,
                MIN_RETURN_AMOUNT,
                MIN_RETURN_AMOUNT,
                DEADLINE,
                {
                    gasLimit: GAS_LIMIT
                }
            );
        }
        else if (exchangeId == 4)
            {
                // execute Sushi trade
                const res = await bancorArbitrage.connect(user).tradeSushiSwap(
                    token1.address,
                    token2.address,
                    AMOUNT,
                    MIN_RETURN_AMOUNT,
                    MIN_RETURN_AMOUNT,
                    DEADLINE,
                    {
                        gasLimit: GAS_LIMIT
                    }
                );
            }

        // assert
        const newBalances = await getBalances([token1, token2], bancorArbitrage.address);

        expect(newBalances[token1.address].eq(previousBalances[token1.address].add(AMOUNT))).to.be.true;
    };

    const testTradeMultiRoute = async (routes) => {
        let allBalances = 0;

        for (let i = 0; i < routes.length; i++)
        {
            let route = routes[i];
            await transfer(deployer, route.sourceToken, exchanges.address, route.sourceAmount + GAS_LIMIT);
            await transfer(deployer, route.targetToken, exchanges.address, route.sourceAmount + GAS_LIMIT);
            await bancorArbitrage.connect(user).addRoute(route.sourceToken.address, route.targetToken.address, route.sourceAmount, route.minReturnAmount, route.deadline, route.exchangeId);
            allBalances += route.sourceAmount;
        }

        // save state
        const token1 = routes[0].sourceToken;
        const previousBalances = await getBalances([token1], exchanges.address);
        const userBalances1 = await getBalances([token1], user.address);
        console.log("userBalances1: " + userBalances1[token1.address].toString());

        const res = await bancorArbitrage.connect(user).execute(
            {
                gasLimit: GAS_LIMIT * 2
            }
        );

        // assert
        const newBalances = await getBalances([token1], exchanges.address);
        const userBalances2 = await getBalances([token1], user.address);
        console.log("userBalances2: " + userBalances2[token1.address].toString());
        expect(newBalances[token1.address].eq(previousBalances[token1.address].sub(allBalances))).to.be.true;

    };

    const transfer = async (
        sourceAccount: SignerWithAddress,
        token: TokenWithAddress,
        target: string | Addressable,
        amount: BigNumberish
    ) => {
        const targetAddress = toAddress(target);
        const tokenAddress = token.address;
        if ([NATIVE_TOKEN_ADDRESS, baseToken.address].includes(tokenAddress)) {
            return sourceAccount.sendTransaction({ to: targetAddress, value: amount });
        }

        return (await Contracts.TestERC20Token.attach(tokenAddress))
            .connect(sourceAccount)
            .transfer(targetAddress, amount);
    };
});
