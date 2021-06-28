import { Card, CardContent, CircularProgress, TextField, Typography } from "@material-ui/core";
import { ethers } from "ethers";
import SuperfluidSDK from "@superfluid-finance/js-sdk";
import { Web3Provider } from "@ethersproject/providers";
import { useParams } from "react-router-dom";
import { useCallback, useEffect, useState } from "react";
import { initializeContract, requestAccount } from "../utils/helpers";

// TODO: there is no easy way to get array data directly via ethereum - subgraph may be needed for this
// you can only get one element at a time.

const Valve = () => {
    const { valveAddress }: { valveAddress: string } = useParams();
    const [loading, setLoading] = useState(true);
    const [time, setTime] = useState(new Date());
    const [flowRate, setFlowRate] = useState("");
    const [sf, setSf] = useState<any>(); // TODO: move this to PipedPiper.tsx so nav has access to this as well
    const [hasAllocations, setHasAllocations] = useState(false);
    const [userAddress, setUserAddress] = useState(""); // TODO: move this to PipedPiper.tsx so nav has access to this as well
    const ethereum = (window as any).ethereum;

    useEffect(() => {
        (async () => {
            const result = await requestAccount();
            setUserAddress(result[0].toLowerCase());
        })();
    }, []);
    useEffect(() => {
        (async () => {
            try {
                setLoading(false);
            } catch (err) {
                console.error(err);
            }
        })();
    }, []);

    useEffect(() => {
        const timer = setTimeout(() => {
            setTime(new Date());
        }, 1000);

        return () => clearTimeout(timer);
    });

    useEffect(() => {
        if (ethereum == null) return;
        ethereum.on("accountsChanged", (accounts: string[]) => {
            setUserAddress(accounts[0].toLowerCase());
        });

        return () => {
            ethereum.removeListener("accountsChanged", () => {});
        };
    }, []);

    useEffect(() => {
        if (!userAddress || !valveAddress) return;
        (async () => {
            const contract = initializeContract(true, valveAddress);
            if (contract == null || ethereum == null) return;
            const superfluidFramework = new SuperfluidSDK.Framework({
                ethers: new Web3Provider(ethereum),
            });
            const data = await contract.userAllocations(userAddress);
            const userPipeFlowId = data["userPipeFlowId"];
            setHasAllocations(userPipeFlowId.toNumber() > 0);

            await superfluidFramework.initialize();
            setSf(superfluidFramework);
        })();
    }, [valveAddress, userAddress]);

    return (
        <div>
            {loading && <CircularProgress className="loading" />}
            {!loading && (
                <>
                    <Card className="dashboard">
                        <CardContent>
                            <Typography variant="h5">Total Flow Balance</Typography>
                            <Typography variant="body2" color="textSecondary">
                                Total Flow Balance
                            </Typography>
                            <Typography variant="h5">Flow Rate</Typography>
                            <Typography variant="body2" color="textSecondary">
                                Total Flow Balance
                            </Typography>
                        </CardContent>
                    </Card>
                    <div className="vault-selector">
                        <Typography variant="h3">Vaults</Typography>
                        <Typography variant="body1">
                            Below is a selection of vaults which you can choose to redirect your cash flow into, you can
                            select one or more of these vaults and specify the monthly flow rate and the % of your flow
                            which you'd like to deposit into each of the vaults.
                        </Typography>
                        <div></div>
                        <TextField
                            className="text-field"
                            type="number"
                            label="Flow rate (monthly)"
                            onChange={e => setFlowRate(e.target.value)}
                            value={flowRate}
                        />
                    </div>
                </>
            )}
        </div>
    );
};

export default Valve;
