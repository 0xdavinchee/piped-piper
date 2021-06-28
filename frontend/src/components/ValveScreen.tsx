import { Card, CardContent, CircularProgress, Typography } from "@material-ui/core";
import { useCallback, useEffect, useState } from "react";
import { initializeContract } from "../utils/helpers";

const Valve = () => {
    const [currencyAddress, setCurrencyAddress] = useState("");
    const [loading, setLoading] = useState(true);
    const [time, setTime] = useState(new Date());
    const [flowRate, setFlowRate] = useState(0);

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

    const getAndSetBaseData = useCallback(async () => {
        const contract = initializeContract(true, currencyAddress);
        if (contract == null) return;
    }, [currencyAddress]);

    return (
        <div>
            {loading && <CircularProgress className="loading" />}
            {!loading && (
                <>
                    <Typography>Valve</Typography>
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
                </>
            )}
        </div>
    );
};

export default Valve;
