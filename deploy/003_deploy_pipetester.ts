import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    await deploy("PipeTester", {
        from: deployer,
        args: [process.env.HOST_ADDRESS, process.env.CFA_ADDRESS],
    });
};

export default func;
func.tags = ["PipeTester"];
