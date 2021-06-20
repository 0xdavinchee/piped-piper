import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    // TODO: THIS VAULT ADDRESS IS INCORRECT
    await deploy("StakeDaoPipe", {
        from: deployer,
        args: [process.env.HOST_ADDRESS, process.env.CFA_ADDRESS, process.env.TOKEN_ADDRESS, process.env.TOKEN_ADDRESS],
        log: true,
    });
};

export default func;
func.tags = ["StakeDaoPipe"];
