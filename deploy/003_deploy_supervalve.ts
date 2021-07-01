import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;
    // const vaultPipe = await deployments.get("VaultPipe");

    const fUSDCx = "0x0f1d7c55a2b133e000ea10eec03c774e0d6796e8";

    await deploy("SuperValve", {
        from: deployer,
        args: [process.env.HOST_ADDRESS, process.env.CFA_ADDRESS, fUSDCx, []],
        log: true,
        gasLimit: 9000000,
    });
};

export default func;
func.tags = ["SuperValve"];
// func.dependencies = ["VaultPipe"];
