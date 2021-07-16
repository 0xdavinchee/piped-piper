import { expect } from "./chai-setup";
import { FakeVault, SuperValve, VaultPipe } from "../typechain";
import hre, { ethers, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import deployFramework from "@superfluid-finance/ethereum-contracts/scripts/deploy-framework";
import deployTestToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-test-token";
import deploySuperToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-super-token";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { setupUser } from "./utils";
import { BigNumber } from "ethers";

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
const testAddress = process.env.TEST_ADDRESS || "";

// test creating/updating/deleting a single flow from a user
// a. for updating test increasing/decreasing flow rate by itself
// b. "" changing the allocation % of the user
// doing both and b

// testing withdrawals

describe("Pipe", () => {
    const encoder = ethers.utils.defaultAbiCoder;
    let sf: any;
    let dai: any;
    let daix: any;

    /**************************************************************************
     * Before Hooks
     *************************************************************************/
    before(async () => {
        const { deployer } = await getNamedAccounts();
        await deployFramework((x: any) => console.error("error: ", x), { web3: (global as any).web3, from: deployer });
    });

    beforeEach(async () => {
        const { deployer } = await getNamedAccounts();
        await deployTestToken((x: any) => console.error("error: ", x), [":", "fDAI"], {
            web3: (global as any).web3,
            from: deployer,
        });
        await deploySuperToken((x: any) => console.error("error: ", x), [":", "fDAI"], {
            web3: (global as any).web3,
            from: deployer,
        });

        sf = new SuperfluidSDK.Framework({
            web3: (global as any).web3,
            version: "test",
            tokens: ["fDAI"],
        });

        console.log("Initialize Superfluid framework...");
        await sf.initialize();

        console.log("Mint DAI for users...");
        dai = await sf.contracts.TestToken.at(sf.tokens.fDAI.address);
        daix = sf.tokens.fDAIx;
        await dai.mint(deployer, ethers.utils.parseUnits("1000").toString());

        console.log("Approve fDAIx allowance of fDAI...");
        await sf.tokens.fDAI.approve(sf.tokens.fDAIx.address, ethers.utils.parseUnits("1000").toString());
        console.log("~Approved~");
    });

    /**************************************************************************
     * Test Helper Functions
     *************************************************************************/
    const monthlyRateToSeconds = (monthlyRate: number) => {
        const days = 30;
        const hours = days * 24;
        const minutes = hours * 60;
        const seconds = minutes * 60;
        return Math.round((monthlyRate / seconds) * 10 ** 18);
    };

    const formatPercentage = (x: string) => Math.round(Number(x));

    const toNum = (x: BigNumber) => Number(x.toString());
    
    const getCreateUpdateFlowUserData = (userPipeData: IUserPipeData[]) => {
        return encoder.encode(
            ["address[]", "int96[]"],
            [userPipeData.map(x => x.pipeAddress), userPipeData.map(x => formatPercentage(x.percentage))],
        );
    };
    const decodeUserData = 

    const setup = async () => {
        const { deployer } = await getNamedAccounts();
        await hre.network.provider.request({
            method: "hardhat_impersonateAccount",
            params: [testAddress],
        });

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
        return {
            deployer: await setupUser(deployer, contracts),
            fundedUser: await setupUser(testAddress, contracts),
            ...contracts,
            sf,
        };
    };

    const createFlow = async (
        senderAddress: string,
        receiverAddress: string,
        monthlyFlowRate: number,
        data: string,
    ) => {
        const formattedFlowRate = ethers.utils.formatUnits(monthlyFlowRate);
        console.log(
            `Create flow from ${senderAddress} to ${receiverAddress} at a monthly flowRate of ${formattedFlowRate}.`,
        );
        try {
            await sf.cfa.createFlow({
                superToken: sf.tokens.fDAIx.address,
                sender: senderAddress,
                receiver: receiverAddress,
                flowRate: monthlyRateToSeconds(monthlyFlowRate),
                userData: data,
            });
        } catch (err) {
            console.error("Create Flow Error: ", err);
        }
    };

    /**************************************************************************
     * Create Test Cases
     *************************************************************************/
    it("Should be able to create flow.", async () => {
        const { VaultPipe, SuperValve, deployer } = await setup();
        console.log("upgrade fDAIx");
        await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
        const userData = getCreateUpdateFlowUserData([{ pipeAddress: VaultPipe.address, percentage: "100" }]);
        
        await createFlow(deployer.address, SuperValve.address, 150, userData);

        expect(toNum(await SuperValve.getUserPipeFlowRate(deployer.address, VaultPipe.address))).to.be.lessThanOrEqual(
            monthlyRateToSeconds(150),
        );
    });

    it("Should be able to create a flow into two pipes.", async () => {
        const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
        await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
        const userData = getCreateUpdateFlowUserData([
            { pipeAddress: VaultPipe.address, percentage: "50" },
            { pipeAddress: VaultPipe2.address, percentage: "50" },
        ]);
        
        await createFlow(deployer.address, SuperValve.address, 150, userData);

        const vaultPipeFlowRate = await SuperValve.getUserPipeFlowRate(deployer.address, VaultPipe.address);
        const vaultPipe2FlowRate = await SuperValve.getUserPipeFlowRate(deployer.address, VaultPipe2.address);

        // we must check less than or equal as we set the flow rate based on `getMaximumFlowRateFromDeposit`
        expect(toNum(vaultPipeFlowRate)).to.be.lessThanOrEqual(monthlyRateToSeconds(75));
        expect(toNum(vaultPipe2FlowRate)).to.be.lessThanOrEqual(
            monthlyRateToSeconds(75),
        );

        console.log("FlowRates: ");
        console.log(VaultPipe.address + ": " + vaultPipeFlowRate);
        console.log(VaultPipe2.address + ": " + vaultPipe2FlowRate);
        expect(vaultPipeFlowRate).to.eq(vaultPipe2FlowRate);
    });

    // TODO: make test cases for when create fails and catch them
    /**************************************************************************
     * Update Test Cases
     *************************************************************************/

    /**************************************************************************
     * Delete Test Cases
     *************************************************************************/

    /**************************************************************************
     * Withdraw Test Cases
     *************************************************************************/
    it("Should be able to update a flow to the two pipes.", async () => {});
});
