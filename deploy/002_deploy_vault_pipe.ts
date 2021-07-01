import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const { deploy } = deployments;
    const fakeVault = await deployments.get("FakeVault");
    const fUSDC = "0xbe49ac1eadac65dccf204d4df81d650b50122ab2";

    await deploy("VaultPipe", {
        from: deployer,
        args: [fUSDC, fakeVault.address],
        log: true,
    });
};

export default func;
func.tags = ["VaultPipe"];
func.dependencies = ["FakeVault"];
