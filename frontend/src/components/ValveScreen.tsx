import { Button, Card, CardContent, CircularProgress, Container, TextField, Typography } from "@material-ui/core";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { Web3Provider } from "@ethersproject/providers";
import { useParams } from "react-router-dom";
import { useEffect, useMemo, useState } from "react";
import { initializeContract } from "../utils/helpers";
import { IPipeData, IUserPipeData } from "../utils/interfaces";
import VaultPipeCard from "./VaultPipeCard";
import { ethers } from "ethers";

interface IValveProps {
    readonly currency: string;
    readonly userAddress: string;
}

interface IFlowData {
    readonly flowRate: string;
    readonly receiver: string;
    readonly sender: string;
}

// TODO: this should come from on chain, that is, a subgraph which gets us a list of the valid
// vault pipe addresses, in addition, we should probably have name and stuff on the VaultPipe contract.
// TODO: figure out why we cannot stop flows - why isn't this wokring.
const PIPE_1 = "0x37e465Bfb567a9081c962676ed604Cf9adD7dcfA";
const PIPE_2 = "0x23aA18C5a88Abf824d43375c03D0029A332705C8";
const PIPES: IPipeData[] = [
    { pipeAddress: PIPE_1, name: "fUSDC Vault 1" },
    { pipeAddress: PIPE_2, name: "fUSDC Vault 2" },
];
const FULLY_ALLOCATED = 100;

