import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;
    const fakeVault = await deployments.get("FakeVault");

    await deploy("VaultPipe", {
        from: deployer,
        args: ["0x0f1d7c55a2b133e000ea10eec03c774e0d6796e8", fakeVault.address],
        log: true,
    });
};

export default func;
func.tags = ["VaultPipe"];
func.dependencies = ["FakeVault"];
