import Contracts, {
    AccessControlEnumerable,
    AutoCompoundingRewards,
    BancorArbitrage,
    BancorNetwork,
    BancorNetworkInfo,
    BancorPortal,
    BNTPool,
    ExternalProtectionVault,
    ExternalRewardsVault,
    MasterVault,
    NetworkSettings,
    PendingWithdrawals,
    PoolCollection,
    PoolMigrator,
    PoolToken,
    PoolTokenFactory,
    StandardRewards
} from '../../components/Contracts';
import LegacyContracts, {
    BNT,
    IUniswapV2Factory,
    IUniswapV2Factory__factory,
    IUniswapV2Router02,
    IUniswapV2Router02__factory,
    LegacyBancorNetwork,
    Registry as LegacyRegistry,
    LiquidityProtection,
    LiquidityProtectionSettings,
    LiquidityProtectionStore,
    Owned,
    StakingRewardsClaim,
    STANDARD_CONVERTER_TYPE,
    STANDARD_POOL_CONVERTER_WEIGHT,
    TokenGovernance,
    VBNT
} from '../../components/LegacyContracts';
import { expectRoleMembers, Roles } from '../../test/helpers/AccessControl';
import { getBalance, getTransactionCost } from '../../test/helpers/Utils';
import { MAX_UINT256, PPM_RESOLUTION, RATE_MAX_DEVIATION_PPM, ZERO_ADDRESS } from '../../utils/Constants';
import { DeployedContracts, fundAccount, getNamedSigners, isMainnet, runPendingDeployments } from '../../utils/Deploy';
import Logger from '../../utils/Logger';
import { NATIVE_TOKEN_ADDRESS } from '../../utils/TokenData';
import { Fraction, toWei } from '../../utils/Types';
import { IERC20, StandardPoolConverter } from '@bancor/contracts-solidity';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import Decimal from 'decimal.js';
import { BigNumber } from 'ethers';
import { getNamedAccounts } from 'hardhat';

(isMainnet() ? describe : describe.skip)('network', async () => {
    let network: BancorNetwork;
    let arbitrage: BancorArbitrage;
    let networkSettings: NetworkSettings;
    let networkInfo: BancorNetworkInfo;
    let bntGovernance: TokenGovernance;
    let vbntGovernance: TokenGovernance;
    let bnt: BNT;
    let vbnt: VBNT;
    let bntPool: BNTPool;
    let masterVault: MasterVault;
    let poolCollection: PoolCollection;
    let pendingWithdrawals: PendingWithdrawals;
    let autoCompoundingRewards: AutoCompoundingRewards;

    let deployer: SignerWithAddress;
    let daoMultisig: SignerWithAddress;
    let foundationMultisig: SignerWithAddress;
    let bntWhale: SignerWithAddress;
    let ethWhale: SignerWithAddress;

    const ArbitrageRewardsDefaults = {
        percentagePPM: 30000,
        maxAmount: 100
    };

    before(async () => {
        ({ deployer, daoMultisig, foundationMultisig, ethWhale, bntWhale } = await getNamedSigners());

        await fundAccount(bntWhale);
    });

    beforeEach(async () => {
        await runPendingDeployments();

        network = await DeployedContracts.BancorNetwork.deployed();
        arbitrage = await DeployedContracts.BancorArbitrage.deployed();
        networkSettings = await DeployedContracts.NetworkSettings.deployed();
        bntGovernance = await DeployedContracts.BNTGovernance.deployed();
        vbntGovernance = await DeployedContracts.VBNTGovernance.deployed();
        bnt = await DeployedContracts.BNT.deployed();
        vbnt = await DeployedContracts.VBNT.deployed();
        poolCollection = await DeployedContracts.PoolCollectionType1V10.deployed();
        bntPool = await DeployedContracts.BNTPool.deployed();
        masterVault = await DeployedContracts.MasterVault.deployed();
        pendingWithdrawals = await DeployedContracts.PendingWithdrawals.deployed();
        autoCompoundingRewards = await DeployedContracts.AutoCompoundingRewards.deployed();
        networkInfo = await DeployedContracts.BancorNetworkInfo.deployed();

        await arbitrage.setRewards(ArbitrageRewardsDefaults);
    });
});
