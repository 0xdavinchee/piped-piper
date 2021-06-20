import { expect } from "./chai-setup";
import { ISuperfluid, Pipe } from "../typechain";
import { ethers, deployments } from "hardhat";
import ISuperfluidArtifact from "../artifacts/@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol/ISuperfluid.json";

const setup = async () => {
    await deployments.fixture(["Pipe"]);
    const contracts = {
        Host: (await ethers.getContractAt(ISuperfluidArtifact.abi, process.env.HOST_ADDRESS || "")) as ISuperfluid,
        Pipe: (await ethers.getContract("Pipe")) as Pipe,
    };

    return { ...contracts };
};

describe("Pipe", function () {
    it("Should deploy properly.", async function () {
        const { Host, Pipe } = await setup();
        expect(await Host.isApp(Pipe.address)).to.equal(true);
    });
});
