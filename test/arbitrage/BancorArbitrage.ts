import Contracts, {
	BancorNetworkInfo,
	ERC20,
	MockExchanges,
	NetworkSettings,
	PoolToken,
	TestBancorArbitrage,
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
import { ethers, waffle } from 'hardhat';

const { deployMockContract, provider } = waffle;

const { formatBytes32String } = utils;

describe('BancorArbitrage', () => {
	interface ReserveTokenAndPoolTokenBundle {
		reserveToken: TokenWithAddress;
		poolToken?: PoolToken;
	}

	let network: TestBancorNetwork;
	let networkInfo: BancorNetworkInfo;
	let bnt: ERC20;
	let bntPoolToken: PoolToken;
	let networkSettings: NetworkSettings;
	let poolCollection: TestPoolCollection;
	let bancorArbitrage: TestBancorArbitrage;

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
		sourceToken: TokenWithAddress;
		targetToken: TokenWithAddress;
		sourceAmount: BigNumber;
		minReturnAmount: BigNumber;
		deadline: BigNumber;
		exchangeId: BigNumber;
	};

	const AMOUNT = 1000;

	shouldHaveGap('TestBancorArbitrage');

	before(async () => {
		[deployer, user] = await ethers.getSigners();
	});

	beforeEach(async () => {
		({ network, networkSettings, bnt, poolCollection, networkInfo, bntPoolToken } = await createSystem());

		baseToken = await createTestToken();
		exchanges =
			bancorV2 =
			bancorV3 =
			uniswapV2Router =
			uniswapV2Factory =
			uniswapV3Router =
			sushiSwap =
				await Contracts.MockExchanges.deploy(100_000_000, baseToken.address);

		bancorArbitrage = await createProxy(Contracts.TestBancorArbitrage, {
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

		await exchanges.transfer(exchanges.address, MAX_SOURCE_AMOUNT);
	});

	describe('construction', () => {
		it('should revert when initializing with an invalid network contract', async () => {
			await expect(
				Contracts.TestBancorArbitrage.deploy(
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
				Contracts.TestBancorArbitrage.deploy(
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
				Contracts.TestBancorArbitrage.deploy(
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
				Contracts.TestBancorArbitrage.deploy(
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
				Contracts.TestBancorArbitrage.deploy(
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
				Contracts.TestBancorArbitrage.deploy(
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
				Contracts.TestBancorArbitrage.deploy(
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

		let exchangeNames = ['BancorV3', 'SushiSwap', 'UniswapV2', 'UniswapV3', 'BancorV2'];
		let baseMsg = 'should trade on ';
		for (let i = 0; i < exchangeNames.length; i++) {
			let exchangeName = exchangeNames[i];
			let testMsg = baseMsg.concat(exchangeName.toString());

			it(testMsg, async () => {
				const { poolToken: poolToken1, token: sourceToken } = await preparePoolAndToken(TokenSymbol.TKN1);
				const { poolToken: poolToken2, token: targetToken } = await preparePoolAndToken(TokenSymbol.TKN2);
				await exchanges.setTokens(sourceToken.address, targetToken.address);
				await testTrade(sourceToken, targetToken, i);
			});
		}

		it('should revert when first trade source token is not BNT', async () => {
			const { poolToken: poolToken3, token: token3 } = await preparePoolAndToken(TokenSymbol.TKN);
			const { poolToken: poolToken1, token: token1 } = await preparePoolAndToken(TokenSymbol.TKN1);
			const { poolToken: poolToken2, token: token2 } = await preparePoolAndToken(TokenSymbol.TKN2);
			await exchanges.setTokens(token1.address, token2.address);

			const sourceToken1 = token1;
			const targetToken1 = token2;
			const sourceAmount1 = AMOUNT;
			const sourceToken2 = token2;
			const targetToken2 = token3;
			const sourceAmount2 = AMOUNT;
			const exchangeId2 = 2;
			const sourceToken3 = token3;
			const targetToken3 = token1;
			const sourceAmount3 = AMOUNT;
			const deadline = DEADLINE;

			await expect(
				testTradeMultiRoute(
					sourceToken1,
					targetToken1,
					sourceAmount1,
					sourceToken2,
					targetToken2,
					exchangeId2,
					sourceToken3,
					targetToken3,
					0,
					deadline
				)
			).to.be.revertedWithError('FirstTradeSourceMustBeBNT');
		});

		it('should revert when last trade target token is not BNT', async () => {
			const { poolToken: poolToken3, token: token3 } = await preparePoolAndToken(TokenSymbol.TKN);
			const { poolToken: poolToken1, token: token1 } = await preparePoolAndToken(TokenSymbol.TKN1);
			const { poolToken: poolToken2, token: token2 } = await preparePoolAndToken(TokenSymbol.TKN2);
			await exchanges.setTokens(token1.address, token2.address);

			const sourceToken1 = bnt;
			const targetToken1 = token2;
			const sourceAmount1 = AMOUNT;
			const sourceToken2 = token2;
			const targetToken2 = token3;
			const sourceAmount2 = AMOUNT;
			const exchangeId2 = 2;
			const sourceToken3 = token3;
			const targetToken3 = token1;
			const sourceAmount3 = AMOUNT;
			const deadline = DEADLINE;

			await expect(
				testTradeMultiRoute(
					sourceToken1,
					targetToken1,
					sourceAmount1,
					sourceToken2,
					targetToken2,
					exchangeId2,
					sourceToken3,
					targetToken3,
					0,
					deadline
				)
			).to.be.revertedWithError('LastTradeTargetMustBeBNT');
		});

		let externalExchanges = ['SushiSwap', 'UniswapV2', 'UniswapV3', 'BancorV2'];
		let arbMsg = 'arbitrage ';
		for (let i = 0; i < externalExchanges.length; i++) {
			let exchangeName = externalExchanges[i];
			let arbMsgNew = arbMsg.concat(exchangeName.toString());

			it(arbMsgNew, async () => {
				const { poolToken: poolToken3, token: token3 } = await preparePoolAndToken(TokenSymbol.TKN);
				const { poolToken: poolToken1, token: token1 } = await preparePoolAndToken(TokenSymbol.TKN1);
				const { poolToken: poolToken2, token: token2 } = await preparePoolAndToken(TokenSymbol.TKN2);

				const sourceToken1 = bnt;
				const targetToken1 = token1;
				const sourceAmount1 = AMOUNT;
				const exchangeId2 = i;
				await exchanges.setTokens(sourceToken1.address, targetToken1.address);
				const sourceToken2 = targetToken1;
				const targetToken2 = token2;
				const sourceToken3 = targetToken2;
				const targetToken3 = sourceToken1;

				await transfer(deployer, sourceToken1, exchanges.address, AMOUNT + GAS_LIMIT);
				await transfer(deployer, targetToken1, exchanges.address, AMOUNT + GAS_LIMIT);
				await transfer(deployer, sourceToken2, exchanges.address, AMOUNT + GAS_LIMIT);
				await transfer(deployer, targetToken2, exchanges.address, AMOUNT + GAS_LIMIT);
				await transfer(deployer, sourceToken3, exchanges.address, AMOUNT + GAS_LIMIT);
				await transfer(deployer, targetToken3, exchanges.address, AMOUNT + GAS_LIMIT);

				if (i == 2) {
					await expect(
						bancorArbitrage
							.connect(user)
							.execute(
								sourceToken1.address,
								targetToken1.address,
								sourceAmount1,
								sourceToken2.address,
								targetToken2.address,
								exchangeId2,
								sourceToken3.address,
								targetToken3.address,
								DEADLINE,
								{
									gasLimit: GAS_LIMIT * 10
								}
							)
					).to.be.revertedWithError('NoPairForTokens');
				} else {
					await expect(
						bancorArbitrage
							.connect(user)
							.execute(
								sourceToken1.address,
								targetToken1.address,
								sourceAmount1,
								sourceToken2.address,
								targetToken2.address,
								exchangeId2,
								sourceToken3.address,
								targetToken3.address,
								DEADLINE,
								{
									gasLimit: GAS_LIMIT * 10
								}
							)
					).to.emit(bancorArbitrage, 'ArbitrageExecuted');
				}
			});
		}
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
		if (exchangeId == 0) {
			// execute BancorV3 trade
			const res = await bancorArbitrage
				.connect(user)
				.testTradeBancorV3(
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
		} else if (exchangeId == 1) {
			// execute Sushi trade
			const res = await bancorArbitrage
				.connect(user)
				.testTradeSushiSwap(
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
		} else if (exchangeId == 2) {
			// execute uniswap V2 trade
			const res = await bancorArbitrage
				.connect(user)
				.testTradeUniswapV2(token1.address, token2.address, AMOUNT, user.address, {
					gasLimit: GAS_LIMIT
				});
		} else if (exchangeId == 3) {
			// execute uniswapV3 trade
			const res = await bancorArbitrage
				.connect(user)
				.testTradeUniswapV3(
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
		} else if (exchangeId == 4) {
			// execute BancorV2 trade
			const res = await bancorArbitrage
				.connect(user)
				.testTradeBancorV2(token1.address, token2.address, AMOUNT, MIN_RETURN_AMOUNT, {
					gasLimit: GAS_LIMIT
				});
		}

		// assert
		const newBalances = await getBalances([token1, token2], bancorArbitrage.address);
		expect(newBalances[token1.address].eq(previousBalances[token1.address].add(AMOUNT))).to.be.true;
	};

	const testTradeMultiRoute = async (
		sourceToken1: TokenWithAddress,
		targetToken1: TokenWithAddress,
		sourceAmount1: BigNumber,
		sourceToken2: TokenWithAddress,
		targetToken2: TokenWithAddress,
		exchangeId2: number,
		sourceToken3: TokenWithAddress,
		targetToken3: TokenWithAddress,
		minReturnAmount: BigNumber,
		deadline: BigNumber
	) => {
		let allBalances = 0;

		await transfer(deployer, sourceToken1, exchanges.address, MAX_SOURCE_AMOUNT);
		await transfer(deployer, targetToken1, exchanges.address, MAX_SOURCE_AMOUNT);

		await transfer(deployer, sourceToken2, exchanges.address, MAX_SOURCE_AMOUNT);
		await transfer(deployer, targetToken2, exchanges.address, MAX_SOURCE_AMOUNT);

		await transfer(deployer, sourceToken3, exchanges.address, MAX_SOURCE_AMOUNT);
		await transfer(deployer, targetToken3, exchanges.address, MAX_SOURCE_AMOUNT);

		const res = await bancorArbitrage
			.connect(user)
			.execute(
				sourceToken1.address,
				targetToken1.address,
				sourceAmount1,
				sourceToken2.address,
				targetToken2.address,
				exchangeId2,
				sourceToken3.address,
				targetToken3.address,
				deadline,
				{
					gasLimit: GAS_LIMIT * 10
				}
			);

		// assert
		//        const newBalances = await getBalances([token1], exchanges.address);
		//        const userBalances2 = await getBalances([token1], user.address);
		//        expect(newBalances[token1.address].eq(previousBalances[token1.address].sub(allBalances + AMOUNT))).to.be.true;
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
