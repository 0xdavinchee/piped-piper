import { Button, Card, CardContent, CircularProgress, Container, TextField, Typography } from "@material-ui/core";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { Web3Provider } from "@ethersproject/providers";
import { useParams } from "react-router-dom";
import { useCallback, useEffect, useMemo, useState } from "react";
import { initializeContract } from "../utils/helpers";
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
const PIPES: IPipeData[] = [
    { address: "0xe28f4e47ab14d2debe741781761798f557f16c91", name: "fUSDC Vault 1" },
    { address: "0x79a42886aFd9ab2028e95262e7044263e6D29c6e", name: "fUSDC Vault 2" },
];
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
        ...PIPES.map(x => ({ address: x.address, name: x.name, allocation: "" })),
    ]);
    const [sf, setSf] = useState<any>(); // TODO: move this to PipedPiper.tsx so nav has access to this as well
    const [hasAllocations, setHasAllocations] = useState(false);
    const ethereum = (window as any).ethereum;

    const handleUpdateAllocation = (allocation: string, index: number) => {
        const dataToModify = userPipeData[index];
        setUserPipeData(Object.assign([], userPipeData, { [index]: { ...dataToModify, allocation } }));
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

    const setAllocationsAndCreateFlow = async () => {};

    const getFlowRateText = (flowRate: string) => {
        return flowRate + " " + props.currency + " / second";
    };

    const isFullyAllocated = useMemo(() => {
        return (
            userPipeData
                .map(x => Number(x.allocation))
                .reduce((x, y) => {
                    return x + y;
                }, 0) === 100
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
            const data = await contract.userAllocations(props.userAddress);
            const userPipeFlowId = data["userPipeFlowId"];
            setHasAllocations(userPipeFlowId.toNumber() > 0);

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
                                        key={x.address}
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
                                onClick={() => setAllocationsAndCreateFlow()}
                            >
                                Flow
                            </Button>
                        </div>
                    </div>
                </div>
            )}
        </Container>
    );
};

export default Valve;
