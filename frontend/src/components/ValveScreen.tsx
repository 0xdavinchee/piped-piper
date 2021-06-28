import { Card, CardContent, CircularProgress, Typography } from "@material-ui/core";
import { useParams } from "react-router-dom";
import { useCallback, useEffect, useState } from "react";
import { initializeContract } from "../utils/helpers";

const Valve = () => {
    const { address }: { address: string } = useParams();
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

    useEffect(() => {
        const contract = initializeContract(true, address);
        if (contract == null) return;
    }, [address]);

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
