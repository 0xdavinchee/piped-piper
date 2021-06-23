import { expect } from "./chai-setup";
import { ISuperfluid, Pipe } from "../typechain";
import hre, { ethers, deployments, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import ISuperfluidArtifact from "../artifacts/@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol/ISuperfluid.json";
import ISuperfluidTokenArtifact from "../artifacts/@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluidToken.sol/ISuperfluidToken.json";
import { setupUser, setupUsers } from "./utils";

const testAddress = process.env.TEST_ADDRESS || "";

const setup = async () => {
    await deployments.fixture(["Pipe"]);
    const contracts = {
        Host: (await ethers.getContractAt(ISuperfluidArtifact.abi, process.env.HOST_ADDRESS || "")) as ISuperfluid,
        Pipe: (await ethers.getContract("Pipe")) as Pipe,
        fUSDC: await ethers.getContractAt(ISuperfluidTokenArtifact.abi, process.env.TOKEN_ADDRESS || ""),
        fUSDCx: await ethers.getContractAt(ISuperfluidTokenArtifact.abi, process.env.SUPER_TOKEN_ADDRESS || ""),
    };
    const { deployer } = await getNamedAccounts();
    const users = await getUnnamedAccounts();
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [testAddress],
    });

    return {
        deployer: await setupUser(deployer, contracts),
        fundedUser: await setupUser(testAddress, contracts),
        ...contracts,
        users: await setupUsers(users, contracts),
    };
};

describe("Pipe", () => {
    it("Should deploy properly.", async () => {
        const { Host, Pipe } = await setup();
        expect(await Host.isApp(Pipe.address)).to.equal(false);
        expect(await Pipe.cfa()).to.equal(process.env.CFA_ADDRESS);
        expect(await Pipe.acceptedToken()).to.equal(process.env.SUPER_TOKEN_ADDRESS);
    });

    it("Should properly handle creation of a new flow amounts", async () => {});
});
