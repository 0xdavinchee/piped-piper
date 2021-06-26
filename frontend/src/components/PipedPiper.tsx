import { useCallback, useEffect, useState } from "react";
import { AppBar, Card, CardContent, CircularProgress, Container, Toolbar, Typography } from "@material-ui/core";
import pipe from "../images/pipe.png";
import { initializeContract } from "../utils/helpers";

// TODO: Might need to implement a subgraph in order to get data on user's flowrate into the various

interface ICurrency {
    address: string;
    symbol: string;
}

const INITIAL_CURRENCIES = [{ address: process.env.REACT_APP_fUSDC_SUPER_VALVE_ADDRESS || "", symbol: "fUSDC" }];

const PipedPiper = () => {
    const [loading, setLoading] = useState(true);
    const [currencies, setCurrencies] = useState<ICurrency[]>(INITIAL_CURRENCIES);
    const [currencyAddress, setCurrencyAddress] = useState("");
    const [time, setTime] = useState(new Date());
    const [flowRate, setFlowRate] = useState(0);

    const getAndSetBaseData = useCallback(async () => {
        const contract = initializeContract(true, currencyAddress);
        if (contract == null) return;
    }, [currencyAddress]);

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
    return (
        <Container className="container" maxWidth="md">
            {loading && <CircularProgress className="loading" />}
            {!loading && (
                <>
                    <AppBar position="static">
                        <Toolbar>
                            <img className="pipe-logo" src={pipe} />
                            <Typography variant="h4" className="nav-title">
                                Piped Piper
                            </Typography>
                        </Toolbar>
                    </AppBar>
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
        </Container>
    );
};

export default PipedPiper;
