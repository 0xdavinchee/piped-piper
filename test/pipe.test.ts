import { expect } from "./chai-setup";
import { ISuperfluid, ISuperToken, Pipe } from "../typechain";
import hre, { ethers, deployments, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import ISuperfluidArtifact from "../artifacts/@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol/ISuperfluid.json";
import ISuperTokenArtifact from "../artifacts/@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol/ISuperToken.json";
import { setupUser, setupUsers } from "./utils";

// TODOs:
// - run through the test cases with pipe to see if things work properly
// - see if the evm.increaseTime leads to expected time (after calling that and then a func or if there is a
//     call function at this time method
// TODO: ensure msgSender remains the same throughout beforeAgreement until afterAgreement hooks.
// TODO: ensure when withdrawAndStopFlows calls withdraw, msg.sender in withdraw() is the origin not address(this).
// TODO: ensure that cfa.getFlowByID returns a positive flow rate.
// TODO: do we need to reset totalValveToPipeFlow on withdraw?
// TODO: Create a fake vault contract that just stores coins

const testAddress = process.env.TEST_ADDRESS || "";
const CFAAddress = process.env.CFA_ADDRESS || "";

const monthlyRateToSeconds = (monthlyRate: number) => {
    const days = 30;
    const hours = days * 24;
    const minutes = hours * 60;
    const seconds = minutes * 60;
    return Math.round((monthlyRate / seconds) * 10 ** 18);
};

const setup = async () => {
    await deployments.fixture(["Pipe"]);
    const contracts = {
        fUSDC: (await ethers.getContractAt(ISuperTokenArtifact.abi, process.env.TOKEN_ADDRESS || "")) as ISuperToken,
        fUSDCx: (await ethers.getContractAt(
            ISuperTokenArtifact.abi,
            process.env.SUPER_TOKEN_ADDRESS || "",
        )) as ISuperToken,
        Host: (await ethers.getContractAt(ISuperfluidArtifact.abi, process.env.HOST_ADDRESS || "")) as ISuperfluid,
        Pipe: (await ethers.getContract("Pipe")) as Pipe,
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
        const { fundedUser, fUSDCx, Host, Pipe } = await setup();
        expect(await Host.isApp(Pipe.address)).to.equal(false);
        expect(await Pipe.cfa()).to.equal(process.env.CFA_ADDRESS);
        expect(await Pipe.acceptedToken()).to.equal(process.env.SUPER_TOKEN_ADDRESS);
        expect(await fUSDCx.balanceOf(fundedUser.address)).to.equal(ethers.utils.parseUnits("1000"));
    });

    // it("Should properly handle creation of a new flow amounts", async () => {
    //     const flowRate = monthlyRateToSeconds(10);
    //     const { fundedUser, fUSDCx, Pipe } = await setup();
    // });
});
