import { Button, Card, CardContent, CircularProgress, Container, TextField, Typography } from "@material-ui/core";
import LinearProgress from '@material-ui/core/LinearProgress';
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { Web3Provider } from "@ethersproject/providers";
import { useParams } from "react-router-dom";
import { useEffect, useMemo, useState } from "react";
import { initializeContract } from "../utils/helpers";
import { IUserPipeData } from "../utils/interfaces";
import VaultPipeCard from "./VaultPipeCard";
import { ethers } from "ethers";

interface IValveProps {
    readonly currency: string;
    readonly userAddress: string;
    readonly setUserAddress: (x: string) => void;
}

interface IFlowData {
    readonly flowRate: string;
    readonly receiver: string;
    readonly sender: string;
}

interface ITotalFlowed {
    readonly totalFlowed: number;
    readonly timestamp: number;
}

const FULLY_ALLOCATED = 100;

const Valve = (props: IValveProps) => {
    const { address }: { address: string } = useParams();
    // Misc State
    const [loading, setLoading] = useState(true);
    const [time, setTime] = useState(new Date());
    const [fetching, setFetching] = useState(false);

    // Superfluid State
    const [sf, setSf] = useState<any>(); // TODO: move this to PipedPiper.tsx so nav has access to this as well
    const [token, setToken] = useState("");

    // Valve Flow State
    const [valveFlowRate, setValveFlowRate] = useState("");
    const [numInflows, setNumInflows] = useState(0);
    const [valveTotalFlowedBalance, setValveTotalFlowedBalance] = useState({
        totalFlowed: 0,
        timestamp: 0,
    });

    // User Flow State
    const [inputFlowRate, setInputFlowRate] = useState("");
    const [userFlowRate, setUserFlowRate] = useState("");
    const [userPipeData, setUserPipeData] = useState<IUserPipeData[]>([]);
    const [userTotalFlowedBalance, setUserTotalFlowedBalance] = useState({
        totalFlowed: 0,
        timestamp: 0,
    });
    const [pipeAddresses, setPipeAddresses] = useState<string[]>([]);
    const ethereum = (window as any).ethereum;

    /**************************************************************************
     * Data Retrieval Functions
     *************************************************************************/
    const getAndSetFlowData = async (tokenAddress: string) => {
        const contract = initializeContract(true, address);
        if (!contract) return;
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

        const [userTotalFlowedBalance, timestamp] = await contract.getUserTotalFlowedBalance(props.userAddress);

        setUserTotalFlowedBalance({
            totalFlowed: Number(userTotalFlowedBalance.toString()) / 10 ** 18,
            timestamp: new Date(timestamp.toNumber() * 1000).getTime(),
        });

        const [valveTotalFlowedBalance, valveTimestamp] = await contract.getTotalValveBalance(valveFlowRate);

        setValveTotalFlowedBalance({
            totalFlowed: Number(valveTotalFlowedBalance.toString()) / 10 ** 18,
            timestamp: new Date(valveTimestamp.toNumber() * 1000).getTime(),
        });

        const userFlowRate = ethers.utils.formatUnits(userToValveFlowData.flowRate);

        setNumInflows(valveFlowData.inFlows.length);

        setValveFlowRate(ethers.utils.formatUnits(valveFlowRate));

        setUserFlowRate(userFlowRate);

        setInputFlowRate(getMonthlyFlowRate(userFlowRate).toString());
    };

    /**************************************************************************
     * Create/Update/Delete Functions
     *************************************************************************/
    const createOrUpdateFlow = async () => {
        setFetching(true);
        if (Number(userFlowRate) > 0) {
            await updateFlow();
        } else {
            await createFlow();
        }
    };

    const createFlow = async () => {
        if (!sf || !token) return;
        try {
            await sf.cfa.createFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                flowRate: getFlowRatePerSecond(inputFlowRate),
                userData: getCreateUpdateFlowUserData(),
            });
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        } finally {
            setFetching(false);
        }
    };

    const updateFlow = async () => {
        if (!sf || !token) return;
        try {
            await sf.cfa.updateFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                flowRate: getFlowRatePerSecond(inputFlowRate),
                userData: getCreateUpdateFlowUserData(),
            });
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        } finally {
            setFetching(false);
        }
    };

    const deleteFlow = async () => {
        if (!sf || !token) return;
        try {
            setFetching(true);
            await sf.cfa.deleteFlow({
                superToken: token,
                sender: props.userAddress,
                receiver: address,
                userData: getDeleteFlowUserData(),
            });
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        } finally {
            setFetching(false);
        }
    };

    const withdrawFunds = async () => {
        const contract = initializeContract(true, address);
        if (!contract || !token || pipeAddresses.length === 0) return;
        try {
            setFetching(true);
            const txn = await contract.withdraw(pipeAddresses);
            await txn.wait();
            await getAndSetFlowData(token);
        } catch (error) {
            console.error(error);
        } finally {
            setFetching(false);
        }
    };

    /**************************************************************************
     * Formatting/Display Helper Functions
     *************************************************************************/
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

    const getFlowRateText = (flowRate: string) => {
        return formatNumbers(Number(flowRate)) + " " + props.currency + " / s";
    };

    /**
     * This function formats the input percentage the user provides by multiplying
     * it by 10 (so it adds up to 1000 as defined in the backend).
     * @param x the percentage the user wants to format
     * @returns
     */
    const formatPercentage = (x: string) => Math.round(Number(x));

    const sumFlows = (flows: IFlowData[]) => flows.map(x => Number(x.flowRate)).reduce((x, y) => x + y, 0);

    const getFlowRatePerSecond = (monthlyFlowRate: string) => {
        const days = 30;
        const hours = 24;
        const minutes = 60;
        const seconds = 60;
        const denominator = days * hours * minutes * seconds;
        return Math.round((Number(monthlyFlowRate) / denominator) * 10 ** 18);
    };

    const getMonthlyFlowRate = (secondFlowRate: string) => {
        const days = 30;
        const hours = 24;
        const minutes = 60;
        const seconds = 60;
        const secondsPerMonth = days * hours * minutes * seconds;
        return Math.round(Number(secondFlowRate) * secondsPerMonth);
    };

    const formatNumbers = (x: number) => {
        return x.toFixed(5);
    };

    const getTotalFlowedBalance = (totalFlowedData: ITotalFlowed, flowRate: string) => {
        return formatNumbers(
            totalFlowedData.totalFlowed + (Date.now() / 1000 - totalFlowedData.timestamp / 1000) * Number(flowRate),
        );
    };

    const handleUpdateAllocation = (percentage: string, index: number) => {
        const dataToModify = userPipeData[index];
        setUserPipeData(Object.assign([], userPipeData, { [index]: { ...dataToModify, percentage } }));
    };

    /**************************************************************************
     * UseMemo Variables
     *************************************************************************/
    /** Get the total user flowed balance:
     * The current user total flowed balance calculated on chain +
     * the difference between now and when we got this information * the user flow rate.
     */
    const totalUserFlowedBalance = useMemo(() => {
        return getTotalFlowedBalance(userTotalFlowedBalance, userFlowRate);
    }, [time, userTotalFlowedBalance, userFlowRate]);

    const totalValveFlowedBalance = useMemo(() => {
        return getTotalFlowedBalance(valveTotalFlowedBalance, valveFlowRate);
    }, [time, valveTotalFlowedBalance, valveFlowRate]);

    const isFullyAllocated = useMemo(() => {
        return (
            userPipeData
                .map(x => Number(x.percentage))
                .reduce((x, y) => {
                    return x + y;
                }, 0) === FULLY_ALLOCATED
        );
    }, [userPipeData]);

    /**************************************************************************
     * UseEffect Hooks
     *************************************************************************/
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

    /**
     * Accounts Changed Hook
     */
    useEffect(() => {
        if (!ethereum) return;
        ethereum.on("accountsChanged", (accounts: string[]) => {
            props.setUserAddress(accounts[0].toLowerCase());
        });

        return () => {
            (window as any).ethereum.removeListener("accountsChanged", () => {});
        };
    }, []);

    useEffect(() => {
        (async () => {
            const contract = initializeContract(true, address);
            if (pipeAddresses.length === 0 || !contract) return;
            const allocations = await Promise.all(
                pipeAddresses.map(x => contract.getUserPipeAllocation(props.userAddress, x)),
            );
            const flowRates = await Promise.all(
                pipeAddresses.map(x => contract.getUserPipeFlowRate(props.userAddress, x)),
            );
            console.log(allocations);
            const formattedFlowRates = flowRates.map(x => x.toNumber() / 10 ** 18);
            const userPipeData = pipeAddresses.map((x, i) => ({
                pipeAddress: x,
                name: props.currency + " Vault " + i,
                percentage: allocations[i].toString(),
                flowRate: formatNumbers(Number(formattedFlowRates[i].toString())),
            }));
            setUserPipeData(userPipeData);
        })();
    }, [pipeAddresses, address, props.currency, userFlowRate]);

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
                                    {totalValveFlowedBalance} {props.currency}
                                </Typography>
                                <Typography variant="h5">Total Inflow Rate</Typography>
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
                                    {totalUserFlowedBalance} {props.currency}
                                </Typography>
                                <Typography variant="h5">Total Inflow Rate</Typography>
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
                            <div className="button-container">
                                <Button
                                    className="button flow-button"
                                    color="primary"
                                    disabled={fetching || !isFullyAllocated || !inputFlowRate || Number(inputFlowRate) <= 0}
                                    variant="contained"
                                    onClick={() => createOrUpdateFlow()}
                                >
                                    {Number(userFlowRate) > 0 ? "Update" : "Create"} Flow
                                </Button>
                                <Button
                                    className="button flow-button"
                                    color="primary"
                                    disabled={fetching || Number(totalUserFlowedBalance) <= 0}
                                    variant="contained"
                                    onClick={() => withdrawFunds()}
                                >
                                    Withdraw
                                </Button>
                                <Button
                                    className="button flow-button"
                                    color="secondary"
                                    disabled={fetching || Number(userFlowRate) === 0}
                                    variant="contained"
                                    onClick={() => deleteFlow()}
                                >
                                    Delete Flow
                                </Button>
                            </div>
                        </div>
                        {fetching && <div className="updating-flows-loading">
                            <Typography className="updating-flow-text" variant="body1">Plunging...</Typography>
                            <LinearProgress />
                        </div>}
                    </div>
                </div>
            )}
        </Container>
    );
};

export default Valve;
