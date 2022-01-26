import { NetworkSettings, ProxyAdmin } from '../../components/Contracts';
import { ContractName, DeployedContracts, runTestDeployment } from '../../utils/Deploy';
import { expectRoleMembers, Roles } from '../helpers/AccessControl';
import { expect } from 'chai';
import { getNamedAccounts } from 'hardhat';

describe('1642682501-network-settings', () => {
    let deployer: string;
    let proxyAdmin: ProxyAdmin;
    let networkSettings: NetworkSettings;

    before(async () => {
        ({ deployer } = await getNamedAccounts());
    });

    beforeEach(async () => {
        await runTestDeployment(ContractName.NetworkSettingsV1);

        proxyAdmin = await DeployedContracts.ProxyAdmin.deployed();
        networkSettings = await DeployedContracts.NetworkSettingsV1.deployed();
    });

    it('should deploy and configure the network settings contract', async () => {
        expect(await proxyAdmin.getProxyAdmin(networkSettings.address)).to.equal(proxyAdmin.address);

        expect(await networkSettings.version()).to.equal(1);

        await expectRoleMembers(networkSettings, Roles.Upgradeable.ROLE_ADMIN, [deployer]);
    });
});
