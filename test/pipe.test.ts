import { expect } from "./chai-setup";
import { FakeVault, SuperValve, VaultPipe } from "../typechain";
import hre, { ethers, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import deployFramework from "@superfluid-finance/ethereum-contracts/scripts/deploy-framework";
import deployTestToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-test-token";
import deploySuperToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-super-token";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { setupUser } from "./utils";

// TODOs:
// - run through the test cases with pipe to see if things work properly
// - see if the evm.increaseTime leads to expected time (after calling that and then a func or if there is a
//     call function at this time method
// TODO: ensure msgSender remains the same throughout beforeAgreement until afterAgreement hooks.
// TODO: ensure when withdrawAndStopFlows calls withdraw, msg.sender in withdraw() is the origin not address(this).
// TODO: ensure that cfa.getFlowByID returns a positive flow rate.
// TODO: do we need to reset totalValveToPipeFlow on withdraw?
// TODO: Create a fake vault contract that just stores coins

interface IUserPipeData {
    pipeAddress: string;
    percentage: string;
}
const testAddress = "0xaE1c976A25c6D0DcCb5F1a7a9CDF81e518B27942";

const monthlyRateToSeconds = (monthlyRate: number) => {
    const days = 30;
    const hours = days * 24;
    const minutes = hours * 60;
    const seconds = minutes * 60;
    return Math.round((monthlyRate / seconds) * 10 ** 18);
};
const formatPercentage = (x: string) => Math.round(Number(x));
const getCreateUpdateFlowUserData = (userPipeData: IUserPipeData[]) => {
    const encoder = ethers.utils.defaultAbiCoder;
    return encoder.encode(
        ["address[]", "int96[]"],
        [userPipeData.map(x => x.pipeAddress), userPipeData.map(x => formatPercentage(x.percentage))],
    );
};

const setup = async () => {
    const { deployer } = await getNamedAccounts();

    await deployFramework((x: any) => console.error("error: ", x), { web3: (global as any).web3, from: deployer });
    await deployTestToken((x: any) => console.error("error: ", x), [":", "fDAI"], {
        web3: (global as any).web3,
        from: deployer,
    });
    await deploySuperToken((x: any) => console.error("error: ", x), [":", "fDAI"], {
        web3: (global as any).web3,
        from: deployer,
    });

    const users = await getUnnamedAccounts();
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [testAddress],
    });

    let sf = new SuperfluidSDK.Framework({
        web3: (global as any).web3,
        version: "test",
        tokens: ["fDAI"],
    });

    console.log("init superfluid");
    await sf.initialize();

    const fakeVaultFactory = await ethers.getContractFactory("FakeVault");
    const vaultPipeFactory = await ethers.getContractFactory("VaultPipe");
    const superValveFactory = await ethers.getContractFactory("SuperValve");
    const fakeVault = await fakeVaultFactory.deploy(sf.tokens.fDAI.address, "fDAI Vault 1 Token", "fDAI");
    const vaultPipe = await vaultPipeFactory.deploy(sf.tokens.fDAIx.address, fakeVault.address);
    const fakeVault2 = await fakeVaultFactory.deploy(sf.tokens.fDAI.address, "fDAI Vault 2 Token", "fDAI");
    const vaultPipe2 = await vaultPipeFactory.deploy(sf.tokens.fDAIx.address, fakeVault2.address);
    await fakeVault.deployed();
    await vaultPipe.deployed();
    await fakeVault2.deployed();
    await vaultPipe2.deployed();
    const superValve = await superValveFactory.deploy(
        sf.host.address,
        sf.agreements.cfa.address,
        sf.tokens.fDAIx.address,
        [vaultPipe.address],
    );
    await superValve.deployed();

    const contracts = {
        FakeVault: fakeVault as FakeVault,
        VaultPipe: vaultPipe as VaultPipe,
        VaultPipe2: vaultPipe2 as VaultPipe,
        SuperValve: superValve as SuperValve,
    };
    console.log("mint dai");
    const dai = await sf.contracts.TestToken.at(sf.tokens.fDAI.address);
    await dai.mint(deployer, ethers.utils.parseUnits("1000").toString());
    console.log("approve upgrade");
    await sf.tokens.fDAI.approve(sf.tokens.fDAIx.address, ethers.utils.parseUnits("1000").toString());
    console.log("approved");
    return {
        deployer: await setupUser(deployer, contracts),
        fundedUser: await setupUser(testAddress, contracts),
        ...contracts,
        sf,
    };
};

// test creating/updating/deleting a single flow from a user
// a. for updating test increasing/decreasing flow rate by itself
// b. "" changing the allocation % of the user
// doing both and b

// testing withdrawals

describe("Pipe", () => {
    before(() => {
        // setup framework here
        // snapshot of the blockchain and rollback
    });

    it.skip("Should be able to create flow.", async () => {
        const { VaultPipe, SuperValve, deployer, sf } = await setup();
        console.log("upgrade fDAIx");
        await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("500").toString());

        console.log("create flow");
        await sf.cfa.createFlow({
            superToken: sf.tokens.fDAIx.address,
            sender: deployer.address,
            receiver: SuperValve.address,
            flowRate: monthlyRateToSeconds(150),
            userData: getCreateUpdateFlowUserData([{ pipeAddress: VaultPipe.address, percentage: "100" }]),
        });

        expect((await SuperValve.getUserPipeFlowRate(deployer.address, VaultPipe.address)).toString()).to.eq(
            monthlyRateToSeconds(150).toString(),
        );
    });

    it("Should be able to create a flow into two pipes.", async () => {
        const { VaultPipe, VaultPipe2, SuperValve, deployer, sf } = await setup();
        await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("500").toString());
        await sf.cfa.createFlow({
            superToken: sf.tokens.fDAIx.address,
            sender: deployer.address,
            receiver: SuperValve.address,
            flowRate: monthlyRateToSeconds(150),
            userData: getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "50" },
                { pipeAddress: VaultPipe2.address, percentage: "50" },
            ]),
        });

        expect((await SuperValve.getUserPipeFlowRate(deployer.address, VaultPipe.address)).toString()).to.eq(
            monthlyRateToSeconds(75).toString(),
        );
        expect((await SuperValve.getUserPipeFlowRate(deployer.address, VaultPipe2.address)).toString()).to.eq(
            monthlyRateToSeconds(75).toString(),
        );
    });

    it("Should be able to update a flow to the two pipes.", async () => {});

    // it("Should properly handle creation of a new flow amounts", async () => {
    //     const flowRate = monthlyRateToSeconds(10);
    //     const { fundedUser, fUSDCx, Pipe } = await setup();
    // });
});
