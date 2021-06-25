import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;
    const fakeVault = await deployments.get("VaultPipe");

    await deploy("SuperValve", {
        from: deployer,
        args: [process.env.HOST_ADDRESS, process.env.CFA_ADDRESS, process.env.SUPER_TOKEN_ADDRESS, [fakeVault.address]],
        log: true,
    });
};

export default func;
func.tags = ["SuperValve"];
func.dependencies = ["VaultPipe"];
