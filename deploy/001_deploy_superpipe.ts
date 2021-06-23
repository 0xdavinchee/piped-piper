import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    // TODO: THIS VAULT ADDRESS IS INCORRECT
    await deploy("Pipe", {
        from: deployer,
        args: [
            process.env.HOST_ADDRESS,
            process.env.CFA_ADDRESS,
            process.env.SUPER_TOKEN_ADDRESS,
            process.env.VAULT_ADDRESS,
        ],
        log: true,
    });
};

export default func;
func.tags = ["Pipe"];
