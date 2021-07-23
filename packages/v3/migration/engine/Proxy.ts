import Contracts, { Contract, ContractBuilder } from 'components/Contracts';
import { BaseContract, ContractFactory } from 'ethers';
import { ProxyAdmin, TransparentUpgradeableProxy } from 'typechain';

export type proxyType = ReturnType<typeof initProxy>;

export const initProxy = (contracts: typeof Contracts) => {
    const createTransparentProxy = async (admin: BaseContract, logicContract: BaseContract) => {
        return contracts.TransparentUpgradeableProxy.deploy(logicContract.address, admin.address, []);
    };

    const createProxy = async <F extends ContractFactory>(
        admin: ProxyAdmin,
        logicContractToDeploy: ContractBuilder<F>,
        ...ctorArgs: Parameters<F['deploy']>
    ): Promise<Contract<F> & { asProxy: TransparentUpgradeableProxy }> => {
        const logicContract = await logicContractToDeploy.deploy(...ctorArgs);
        const proxy = await createTransparentProxy(admin, logicContract);

        return {
            ...(await logicContractToDeploy.attach(proxy.address)),
            asProxy: await contracts.TransparentUpgradeableProxy.attach(proxy.address)
        };
    };

    return { createProxy };
};
