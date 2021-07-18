import { expect } from "./chai-setup";
import { BigNumber } from "ethers";
import hre, { ethers, getNamedAccounts, getUnnamedAccounts } from "hardhat";
import deployFramework from "@superfluid-finance/ethereum-contracts/scripts/deploy-framework";
import deployTestToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-test-token";
import deploySuperToken from "@superfluid-finance/ethereum-contracts/scripts/deploy-super-token";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { FakeVault, SuperValve, VaultPipe } from "../typechain";
import { setupUser } from "./utils";

interface IUserPipeData {
    pipeAddress: string;
    percentage: string;
}
interface IUser {
    address: string;
    FakeVault: FakeVault;
    FakeVault2: FakeVault;
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
    let Users: IUser[];

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

        console.log("Mint fDAI, approve fDAIx allowance and upgrade fDAI to fDAIx for users...");
        for (let i = 0; i < userAddresses.length; i++) {
            const address = userAddresses[i];
            await dai.mint(address, ethers.utils.parseUnits("10000").toString(), { from: userAddresses[0] });
            await dai.approve(daix.address, ethers.utils.parseUnits("10000").toString(), { from: address });
            await daix.upgrade(ethers.utils.parseUnits("10000").toString(), { from: address });
        }
        console.log("\n************** Superfluid Framework Setup Complete **************\n");

        console.log("\n************** Deploying SuperValve + Pipe Contract **************\n");
        const fakeVaultFactory = await ethers.getContractFactory("FakeVault");
        const vaultPipeFactory = await ethers.getContractFactory("VaultPipe");
        const superValveFactory = await ethers.getContractFactory("SuperValve");

