import { deploymentMetadata, deploymentTagExists, isLive } from '../../utils/Deploy';
import { deployments } from 'hardhat';
import { Suite } from 'mocha';

const { run } = deployments;

export const describeDeployment = async (
    filename: string,
    fn: (this: Suite) => void,
    skip: () => boolean = () => false
): Promise<Suite | void> => {
    const { id, tag } = deploymentMetadata(filename);

    // if we're running against a mainnet fork, ensure to skip tests for already existing deployments
    if (skip() || (await deploymentTagExists(tag))) {
        return describe.skip(id, fn);
    }

    return describe(id, async function (this: Suite) {
        beforeEach(async () => {
            if (isLive()) {
                throw new Error('Unsupported network');
            }

            return run(tag, {
                resetMemory: false,
                deletePreviousDeployments: false,
                writeDeploymentsToFiles: true
            });
        });

        fn.apply(this);
    });
};