const Valve = (props: IValveProps) => {
    const { address }: { address: string } = useParams();
    // Misc State
    const [loading, setLoading] = useState(true);
    const [time, setTime] = useState(new Date());

    // Superfluid State
    const [sf, setSf] = useState<any>(); // TODO: move this to PipedPiper.tsx so nav has access to this as well
    const [token, setToken] = useState("");

    // Valve Flow State
    const [valveFlowRate, setValveFlowRate] = useState("");
    const [numInflows, setNumInflows] = useState(0);

    // User Flow State
    const [inputFlowRate, setInputFlowRate] = useState("");
    const [userFlowRate, setUserFlowRate] = useState("");
    const [userPipeData, setUserPipeData] = useState<IUserPipeData[]>([
        ...PIPES.map(x => ({ pipeAddress: x.pipeAddress, name: x.name, percentage: "" })),
    ]);
    const [userTotalFlowedBalance, setUserTotalFlowedBalance] = useState({
        totalFlowed: 0,
        timestamp: 0,
    });
    const [pipeAddresses, setPipeAddresses] = useState<string[]>([]);
    const ethereum = (window as any).ethereum;

    const handleUpdateAllocation = (percentage: string, index: number) => {
        const dataToModify = userPipeData[index];
        setUserPipeData(Object.assign([], userPipeData, { [index]: { ...dataToModify, percentage } }));
    };

    const getAndSetFlowData = async (tokenAddress: string) => {
        const valveFlowData: { inFlows: IFlowData[]; outFlows: IFlowData[] } = await sf.cfa.listFlows({
            superToken: tokenAddress,
            account: address,
        });
        const userToValveFlowData = await sf.cfa.getFlow({
            superToken: tokenAddress,
            sender: props.userAddress,
            receiver: address,
        });

        const valveFlowRate = sumFlows(valveFlowData.inFlows);

        setNumInflows(valveFlowData.inFlows.length);
        setValveFlowRate(ethers.utils.formatUnits(valveFlowRate));
        setUserFlowRate(ethers.utils.formatUnits(userToValveFlowData.flowRate));
    };

    const getRelevantFlowData = async (sf: any, tokenAddress: string) => {
        if (sf == null) return;
        const inflowData = await sf.cfa.listFlows({ superToken: tokenAddress, account: props.userAddress });
        console.log("inflowData", inflowData);
        const userToValveFlow = await sf.cfa.getFlow({
            superToken: tokenAddress,
            sender: props.userAddress,
            receiver: address,
        });
        console.log("userToValveFlow", userToValveFlow);
        const flowData1 = await sf.cfa.getFlow({
            superToken: tokenAddress,
            sender: address,
            receiver: PIPE_1,
        });
        const flowData2 = await sf.cfa.getFlow({
            superToken: tokenAddress,
            sender: address,
            receiver: PIPE_2,
        });
        console.log("flowData1", flowData1);
        console.log("flowData2", flowData2);
    };

    const createOrUpdateFlow = async () => {
        if (Number(userFlowRate) > 0) {
            await updateFlow();
        } else {
            await createFlow();
        }
    };

    const sumFlows = (flows: IFlowData[]) => flows.map(x => Number(x.flowRate)).reduce((x, y) => x + y, 0);

    const getCreateUpdateFlowUserData = () => {
        const encoder = ethers.utils.defaultAbiCoder;
        return encoder.encode(
            ["address[]", "int96[]"],
            [userPipeData.map(x => x.pipeAddress), userPipeData.map(x => formatPercentage(x.percentage))],
        );
    };

    const getDeleteFlowUserData = () => {
        const encoder = ethers.utils.defaultAbiCoder;
        return encoder.encode(
            ["address[]", "int96[]"],
            [userPipeData.map(x => x.pipeAddress), userPipeData.map(x => formatPercentage("0"))],
        );
    };

    const createFlow = async () => {
        if (!sf || !token) return;
        try {
            await sf.cfa.createFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                flowRate: getFlowRate(inputFlowRate),
                userData: getCreateUpdateFlowUserData(),
            });
            await getAndSetFlowData(token);
            await getRelevantFlowData(sf, token);
        } catch (error) {
            console.error(error);
        }
    };

    const updateFlow = async () => {
        if (!sf || !token) return;
        try {
            await sf.cfa.updateFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                flowRate: getFlowRate(inputFlowRate),
                userData: getCreateUpdateFlowUserData(),
            });
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        }
    };

    const deleteFlow = async () => {
        if (!sf || !token) return;
        try {
            await sf.cfa.deleteFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                userData: getDeleteFlowUserData(),
            });
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        }
    };

    const withdrawFunds = async () => {
        const contract = initializeContract(true, address);
        if (!contract || !token || pipeAddresses.length === 0) return;
        try {
            const txn = await contract.withdraw(pipeAddresses);
            await txn.wait();
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        }
    };

    const getFlowRateText = (flowRate: string) => {
        return flowRate + " " + props.currency + " / second";
    };

    /**
     * This function formats the input percentage the user provides by multiplying
     * it by 10 (so it adds up to 1000 as defined in the backend).
     * @param x the percentage the user wants to format
     * @returns
     */
    const formatPercentage = (x: string) => Math.round(Number(x));

    const getFlowRate = (x: string) => {
        const days = 30;
        const hours = 24;
        const minutes = 60;
        const seconds = 60;
        const denominator = days * hours * minutes * seconds;
        return Math.round((Number(x) / denominator) * 10 ** 18);
    };

    /** Get the total user flowed balance:
     * The current user total flowed balance calculated on chain +
     * the difference between now and when we got this information * the user flow rate.
     */
    const totalUserFlowedBalance = useMemo(() => {
        console.log("test", userTotalFlowedBalance.timestamp);
        return (
            userTotalFlowedBalance.totalFlowed +
            (Date.now() / 1000 - userTotalFlowedBalance.timestamp / 1000) * Number(userFlowRate)
        );
    }, [time, userTotalFlowedBalance, userFlowRate]);
    const isFullyAllocated = useMemo(() => {
        return (
            userPipeData
                .map(x => Number(x.percentage))
                .reduce((x, y) => {
                    return x + y;
                }, 0) === FULLY_ALLOCATED
        );
    }, [userPipeData]);

    useEffect(() => {
        const timer = setTimeout(() => {
            setTime(new Date());
        }, 1000);

        return () => clearTimeout(timer);
    });

    useEffect(() => {
        if (!props.userAddress || !address) return;
        (async () => {
            const contract = initializeContract(true, address);
            if (contract == null || ethereum == null) return;
            const superfluidFramework = new SuperfluidSDK.Framework({
                ethers: new Web3Provider(ethereum),
            });
            await superfluidFramework.initialize();
            setSf(superfluidFramework);

            const pipeAddresses = await contract.getValidPipeAddresses();
            setPipeAddresses(pipeAddresses);

            // we kinda want to do this whenever the user updates //*** */
            const [userTotalFlowedBalance, timestamp] = await contract.getUserTotalFlowedBalance(props.userAddress);

            setUserTotalFlowedBalance({
                totalFlowed: userTotalFlowedBalance.toNumber(),
                timestamp: new Date(timestamp.toNumber() * 1000).getTime(),
            });
            console.log(userTotalFlowedBalance.toNumber());
            //*** */

            const token = await contract.acceptedToken();
            await getRelevantFlowData(superfluidFramework, token);
            setToken(token);
        })();
    }, [address, props.userAddress]);
    useEffect(() => {
        if (!sf || !token) return;
        (async () => {
            await getAndSetFlowData(token);
            setLoading(false);
        })();
    }, [sf, token]);

    return (
        <Container maxWidth="sm">
            {loading && <CircularProgress className="loading" />}
            {!loading && (
                <div className="valve-screen">
                    <div className="valve-cards">
                        <Card className="dashboard">
                            <CardContent>
                                <Typography variant="h4">Valve Flow Metrics</Typography>
                                <Typography variant="h5">Total Flow Balance</Typography>
                                <Typography variant="body1" color="textSecondary">
                                    Total Flow Balance
                                </Typography>
                                <Typography variant="h5">Flow Rate</Typography>
                                <Typography variant="body1" color="textSecondary">
                                    {getFlowRateText(valveFlowRate)}
                                </Typography>
                                <Typography variant="h5"># inflows</Typography>
                                <Typography variant="body1" color="textSecondary">
                                    {numInflows}
                                </Typography>
                            </CardContent>
                        </Card>
                        <Card className="dashboard">
                            <CardContent>
                                <Typography variant="h4">User Flow Metrics</Typography>
                                <Typography variant="h5">Total Flow Balance</Typography>
                                <Typography variant="body1" color="textSecondary">
                                    {totalUserFlowedBalance}
                                </Typography>
                                <Typography variant="h5">Flow Rate</Typography>
                                <Typography variant="body1" color="textSecondary">
                                    {getFlowRateText(userFlowRate)}
                                </Typography>
                            </CardContent>
                        </Card>
                    </div>
                    <div className="vault-selector">
                        <Typography variant="h3">Vaults</Typography>
                        <Typography className="text" variant="body1">
                            Below is a selection of vaults which you can choose to redirect your {props.currency} cash
                            flow into, you can select one or more of these vaults and specify the monthly flow rate and
                            the % of your flow which you'd like to deposit into each of the vaults.
                        </Typography>
                        <div className="vault-selection-container">
                            <div className="flow-rate-selector">
                                <TextField
                                    className="text-field"
                                    type="number"
                                    label="Flow rate"
                                    onChange={e => setInputFlowRate(e.target.value)}
                                    value={inputFlowRate}
                                />
                                <Typography variant="h6">{props.currency}/month</Typography>
                            </div>
                            <div className="pipe-vaults">
                                {userPipeData.map((x, i) => (
                                    <VaultPipeCard
                                        key={x.pipeAddress}
                                        data={x}
                                        index={i}
                                        handleUpdateAllocation={(x: string, i: number) => handleUpdateAllocation(x, i)}
                                    />
                                ))}
                            </div>
                            <Button
                                className="button flow-button"
                                color="primary"
                                disabled={!isFullyAllocated || !inputFlowRate}
                                variant="contained"
                                onClick={() => createOrUpdateFlow()}
                            >
                                {Number(userFlowRate) > 0 ? "Update" : "Create"} Flow
                            </Button>
                            <Button
                                className="button flow-button"
                                color="primary"
                                disabled={false} // TODO: check if withdrawable balance > 0
                                variant="contained"
                                onClick={() => withdrawFunds()}
                            >
                                Withdraw
                            </Button>
                            <Button
                                className="button flow-button"
                                color="secondary"
                                disabled={Number(userFlowRate) === 0}
                                variant="contained"
                                onClick={() => deleteFlow()}
                            >
                                Delete Flow
                            </Button>
                        </div>
                    </div>
                </div>
            )}
        </Container>
    );
};

export default Valve;
