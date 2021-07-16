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
interface IUser {
    address: string;
    FakeVault: FakeVault;
    VaultPipe: VaultPipe;
    VaultPipe2: VaultPipe;
    SuperValve: SuperValve;
}

describe("SuperValve Tests", () => {
    const encoder = ethers.utils.defaultAbiCoder;
    let sf: any;
    let dai: any;
    let daix: any;
    let names: { [address: string]: string } = {};
    let userAddresses: string[] = [];
    let admin: IUser;
    let superValveAddress: string;

    /** Alice and Bob  */
    let users: IUser[];

    /**************************************************************************
     * Before Hooks
     *************************************************************************/
    before(async () => {
        const { deployer } = await getNamedAccounts();
        await deployFramework((x: any) => errorHandler("Framework", x), {
            web3: (global as any).web3,
            from: deployer,
        });
        const [Alice, Bob] = await getUnnamedAccounts();
        names[deployer] = "Deployer";
        names[Alice] = "Alice";
        names[Bob] = "Bob";
        userAddresses = [Alice, Bob];
    });

    beforeEach(async () => {
        const { deployer } = await getNamedAccounts();

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
        const adminAndUsers = userAddresses.concat(deployer);
        for (let i = 0; i < adminAndUsers.length; i++) {
            const address = adminAndUsers[i];
            await dai.mint(address, ethers.utils.parseUnits("1000").toString(), { from: deployer });
            await dai.approve(sf.tokens.fDAIx.address, ethers.utils.parseUnits("1000").toString(), { from: address });
            await sf.tokens.fDAIx.upgrade(ethers.utils.parseUnits("1000").toString(), { from: address });
        }
        console.log("\n************** Superfluid Framework Setup Complete **************\n");

        console.log("\n************** Deploying SuperValve + Pipe Contract **************\n");
        const fakeVaultFactory = await ethers.getContractFactory("FakeVault");
        const vaultPipeFactory = await ethers.getContractFactory("VaultPipe");
        const superValveFactory = await ethers.getContractFactory("SuperValve");

        const fakeVault = await fakeVaultFactory.deploy(sf.tokens.fDAI.address, "fDAI Vault 1 Token", "fDAI");
        const vaultPipe = await vaultPipeFactory.deploy(sf.tokens.fDAIx.address, fakeVault.address);
        const fakeVault2 = await fakeVaultFactory.deploy(sf.tokens.fDAI.address, "fDAI Vault 2 Token", "fDAI");
        const vaultPipe2 = await vaultPipeFactory.deploy(sf.tokens.fDAIx.address, fakeVault2.address);
        const superValve = await superValveFactory.deploy(
            sf.host.address,
            sf.agreements.cfa.address,
            sf.tokens.fDAIx.address,
            [vaultPipe.address, vaultPipe2.address],
        );

        await fakeVault.deployed();
        await vaultPipe.deployed();
        await fakeVault2.deployed();
        await vaultPipe2.deployed();
        await superValve.deployed();

        names[superValve.address] = "SuperValve";
        names[vaultPipe.address] = "fDAI Vault 1";
        names[vaultPipe2.address] = "fDAI Vault 2";

        superValveAddress = superValve.address;

        const contracts = {
            FakeVault: fakeVault as FakeVault,
            VaultPipe: vaultPipe as VaultPipe,
            VaultPipe2: vaultPipe2 as VaultPipe,
            SuperValve: superValve as SuperValve,
        };
        admin = await setupUser(deployer, contracts);
        users = await setupUsers(userAddresses, contracts);
        
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

    const printOutUserToPipeFlowRates = async (
        superValve: SuperValve,
        userAddress: string,
        pipeAddresses: string[],
    ) => {
        console.log("****************** User to Pipe Flow Rate(s) ******************");
        const promises = pipeAddresses.map(x => superValve.getUserPipeFlowRate(userAddress, x));
        const results = await Promise.all(promises);
        for (let i = 0; i < pipeAddresses.length; i++) {
            console.log(names[userAddress] + " to " + names[pipeAddresses[i]] + " flow rate: ", toNum(results[i]));
        }
        return results;
    };

    const checkUserFlowRateResults = (monthlyFlowRate: number, results: BigNumber[], userData: string) => {
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

    describe.skip("Admin Permissions Tests", () => {
        it("Should allow admin to add/remove pipe addresses", async () => {
            await expect(admin.SuperValve.addPipeAddress(users[1].address))
                .to.emit(admin.SuperValve, "NewPipeAddress")
                .withArgs(users[1].address);
            await expect(admin.SuperValve.removePipeAddress(users[1].address))
                .to.emit(admin.SuperValve, "RemovedPipeAddress")
                .withArgs(users[1].address);
        });

        it("Should not allow adding/removing invalid pipe addresses.", async () => {
            await expect(admin.SuperValve.addPipeAddress(admin.VaultPipe2.address)).to.revertedWith(
                "SuperValve: This pipe address is already a valid pipe address.",
            );
            await expect(admin.SuperValve.removePipeAddress(users[1].address)).to.revertedWith(
                "SuperValve: This pipe address is not a valid pipe address.",
            );
        });

        it("Should not allow non admin to add/remove pipe addresses", async () => {
            await expect(users[0].SuperValve.addPipeAddress(users[1].address)).to.revertedWith(
                "SuperValve: You don't have permissions for this action.",
            );
            await expect(users[0].SuperValve.removePipeAddress(admin.VaultPipe.address)).to.revertedWith(
                "SuperValve: You don't have permissions for this action.",
            );
        });
    });

    describe("Create Flow Tests", () => {
        it("Should be able to create flow to just a single pipe.", async () => {
            const userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "100" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "0" },
            ]);

            const results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);
        });

        it("Should be able to create a flow into two pipes.", async () => {
            const userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "50" },
            ]);

            const results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);
        });

        it("Should allow multiple users to create flows into multiple pipes.", async () => {});
    });

    describe("Update Flow Tests", () => {
        it("Should be able to update increase and decrease flow rate.", async () => {
            const userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);

            // increase flow rate
            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                250,
                userData,
            );
            checkUserFlowRateResults(250, results, userData);

            // decrease flow rate
            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                50,
                userData,
            );
            checkUserFlowRateResults(50, results, userData);

            // increase flow rate
            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                550,
                userData,
            );
            checkUserFlowRateResults(550, results, userData);
        });

        it("Should be able to change their allocations with flow rate staying constant.", async () => {
            let userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);

            userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "30" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "70" },
            ]);

            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);
        });

        it("Should be able to remove allocation completely to one pipe.", async () => {
            let userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);

            // remove allocation completely from one pipe
            userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "100" },
            ]);

            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);
        });

        it("Should be able to change their allocations and their flow rate.", async () => {
            let userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await createOrUpdateFlow(
                sf.cfa.createFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                150,
                userData,
            );
            checkUserFlowRateResults(150, results, userData);

            // remove allocation completely from one pipe
            userData = getCreateUpdateFlowUserData([
                { pipeAddress: admin.VaultPipe.address, percentage: "43" },
                { pipeAddress: admin.VaultPipe2.address, percentage: "57" },
            ]);

            results = await createOrUpdateFlow(
                sf.cfa.updateFlow,
                admin.SuperValve,
                admin.address,
                superValveAddress,
                342,
                userData,
            );
            checkUserFlowRateResults(342, results, userData);
        });
    });

    describe("Delete Flow Tests", () => {

    });

    /**************************************************************************
     * Withdraw Test Cases
     *************************************************************************/
});

// TODO: Should not allow create flow rate where flow rate is 0
// Should not allow create flow rate where allocations don't add up to 100 (greater or less than)
// Should not allow update flow rate where flow rate is 0
// Should not allow update flow rate where allocations don't add up to 100 (greater or less than)
