import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    await deploy("SuperPipe", {
        from: deployer,
        args: [process.env.HOST_ADDRESS, process.env.CFA_ADDRESS, process.env.TOKEN_ADDRESS],
        log: true,
    });
};

export default func;
func.tags = ["SuperPipe"];
