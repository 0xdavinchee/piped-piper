import { Button, Card, CardContent, CircularProgress, Container, TextField, Typography } from "@material-ui/core";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { Web3Provider } from "@ethersproject/providers";
import { useParams } from "react-router-dom";
import { useCallback, useEffect, useMemo, useState } from "react";
import { initializeContract, requestAccount } from "../utils/helpers";
import { IPipeData, IUserPipeData } from "../utils/interfaces";
import VaultPipeCard from "./VaultPipeCard";
import { ethers } from "ethers";

interface IValveProps {
    readonly currency: string;
    readonly userAddress: string;
}

// TODO: there is no easy way to get array data directly via ethereum - subgraph may be needed for this
// you can only get one element at a time.

// TODO: this should come from on chain, that is, a subgraph which gets us a list of the valid
// vault pipe addresses, in addition, we should probably have name and stuff on the VaultPipe contract.

// TODO: Cannot redirect streams to multiple pipes only one.
// Cannot update flow to higher amount currently.
const PIPES: IPipeData[] = [
    // { pipeAddress: "0xe28f4e47ab14d2debe741781761798f557f16c91", name: "fUSDC Vault 1" },
    { pipeAddress: "0x79a42886aFd9ab2028e95262e7044263e6D29c6e", name: "fUSDC Vault 2" },
];
const FULLY_ALLOCATED = 100;

const Valve = (props: IValveProps) => {
    const { address }: { address: string } = useParams();
    const [loading, setLoading] = useState(true);
    const [time, setTime] = useState(new Date());
    const [token, setToken] = useState("");
    const [inputFlowRate, setInputFlowRate] = useState("");
    const [userFlowRate, setUserFlowRate] = useState("");
    const [valveFlowRate, setValveFlowRate] = useState("");
    const [numInflows, setNumInflows] = useState(0);
    const [userPipeData, setUserPipeData] = useState<IUserPipeData[]>([
        ...PIPES.map(x => ({ pipeAddress: x.pipeAddress, name: x.name, percentage: "" })),
    ]);
    const [pipeAddresses, setPipeAddresses] = useState<string[]>([]);
    const [sf, setSf] = useState<any>(); // TODO: move this to PipedPiper.tsx so nav has access to this as well
    const [hasAllocations, setHasAllocations] = useState(false);
    const ethereum = (window as any).ethereum;

    const handleUpdateAllocation = (percentage: string, index: number) => {
        const dataToModify = userPipeData[index];
        setUserPipeData(Object.assign([], userPipeData, { [index]: { ...dataToModify, percentage } }));
    };

    const getAndSetFlowData = async (tokenAddress: string) => {
        const netFlow = await sf.cfa.getNetFlow({ superToken: tokenAddress, account: address });
        const inflowData = await sf.cfa.listFlows({ superToken: tokenAddress, account: address, onlyInFlows: true });
        const flowData = await sf.cfa.getFlow({
            superToken: tokenAddress,
            sender: props.userAddress,
            receiver: address,
        });
        setNumInflows(inflowData.inFlows.length);
        setValveFlowRate(ethers.utils.formatUnits(netFlow));
        setUserFlowRate(ethers.utils.formatUnits(flowData.flowRate));
    };

    const createAllocation = async () => {
        const contract = initializeContract(true, address);
        if (!contract || !token) return;
        try {
            const data = userPipeData.map(x => ({
                pipeAddress: x.pipeAddress,
                percentage: formatPercentage(x.percentage),
            }));
            await requestAccount();
            const txn = await contract.setUserFlowData(data);
            await txn.wait();
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        }
    };
    const createOrUpdateFlow = async () => {
        if (Number(userFlowRate) > 0) {
            await updateFlow();
        } else {
            await createFlow();
        }
    };
    const createFlow = async () => {
        if (!sf || !token) return;
        try {
            const txn = await sf.cfa.createFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                flowRate: getFlowRate(inputFlowRate),
            });
            await txn.wait();
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        }
    };

    const updateFlow = async () => {
        if (!sf || !token) return;
        try {
            const txn = await sf.cfa.updateFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                flowRate: getFlowRate(inputFlowRate),
            });
            await txn.wait();
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        }
    };

    const deleteFlow = async () => {
        if (!sf || !token) return;
        try {
            const txn = await sf.cfa.deleteFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
            });
            await txn.wait();
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
    const formatPercentage = (x: string) => Number(Number(x).toFixed(1)) * 10;

    const getFlowRate = (x: string) => {
        const days = 30;
        const hours = 24;
        const minutes = 60;
        const seconds = 60;
        const denominator = days * hours * minutes * seconds;
        return Math.round((Number(x) / denominator) * 10 ** 18);
    };

    const isFullyAllocated = useMemo(() => {
        return (
            userPipeData
                .map(x => Number(x.percentage))
                .reduce((x, y) => {
                    return x + y;
                }, 0) === FULLY_ALLOCATED
        );
    }, [userPipeData]);

    // useEffect(() => {
    //     const timer = setTimeout(() => {
    //         setTime(new Date());
    //     }, 1000);

    //     return () => clearTimeout(timer);
    // });

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

            const token = await contract.acceptedToken();
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
                                <Typography variant="h5"># inflow streams</Typography>
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
                                    Total Flow Balance
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
                                onClick={() => createAllocation()}
                            >
                                Set Allocation
                            </Button>
                            <Button
                                className="button flow-button"
                                color="primary"
                                disabled={!inputFlowRate}
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
                                disabled={!userFlowRate}
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