        const fakeVault = await fakeVaultFactory.deploy(sf.tokens.fDAI.address, "fDAI Vault 1 Token", "fDAI");
        const vaultPipe = await vaultPipeFactory.deploy(daix.address, fakeVault.address);
        const fakeVault2 = await fakeVaultFactory.deploy(sf.tokens.fDAI.address, "fDAI Vault 2 Token", "fDAI");
        const vaultPipe2 = await vaultPipeFactory.deploy(daix.address, fakeVault2.address);
        const superValve = await superValveFactory.deploy(sf.host.address, sf.agreements.cfa.address, daix.address, [
            vaultPipe.address,
            vaultPipe2.address,
        ]);

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
            FakeVault2: fakeVault2 as FakeVault,
            VaultPipe: vaultPipe as VaultPipe,
            VaultPipe2: vaultPipe2 as VaultPipe,
            SuperValve: superValve as SuperValve,
        };

        Admin = await setupUser(userAddresses[0], contracts);
        Alice = await setupUser(userAddresses[1], contracts);
        Bob = await setupUser(userAddresses[2], contracts);
        Users = [Admin, Alice, Bob];
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

    const getRandomAllocationsUserData = () => {
        const randomPercentage = Math.floor(Math.random() * 101);
        const pipePercentage = randomPercentage.toString();
        const pipe2Percentage = (100 - randomPercentage).toString();
        return getModifyFlowUserData([
            { pipeAddress: Admin.VaultPipe.address, percentage: pipePercentage },
            { pipeAddress: Admin.VaultPipe2.address, percentage: pipe2Percentage },
        ]);
    };

    const decodeUserData = (encodedData: string) => {
        return encoder.decode(["address[]", "int96[]"], encodedData);
    };

    const checkModifyFlowResults = (
        monthlyFlowRate: number,
        userToPipeFlowRates: BigNumber[],
        userToPipeAllocations: BigNumber[],
        userData: string,
        userAddress: string,
    ) => {
        const data = decodeUserData(userData);
        const pipeAddresses: string[] = data[0];
        const percentages = data[1];
        console.log("****************** User to Pipe Flow Rate(s) ******************");
        for (let i = 0; i < userToPipeFlowRates.length; i++) {
            const flowRateAllocation = monthlyFlowRate * (toNum(percentages[i]) / 100);
            console.log(
                "Expect",
                names[userAddress] + " to " + names[pipeAddresses[i]] + " flow rate (" + percentages[i] + "%)",
                toNum(userToPipeFlowRates[i]),
                "to be less than or equal to",
                monthlyToSecondRate(flowRateAllocation),
            );

            // Note: flow rate will always be less than or equal to our desired flow rate as we set the
            // flow rate based on `getMaximumFlowRateFromDeposit`
            expect(toNum(userToPipeFlowRates[i])).to.be.lessThanOrEqual(monthlyToSecondRate(flowRateAllocation));

            // However, our allocation % must remain the same.
            expect(toNum(userToPipeAllocations[i])).to.be.eq(toNum(percentages[i]));
        }
        console.log("******************************************************\n");
    };

    const checkRevertResults = async (revertedFunc: any, revertMsg: string) => {
        console.log("\nExpect to be reverted with:", revertMsg, "\n");
        await expect(revertedFunc).to.be.revertedWith(revertMsg);
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
            (monthlyFlowRate
                ? ` at a flowRate of ${formattedFlowRate} fDAIx/s (monthly: ${monthlyFlowRate} fDAIx).`
                : ".");
        console.log(message);
        try {
            if (monthlyFlowRate) {
                await func({
                    superToken: daix.address,
                    sender,
                    receiver,
                    flowRate: monthlyToSecondRate(monthlyFlowRate),
                    userData: data,
                });
            } else {
                await func({
                    superToken: daix.address,
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
        const userPipeFlowRatePromises = pipeAddresses.map(x => superValve.getUserPipeFlowRate(sender, x));
        const userPipeAllocationPromises = pipeAddresses.map(x => superValve.getUserPipeAllocation(sender, x));
        const userToPipeFlowRates = await Promise.all(userPipeFlowRatePromises);
        const userToPipeAllocations = await Promise.all(userPipeAllocationPromises);

        return [userToPipeFlowRates, userToPipeAllocations];
    };

    /**
     * Function for testing cases where we expect it to revert, returns the promise that will be reverted.
     * @param func
     * @param sender
     * @param receiver
     * @param data
     * @param monthlyFlowRate
     * @returns
     */
    const getRevertedModifyFlowPromise = async (
        func: any,
        sender: string,
        receiver: string,
        data: string,
        monthlyFlowRate?: number,
    ) => {
        const type = monthlyFlowRate == null ? "Delete" : func === sf.cfa.createFlow ? "Create" : "Update";
        console.log(`\n****************** Expect ${type} Flow Reverted ******************`);
        const funcData =
            monthlyFlowRate == null
                ? {
                      superToken: daix.address,
                      sender,
                      receiver,
                      userData: data,
                  }
                : {
                      superToken: daix.address,
                      sender,
                      receiver,
                      flowRate: ethers.BigNumber.from(monthlyToSecondRate(monthlyFlowRate)),
                      userData: data,
                  };
        return func(funcData);
    };

    /**
     * Helper to execute Create/Update/Delete Flow to SuperValve test.
     * Has expect checks to ensure flow rate is as expected and also has console.log's
     * indicating what it is testing.
     * @param func
     * @param userAddress
     * @param flowRate
     * @param userData
     * @param incrementer
     */
    const executeModifyFlowTest = async (
        func: any,
        userAddress: string,
        flowRate: number | null,
        userData?: string,
        incrementer?: number,
    ) => {
        const inputUserData = userData ? userData : getRandomAllocationsUserData();
        const inputFlowRate = flowRate ? flowRate : Math.floor(Math.random() * 1000) + (incrementer || 0);
        const [userToPipeFlowRates, userToPipeAllocations] = await modifyFlow(
            func,
            Admin.SuperValve,
            userAddress,
            superValveAddress,
            inputUserData,
            func === sf.cfa.deleteFlow ? undefined : inputFlowRate,
        );
        checkModifyFlowResults(inputFlowRate, userToPipeFlowRates, userToPipeAllocations, inputUserData, userAddress);
    };

    /**
     * Runs executeModifyFlowTest for all users.
     * @param func
     * @param flowRate if this is null, we randomize this
     * @param userData if this is null, we randomize this
     * @param incrementer if this is null, it is 0
     */
    const executeModifyFlowTestForUsers = async (
        func: any,
        flowRate: number | null,
        userData?: string,
        incrementer?: number,
    ) => {
        for (let i = 0; i < userAddresses.length; i++) {
            await executeModifyFlowTest(func, userAddresses[i], flowRate, userData, incrementer);
        }
    };

    const executeExpectRevertModifyFlowTest = async (
        func: any,
        sender: string,
        userData: string,
        revertString: string,
        flowRate?: number,
    ) => {
        let revertedModifyFlowPromise = getRevertedModifyFlowPromise(
            func,
            sender,
            superValveAddress,
            userData,
            flowRate,
        );
        await checkRevertResults(revertedModifyFlowPromise, revertString);
    };

    /**
     * Execute withdrawal test for all users, we expect the userFlowBalance to be exactly 0 if
     * {hasFlows} is false as we have stopped flows from the user. We expect the userFlowBalance
     * to be less than the initial userFlowBalance in the event that the user hasn't stopped their
     * flows. Note: difference will be negative in these cases as more funds will have flowed from
     * the user since getting their total flow balance so their withdrawal will be larger than their
     * balance.
     * @param hasFlows whether the flows to the superValve has been stopped
     */
    const executeWithdrawalTestForUsers = async (hasFlows: boolean) => {
        const PIPE_ADDRESSES = [Admin.VaultPipe.address, Admin.VaultPipe2.address];
        let preWithdrawalFlowBalance = [];

        // get user total flowed
        for (let i = 0; i < userAddresses.length; i++) {
            const [userFlowBalance] = await Admin.SuperValve.getUserTotalFlowedBalance(userAddresses[i]);
            preWithdrawalFlowBalance.push(userFlowBalance);
        }

        // withdraw for each user
        for (let i = 0; i < Users.length; i++) {
            const txn = await Users[i].SuperValve.withdraw(PIPE_ADDRESSES);
            const res = await txn.wait();
            const withdrawalSignature = ethers.utils.solidityKeccak256(["string"], ["Withdrawal(uint256)"]);
            const withdrawalEvent = res.logs.filter(x => x.topics.includes(withdrawalSignature))[0];
            const withdrawalAmount = withdrawalEvent
                ? ethers.BigNumber.from(withdrawalEvent.data)
                : ethers.BigNumber.from(0);
            const flowBalanceNum = toNum(preWithdrawalFlowBalance[i]);
            const withdrawalAmountNum = toNum(withdrawalAmount);
            console.log(
                names[Users[i].address] + " withdrawing from SuperValve, total flowed balance: " + flowBalanceNum,
            );
            console.log("Actual Withdrawal Amount: ", withdrawalAmountNum);
            const difference = flowBalanceNum - withdrawalAmountNum;
            console.log("Difference: ", difference);
        }

        // we test less than here because they still have ongoing flows after withdrawal, so it probably won't be 0
        if (hasFlows) {
            console.log("Expect all the flow balances after withdrawal to be less than pre withdrawal balance.");
            for (let i = 0; i < userAddresses.length; i++) {
                const [userFlowBalance] = await Admin.SuperValve.getUserTotalFlowedBalance(userAddresses[i]);
                console.log(
                    "Expect " +
                        names[userAddresses[i]] +
                        " flow balance after withdrawal: " +
                        userFlowBalance +
                        " to be less than flow balance before withdrawal: " +
                        preWithdrawalFlowBalance[i],
                );
                expect(toNum(userFlowBalance)).to.be.lessThan(toNum(preWithdrawalFlowBalance[i]));
            }

            // we know balance will be 0 because the user has stopped their flows and withdrawn
        } else {
            console.log("Expect all the user flow balances to be 0 after withdrawal.");
            // get user total flowed after withdrawal
            for (let i = 0; i < userAddresses.length; i++) {
                const [userFlowBalance] = await Admin.SuperValve.getUserTotalFlowedBalance(userAddresses[i]);
                console.log(
                    "Expect " +
                        names[userAddresses[i]] +
                        " flow balance after withdrawal: " +
                        userFlowBalance +
                        " to be 0 after withdrawal and stopping flows.",
                );
                expect(toNum(userFlowBalance)).to.be.eq(0);
            }
        }
    };

    describe("Admin Permissions Tests", () => {
        it("Should handle add/remove pipe address cases", async () => {
            await expect(Admin.SuperValve.addPipeAddress(Alice.address))
                .to.emit(Admin.SuperValve, "NewPipeAddress")
                .withArgs(Alice.address);
            await expect(Admin.SuperValve.removePipeAddress(Alice.address))
                .to.emit(Admin.SuperValve, "RemovedPipeAddress")
                .withArgs(Alice.address);

            // expect valid pipe addresses
            expect(await Admin.SuperValve.getValidPipeAddresses()).to.have.same.members([
                Admin.VaultPipe.address,
                Admin.VaultPipe2.address,
            ]);

            // revert cases
            await checkRevertResults(
                Admin.SuperValve.addPipeAddress(Admin.VaultPipe2.address),
                "SuperValve: This pipe address is already a valid pipe address.",
            );
            await checkRevertResults(
                Admin.SuperValve.removePipeAddress(Alice.address),
                "SuperValve: This pipe address is not a valid pipe address.",
            );
            await checkRevertResults(
                Bob.SuperValve.addPipeAddress(Alice.address),
                "SuperValve: You don't have permissions for this action.",
            );
            await checkRevertResults(
                Bob.SuperValve.removePipeAddress(Admin.VaultPipe.address),
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

            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null, userData);
        });

        it("Should be able to create a flow into two pipes.", async () => {
            const userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null, userData);
        });

        it("Should revert when users try to create a flow with flowrate of 0.", async () => {
            const userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            await executeExpectRevertModifyFlowTest(
                sf.cfa.createFlow,
                userAddresses[0],
                userData,
                "CFA: invalid flow rate",
                0,
            );
        });

        it("Should revert when users try to create a flow with allocations that don't add up to 100.", async () => {
            // when allocations > 100%
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "60" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.createFlow,
                userAddresses[0],
                userData,
                "SuperValve: Your allocations must add up to 100% when creating or updating or be 0%.",
                150,
            );

            // when allocations < 100%
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "20" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.createFlow,
                userAddresses[0],
                userData,
                "SuperValve: Your allocations must add up to 100% when creating or updating or be 0%.",
                150,
            );

            // when attempting with one allocation > 100%
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "120" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.createFlow,
                userAddresses[0],
                userData,
                "SuperValve: Your percentage is outside of the acceptable range.",
                150,
            );
        });

        it("Should revert when users try to create a flow to an invalid address.", async () => {
            let userData = getModifyFlowUserData([
                { pipeAddress: Alice.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            await executeExpectRevertModifyFlowTest(
                sf.cfa.createFlow,
                userAddresses[0],
                userData,
                "SuperValve: The pipe address you have entered is not valid.",
                150,
            );
        });
    });

    describe("Update Flow Tests", () => {
        it("Should be able to update increase and decrease flow rate.", async () => {
            const userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);

            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null, userData);

            // increase flow rate (increments num between 0-1000 by 1000)
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, null, userData, 1000);

            // decrease flow rate
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, null, userData);
        });

        it("Should be able to change their allocations with flow rate staying constant.", async () => {
            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, 150);

            // update allocation whilst keeping flowRate the same
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, 150);
        });

        it("Should be able to remove allocation completely to one pipe.", async () => {
            // create initial flow rate
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, 150);

            // remove allocation completely from one pipe
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "100" },
            ]);
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, 150, userData);
        });

        it("Should be able to change their allocations and their flow rate.", async () => {
            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);

            // update flowRate and allocations
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, null);
        });

        it("Should be able to update allocations and flow rate to same amounts.", async () => {
            // remove allocation completely from one pipe
            let userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "50" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "50" },
            ]);
            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, 150, userData);

            // update flowRate and allocations
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, 150, userData);
        });

        it("Should properly calculate total valve balance", async () => {
            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);

            let totalValveBalanceByUserFlowBalance = 0;
            let totalValveFlowRate = 0;
            const pipeAddresses = [Admin.VaultPipe.address, Admin.VaultPipe2.address];

            for (let i = 0; i < userAddresses.length; i++) {
                // sum the flowRates of all users for all pipeAddresses
                for (let j = 0; j < pipeAddresses.length; j++) {
                    const userPipeAllocation = await Admin.SuperValve.getUserPipeAllocation(
                        userAddresses[i],
                        pipeAddresses[j],
                    );
                    totalValveFlowRate += toNum(userPipeAllocation);
                }

                // sum totalValveBalance w/ userBalance
                const [userBalance] = await Admin.SuperValve.getUserTotalFlowedBalance(userAddresses[i]);
                totalValveBalanceByUserFlowBalance += toNum(userBalance);
            }
            const [totalValveBalance] = await Admin.SuperValve.getTotalValveBalance(totalValveFlowRate);

            expect(totalValveBalanceByUserFlowBalance).to.eq(toNum(totalValveBalance));
        });

        it("Should not allow update flow rate to 0.", async () => {
            let userData = getRandomAllocationsUserData();

            await executeModifyFlowTest(sf.cfa.createFlow, userAddresses[0], 150);

            await executeExpectRevertModifyFlowTest(
                sf.cfa.updateFlow,
                userAddresses[0],
                userData,
                "CFA: invalid flow rate",
                0,
            );
        });

        it("Should not allow update flow rate with allocations that don't add up to 100.", async () => {
            let userData;

            await executeModifyFlowTest(sf.cfa.createFlow, userAddresses[0], 150);

            // update with pipe allocation outside of >= 0 && <= 100
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "-20" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "100" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.updateFlow,
                userAddresses[0],
                userData,
                "SuperValve: Your percentage is outside of the acceptable range.",
                150,
            );

            // update with total pipe allocation > 100
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "20" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "100" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.updateFlow,
                userAddresses[0],
                userData,
                "SuperValve: Your allocations must add up to 100% when creating or updating or be 0%.",
                150,
            );

            // update with total pipe allocation < 100
            userData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "20" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "35" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.updateFlow,
                userAddresses[0],
                userData,
                "SuperValve: Your allocations must add up to 100% when creating or updating or be 0%.",
                150,
            );
        });
    });

    describe("Delete Flow Tests", () => {
        it("Should be able to delete flow", async () => {
            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);

            const deleteFlowData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);
            // delete flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.deleteFlow, 0, deleteFlowData);

            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);
        });

        it("Should not allow you to delete a flow if it doesn't exist.", async () => {
            const deleteFlowData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);
            await executeExpectRevertModifyFlowTest(
                sf.cfa.deleteFlow,
                userAddresses[0],
                deleteFlowData,
                "CFA: flow does not exist",
            );
        });
    });

    describe("Withdrawal/Deposit Tests", () => {
        it("Should be able to withdraw funds while flows are ongoing and after stopping.", async () => {
            const deleteFlowData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);

            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);

            // go 30 days into the future
            await hre.network.provider.send("evm_increaseTime", [86400 * 30]);
            await hre.network.provider.send("evm_mine");

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(true);

            // go 30 days into the future
            await hre.network.provider.send("evm_increaseTime", [86400 * 30]);
            await hre.network.provider.send("evm_mine");

            // delete flows
            await executeModifyFlowTestForUsers(sf.cfa.deleteFlow, 0, deleteFlowData);

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(false);
        });

        it("Should be able to deposit and withdraw funds into vaults with ongoing flows and after stopping flows.", async () => {
            const deleteFlowData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);

            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);

            // go 30 days into the future
            await hre.network.provider.send("evm_increaseTime", [86400 * 30]);
            await hre.network.provider.send("evm_mine");

            // deposit funds into the vaults
            await Promise.all([Admin.VaultPipe.depositFundsIntoVault(), Admin.VaultPipe2.depositFundsIntoVault()]);

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(true);

            // delete flows
            await executeModifyFlowTestForUsers(sf.cfa.deleteFlow, 0, deleteFlowData);

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(false);
        });

        it("Should be able to handle deposit and withdraw funds into vaults with flow updates.", async () => {
            const deleteFlowData = getModifyFlowUserData([
                { pipeAddress: Admin.VaultPipe.address, percentage: "0" },
                { pipeAddress: Admin.VaultPipe2.address, percentage: "0" },
            ]);

            // create flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.createFlow, null);

            // go 30 days into the future
            await hre.network.provider.send("evm_increaseTime", [86400 * 30]);
            await hre.network.provider.send("evm_mine");

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(true);

            // deposit funds into the vaults
            await Promise.all([Admin.VaultPipe.depositFundsIntoVault(), Admin.VaultPipe2.depositFundsIntoVault()]);

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(true);

            // update flow to superValve
            await executeModifyFlowTestForUsers(sf.cfa.updateFlow, null);

            // go 30 days into the future
            await hre.network.provider.send("evm_increaseTime", [86400 * 30]);
            await hre.network.provider.send("evm_mine");

            // deposit funds into the vaults
            await Promise.all([Admin.VaultPipe.depositFundsIntoVault(), Admin.VaultPipe2.depositFundsIntoVault()]);

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(true);

            // delete flows
            await executeModifyFlowTestForUsers(sf.cfa.deleteFlow, 0, deleteFlowData);

            // withdraw funds from super valve and execute tests
            await executeWithdrawalTestForUsers(false);
        });

        it("Should not be able to withdraw from invalid pipe address.", async () => {
            const INVALID_PIPE_ADDRESSES = [Alice.address, Bob.address];

            // create flow to superValve
            await executeModifyFlowTest(sf.cfa.createFlow, userAddresses[0], null);

            // go 30 days into the future
            await hre.network.provider.send("evm_increaseTime", [86400 * 30]);
            await hre.network.provider.send("evm_mine");

            await expect(Admin.SuperValve.withdraw(INVALID_PIPE_ADDRESSES)).to.be.revertedWith(
                "SuperValve: This is not a registered vault address.",
            );
        });
    });
});
