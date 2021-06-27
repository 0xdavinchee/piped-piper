import { expect } from "./chai-setup";
import { ISuperfluid, SuperPipe } from "../typechain";
import { ethers, deployments } from "hardhat";
import ISuperfluidArtifact from "../artifacts/@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol/ISuperfluid.json";

const setup = async () => {
  await deployments.fixture(["SuperPipe"]);
  const contracts = {
    Host: (await ethers.getContractAt(ISuperfluidArtifact.abi, process.env.HOST_ADDRESS || "")) as ISuperfluid,
    SuperPipe: (await ethers.getContract("SuperPipe")) as SuperPipe,
  };

  return { ...contracts };
};

describe("SuperPipe", function () {
  it("Should deploy properly.", async function () {
    const { Host, SuperPipe } = await setup();
    expect(await Host.isApp(SuperPipe.address)).to.equal(true);
  });
});
