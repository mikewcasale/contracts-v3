import {
    DeployedContracts,
    fundAccount,
    getNamedSigners,
    isLive,
    isMainnetFork,
    setDeploymentMetadata
} from '../../utils/Deploy';
import { Roles } from '../../utils/Roles';
import { utils } from 'ethers';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

const { id } = utils;

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    if (!isMainnetFork()) {
        throw new Error('Unsupported network');
    }

    const { deployer, foundationMultisig } = await getNamedSigners();

    await fundAccount(foundationMultisig.address);

    const network = await DeployedContracts.BancorNetwork.deployed();
    const liquidityProtection = await DeployedContracts.LiquidityProtection.deployed();

    // grant the BancorNetwork ROLE_MIGRATION_MANAGER role to the contract
    await network.connect(deployer).grantRole(Roles.BancorNetwork.ROLE_MIGRATION_MANAGER, liquidityProtection.address);

    return true;
};

func.skip = async () => isLive();

export default setDeploymentMetadata(__filename, func);
