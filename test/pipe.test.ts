import { expect } from "./chai-setup";
import { FakeVault, SuperValve, VaultPipe } from "../typechain";
import hre, { ethers, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import deployFramework from "@superfluid-finance/ethereum-contracts/scripts/deploy-framework";
import deployTestToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-test-token";
import deploySuperToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-super-token";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { setupUser, setupUsers } from "./utils";
import { BigNumber } from "ethers";

interface IFlowData {
    readonly flowRate: string;
    readonly receiver: string;
    readonly sender: string;
}
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
    let superValveAddress: string;

    /** Alice and Bob  */
    let Admin: IUser;
    let Alice: IUser;
    let Bob: IUser;

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
        userAddresses = [deployer, Alice, Bob];
    });

    beforeEach(async () => {
        await deployTestToken((x: any) => errorHandler("TestToken", x), [":", "fDAI"], {
            web3: (global as any).web3,
            from: userAddresses[0],
        });
        await deploySuperToken((x: any) => errorHandler("SuperToken", x), [":", "fDAI"], {
            web3: (global as any).web3,
            from: userAddresses[0],
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
        for (let i = 0; i < userAddresses.length; i++) {
            const address = userAddresses[i];
            await dai.mint(address, ethers.utils.parseUnits("1000").toString(), { from: userAddresses[0] });
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

        Admin = await setupUser(userAddresses[0], contracts);
        Alice = await setupUser(userAddresses[1], contracts);
        Bob = await setupUser(userAddresses[2], contracts);
    });

    /**************************************************************************
     * Test Helper Functions
     *************************************************************************/
    const errorHandler = (type: string, err: any) => {
        if (err) console.error("Deploy " + type + " Error: ", err);
    };

    const monthlyToSecondRate = (monthlyRate: number) => {
        const days = 30;
        const hours = days * 24;
        const minutes = hours * 60;
        const seconds = minutes * 60;
        return Math.round((monthlyRate / seconds) * 10 ** 18);
    };

    const formatPercentage = (x: string) => Math.round(Number(x));

    const toNum = (x: BigNumber) => Number(x.toString());

    const getModifyFlowUserData = (userPipeData: IUserPipeData[]) => {
        return encoder.encode(
            ["address[]", "int96[]"],
            [userPipeData.map(x => x.pipeAddress), userPipeData.map(x => formatPercentage(x.percentage))],
        );
    };

    const decodeUserData = (encodedData: string) => {
        return encoder.decode(["address[]", "int96[]"], encodedData);
    };

    const checkUserFlowRateResults = (
        monthlyFlowRate: number,
        results: BigNumber[],
        userData: string,
        userAddress: string,
    ) => {
        const data = decodeUserData(userData);
        const pipeAddresses: string[] = data[0];
        const percentages = data[1];
        console.log("****************** User to Pipe Flow Rate(s) ******************");
        for (let i = 0; i < results.length; i++) {
            const flowRateAllocation = monthlyFlowRate * (toNum(percentages[i]) / 100);
            console.log(
                "Expect",
                names[userAddress] + " to " + names[pipeAddresses[i]] + " flow rate:",
                toNum(results[i]),
                "to be less than or equal to",
                monthlyToSecondRate(flowRateAllocation),
            );

            // Note: flow rate will always be less than or equal to our desired flow rate as we set the
            // flow rate based on `getMaximumFlowRateFromDeposit`
            expect(toNum(results[i])).to.be.lessThanOrEqual(monthlyToSecondRate(flowRateAllocation));
        }
        console.log("******************************************************\n");
    };

    /** Modifies flow from sender to receiver of monthly flow rate and
     * the receiver (super app) redirects these flows to multiple pipes.
     * This function returns an array containing information about the
     * resulting flow rates into the different pipes.
     */
    const modifyFlow = async (
        func: any,
        superValve: SuperValve,
        sender: string,
        receiver: string,
        data: string,
        monthlyFlowRate?: number,
    ) => {
        const formattedFlowRate = monthlyFlowRate ? ethers.utils.formatUnits(monthlyToSecondRate(monthlyFlowRate)) : "";
        const type = monthlyFlowRate == null ? "Delete" : func === sf.cfa.createFlow ? "Create" : "Update";
        console.log(`\n****************** ${type} Flow Test ******************`);
        const message =
            `${type} flow from ${names[sender]} to ${names[receiver]}` +
            (monthlyFlowRate ? ` at a flowRate of ${formattedFlowRate} fDAIx/s.` : ".");
        console.log(message);
        try {
            if (monthlyFlowRate) {
                await func({
                    superToken: sf.tokens.fDAIx.address,
                    sender,
                    receiver,
                    flowRate: monthlyToSecondRate(monthlyFlowRate),
                    userData: data,
                });
            } else {
                await func({
                    superToken: sf.tokens.fDAIx.address,
                    sender,
                    receiver,
                    userData: data,
                });
            }
        } catch (err) {
            console.error(`${type} Flow Error: ${err}`);
        }

        const userData = decodeUserData(data);
        const pipeAddresses: string[] = userData[0];
        const promises = pipeAddresses.map(x => superValve.getUserPipeFlowRate(sender, x));
        const results = await Promise.all(promises);

        return results;
    };

    describe.skip("Admin Permissions Tests", () => {
        it("Should allow admin to add/remove pipe addresses", async () => {
            await expect(Admin.SuperValve.addPipeAddress(Alice.address))
                .to.emit(Admin.SuperValve, "NewPipeAddress")
                .withArgs(Alice.address);
            await expect(Admin.SuperValve.removePipeAddress(Alice.address))
                .to.emit(Admin.SuperValve, "RemovedPipeAddress")
                .withArgs(Alice.address);
        });

        it("Should not allow adding/removing invalid pipe addresses.", async () => {
            await expect(Admin.SuperValve.addPipeAddress(Admin.VaultPipe2.address)).to.revertedWith(
                "SuperValve: This pipe address is already a valid pipe address.",
            );
            await expect(Admin.SuperValve.removePipeAddress(Alice.address)).to.revertedWith(
                "SuperValve: This pipe address is not a valid pipe address.",
            );
        });

        it("Should not allow non admin to add/remove pipe addresses", async () => {
            await expect(Bob.SuperValve.addPipeAddress(Alice.address)).to.revertedWith(
                "SuperValve: You don't have permissions for this action.",
            );
            await expect(Bob.SuperValve.removePipeAddress(Admin.VaultPipe.address)).to.revertedWith(
                "SuperValve: You don't have permissions for this action.",
            );
        });
    });

    describe("Create Flow Tests", () => {
        it("Should be able to create flow to just a single pipe.", async () => {
            const userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "100" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);

            const usersData = userAddresses.map(x => ({ user: x, monthlyFlowRate: 150 }));
            for (let i = 0; i < usersData.length; i++) {
                const results = await modifyFlow(
                    sf.cfa.createFlow,
                    Admin.SuperValve,
                    usersData[i].user,
                    superValveAddress,
                    userData,
                    usersData[i].monthlyFlowRate,
                );
                checkUserFlowRateResults(usersData[i].monthlyFlowRate, results, userData, usersData[i].user);
            }
        });

        it("Should be able to create a flow into two pipes.", async () => {
            const userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            const usersData = userAddresses.map(x => ({ user: x, monthlyFlowRate: 150 }));
            for (let i = 0; i < usersData.length; i++) {
                const results = await modifyFlow(
                    sf.cfa.createFlow,
                    Admin.SuperValve,
                    usersData[i].user,
                    superValveAddress,
                    userData,
                    usersData[i].monthlyFlowRate,
                );
                checkUserFlowRateResults(usersData[i].monthlyFlowRate, results, userData, usersData[i].user);
            }
        });
    });

    describe("Update Flow Tests", () => {
        it("Should be able to update increase and decrease flow rate.", async () => {
            const userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await modifyFlow(
                sf.cfa.createFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);

            // increase flow rate
            results = await modifyFlow(
                sf.cfa.updateFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                250,
            );
            checkUserFlowRateResults(250, results, userData, Admin.address);

            // decrease flow rate
            results = await modifyFlow(
                sf.cfa.updateFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                50,
            );
            checkUserFlowRateResults(50, results, userData, Admin.address);

            // increase flow rate
            results = await modifyFlow(
                sf.cfa.updateFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                550,
            );
            checkUserFlowRateResults(550, results, userData, Admin.address);
        });

        it("Should be able to change their allocations with flow rate staying constant.", async () => {
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await modifyFlow(
                sf.cfa.createFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);

            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "30" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "70" },
            ]);

            results = await modifyFlow(
                sf.cfa.updateFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);
        });

        it("Should be able to remove allocation completely to one pipe.", async () => {
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await modifyFlow(
                sf.cfa.createFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);

            // remove allocation completely from one pipe
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "100" },
            ]);

            results = await modifyFlow(
                sf.cfa.updateFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);
        });

        it("Should be able to change their allocations and their flow rate.", async () => {
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await modifyFlow(
                sf.cfa.createFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);

            // remove allocation completely from one pipe
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "43" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "57" },
            ]);

            results = await modifyFlow(
                sf.cfa.updateFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                342,
            );
            checkUserFlowRateResults(342, results, userData, Admin.address);
        });
    });

    describe("Delete Flow Tests", () => {
        it("Should be able to delete flow", async () => {
            const deleteFlowData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create first flow
            let results = await modifyFlow(
                sf.cfa.createFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                150,
            );
            checkUserFlowRateResults(150, results, userData, Admin.address);

            // delete flow
            results = await modifyFlow(
                sf.cfa.deleteFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                deleteFlowData,
            );
            checkUserFlowRateResults(0, results, userData, Admin.address);

            // create another flow
            results = await modifyFlow(
                sf.cfa.createFlow,
                Admin.SuperValve,
                Admin.address,
                superValveAddress,
                userData,
                250,
            );
            checkUserFlowRateResults(250, results, userData, Admin.address);
        });
    });

    /**************************************************************************
     * Withdraw Test Cases
     *************************************************************************/
});

// TODO: Should not allow create flow rate where flow rate is 0
// Should not allow create flow rate where allocations don't add up to 100 (greater or less than)
// Should not allow update flow rate where flow rate is 0
// Should not allow update flow rate where allocations don't add up to 100 (greater or less than)
