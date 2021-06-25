import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;

    await deploy("FakeVault", {
        from: deployer,
        args: ["0x0f1d7c55a2b133e000ea10eec03c774e0d6796e8", "fUSDC Vault 1 TOKEN", "vFUSDC1"],
        log: true,
    });
};

export default func;
func.tags = ["FakeVault"];
