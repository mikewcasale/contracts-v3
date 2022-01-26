import { ExternalRewardsVault, ProxyAdmin } from '../../components/Contracts';
import { ContractName, DeployedContracts, runTestDeployment } from '../../utils/Deploy';
import { expectRoleMembers, Roles } from '../helpers/AccessControl';
import { expect } from 'chai';
import { getNamedAccounts } from 'hardhat';

describe('1642682498-external-rewards-vault', () => {
    let deployer: string;
    let proxyAdmin: ProxyAdmin;
    let externalRewardsVault: ExternalRewardsVault;

    before(async () => {
        ({ deployer } = await getNamedAccounts());
    });

    beforeEach(async () => {
        await runTestDeployment(ContractName.ExternalRewardsVaultV1);

        proxyAdmin = await DeployedContracts.ProxyAdmin.deployed();
        externalRewardsVault = await DeployedContracts.ExternalRewardsVaultV1.deployed();
    });

    it('should deploy and configure the external rewards vault contract', async () => {
        expect(await proxyAdmin.getProxyAdmin(externalRewardsVault.address)).to.equal(proxyAdmin.address);

        expect(await externalRewardsVault.version()).to.equal(1);

        await expectRoleMembers(externalRewardsVault, Roles.Upgradeable.ROLE_ADMIN, [deployer]);
        await expectRoleMembers(externalRewardsVault, Roles.Vault.ROLE_ASSET_MANAGER);
    });
});
