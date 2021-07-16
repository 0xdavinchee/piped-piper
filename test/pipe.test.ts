import { expect } from "./chai-setup";
import { FakeVault, SuperValve, VaultPipe } from "../typechain";
import hre, { ethers, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import deployFramework from "@superfluid-finance/ethereum-contracts/scripts/deploy-framework";
import deployTestToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-test-token";
import deploySuperToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-super-token";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { setupUser, setupUsers } from "./utils";
import { BigNumber } from "ethers";

interface IUserPipeData {
    pipeAddress: string;
    percentage: string;
}

describe("SuperValve Tests", () => {
    const encoder = ethers.utils.defaultAbiCoder;
    let sf: any;
    let dai: any;
    let daix: any;
    let names: { [address: string]: string } = {};

    /**************************************************************************
     * Before Hooks
     *************************************************************************/
    before(async () => {
        const { deployer } = await getNamedAccounts();
        await deployFramework((x: any) => errorHandler("Framework", x), {
            web3: (global as any).web3,
            from: deployer,
        });
    });

    beforeEach(async () => {
        const { deployer } = await getNamedAccounts();
        const [Alice, Bob] = await getUnnamedAccounts();
        names[deployer] = "Deployer";
        names[Alice] = "Alice";
        names[Bob] = "Bob";
        const users = [deployer, Alice, Bob];

        await deployTestToken((x: any) => errorHandler("TestToken", x), [":", "fDAI"], {
            web3: (global as any).web3,
            from: deployer,
        });
        await deploySuperToken((x: any) => errorHandler("SuperToken", x), [":", "fDAI"], {
            web3: (global as any).web3,
            from: deployer,
        });

        sf = new SuperfluidSDK.Framework({
            web3: (global as any).web3,
            version: "test",
            tokens: ["fDAI"],
        });

        console.log("\n");
        await sf.initialize();

        dai = await sf.contracts.TestToken.at(sf.tokens.fDAI.address);
        daix = sf.tokens.fDAIx;

        console.log("Mint DAI and approve fDAIx allowance for users...");
        for (let i = 0; i < users.length; i++) {
            await dai.mint(deployer, ethers.utils.parseUnits("1000").toString(), { from: users[i] });
            await dai.approve(sf.tokens.fDAIx.address, ethers.utils.parseUnits("1000").toString(), { from: users[i] });
        }
        console.log("\n**************Superfluid Framework Setup Complete**************\n");
    });

    /**************************************************************************
     * Test Helper Functions
     *************************************************************************/
    const errorHandler = (type: string, err: any) => {
        if (err) console.error("Deploy " + type + " Error: ", err);
    };
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
    const decodeUserData = (encodedData: string) => {
        return encoder.decode(["address[]", "int96[]"], encodedData);
    };

    const setup = async () => {
        const { deployer } = await getNamedAccounts();
        const users = await getUnnamedAccounts();

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

        names[superValve.address] = "SuperValve";
        names[vaultPipe.address] = "fDAI Vault 1";
        names[vaultPipe2.address] = "fDAI Vault 2";

        const contracts = {
            FakeVault: fakeVault as FakeVault,
            VaultPipe: vaultPipe as VaultPipe,
            VaultPipe2: vaultPipe2 as VaultPipe,
            SuperValve: superValve as SuperValve,
        };
        return {
            deployer: await setupUser(deployer, contracts),
            ...contracts,
            sf,
            users: await setupUsers(users, contracts),
        };
    };

    const printOutUserToPipeFlowRates = async (
        superValve: SuperValve,
        userAddress: string,
        pipeAddresses: string[],
    ) => {
        console.log("*** User to Pipe Flow Rate(s) ***");
        const promises = pipeAddresses.map(x => superValve.getUserPipeFlowRate(userAddress, x));
        const results = await Promise.all(promises);
        for (let i = 0; i < pipeAddresses.length; i++) {
            console.log(names[userAddress] + " to " + names[pipeAddresses[i]] + " flow rate: ", toNum(results[i]));
        }
        return results;
    };

    const checkFlowRateResults = (monthlyFlowRate: number, results: BigNumber[], userData: string) => {
        const data = decodeUserData(userData);
        const percentages = data[1];
        for (let i = 0; i < results.length; i++) {
            const flowRateAllocation = monthlyFlowRate * (toNum(percentages[i]) / 100);
            console.log(
                "Expect: ",
                toNum(results[i]),
                " to be less than or equal to ",
                monthlyRateToSeconds(flowRateAllocation),
            );

            // Note: flow rate will always be less than or equal to our desired flow rate as we set the
            // flow rate based on `getMaximumFlowRateFromDeposit`
            expect(toNum(results[i])).to.be.lessThanOrEqual(monthlyRateToSeconds(flowRateAllocation));
        }
        console.log("******************************************************\n");
    };

    /** Creates a flow from sender to receiver of monthly flow rate and
     * the receiver (super app) redirects these flows to multiple pipes.
     * This function returns an array containing information about the
     * resulting flow rates into the different pipes.
     */
    const createOrUpdateFlow = async (
        func: any,
        superValve: SuperValve,
        sender: string,
        receiver: string,
        monthlyFlowRate: number,
        data: string,
    ) => {
        const formattedFlowRate = ethers.utils.formatUnits(monthlyRateToSeconds(monthlyFlowRate));
        const type = func === sf.cfa.createFlow ? "Create" : "Update";
        console.log(`\n****************** ${type} Flow Test ******************`);
        console.log(
            `${type} flow from ${names[sender]} to ${names[receiver]} at a monthly flowRate of ${formattedFlowRate} fDAIx/s.`,
        );
        try {
            await func({
                superToken: sf.tokens.fDAIx.address,
                sender: sender,
                receiver: receiver,
                flowRate: monthlyRateToSeconds(monthlyFlowRate),
                userData: data,
            });
        } catch (err) {
            console.error(`${type} Flow Error: ${err}`);
        }
        const userData = decodeUserData(data);
        const results = printOutUserToPipeFlowRates(superValve, sender, userData[0]);

        return results;
    };

    describe("Create Flow Tests", () => {
        it("Should be able to create flow to just a single pipe.", async () => {
            const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
            const userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "100" },
                { pipeAddress: VaultPipe2.address, percentage: "0" },
            ]);

            const results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);
        });

        it("Should be able to create a flow into two pipes.", async () => {
            const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
            const userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "50" },
                { pipeAddress: VaultPipe2.address, percentage: "50" },
            ]);

            const results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);
        });

        it("Should allow multiple users to create flows into multiple pipes.", async () => {});
    });

    describe("Update Flow Tests", () => {
        it("Should be able to update increase and decrease flow rate.", async () => {
            const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
            const userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "50" },
                { pipeAddress: VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);

            // increase flow rate
            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                250,
                userData,
            );
            checkFlowRateResults(250, results, userData);

            // decrease flow rate
            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                50,
                userData,
            );
            checkFlowRateResults(50, results, userData);

            // increase flow rate
            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                550,
                userData,
            );
            checkFlowRateResults(550, results, userData);
        });

        it("Should be able to change their allocations with flow rate staying constant.", async () => {
            const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
            let userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "50" },
                { pipeAddress: VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);

            userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "30" },
                { pipeAddress: VaultPipe2.address, percentage: "70" },
            ]);

            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);
        });

        it("Should be able to remove allocation completely to one pipe.", async () => {
            const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
            let userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "50" },
                { pipeAddress: VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);

            // remove allocation completely from one pipe
            userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "0" },
                { pipeAddress: VaultPipe2.address, percentage: "100" },
            ]);

            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);
        });

        it("Should be able to change their allocations and their flow rate.", async () => {
            const { VaultPipe, VaultPipe2, SuperValve, deployer } = await setup();
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString());
            let userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "50" },
                { pipeAddress: VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                150,
                userData,
            );
            checkFlowRateResults(150, results, userData);

            // remove allocation completely from one pipe
            userData = getCreateUpdateFlowUserData([
                { pipeAddress: VaultPipe.address, percentage: "43" },
                { pipeAddress: VaultPipe2.address, percentage: "57" },
            ]);

            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                SuperValve,
                deployer.address,
                SuperValve.address,
                342,
                userData,
            );
            checkFlowRateResults(342, results, userData);
        });
    });
    /**************************************************************************
     * Delete Test Cases
     *************************************************************************/

    /**************************************************************************
     * Withdraw Test Cases
     *************************************************************************/
});
