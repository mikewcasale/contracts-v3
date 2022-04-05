import { ContractName, deploy, DeployedContracts, DeploymentTag } from '../utils/Deploy';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    const { deployer } = await getNamedAccounts();

    const network = await DeployedContracts.BancorNetworkV1.deployed();
    const networkSettings = await DeployedContracts.NetworkSettingsV1.deployed();
    const bnt = await DeployedContracts.BNT.deployed();

    await deploy({
        name: ContractName.BancorV1Migration,
        from: deployer,
        args: [network.address, networkSettings.address, bnt.address]
    });

    return true;
};

func.id = DeploymentTag.BancorV1MigrationV1;
func.dependencies = [DeploymentTag.V2, DeploymentTag.BancorNetworkV1];
func.tags = [DeploymentTag.V3, DeploymentTag.BancorV1MigrationV1];

export default func;