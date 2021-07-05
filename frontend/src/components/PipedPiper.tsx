import { useEffect, useState } from "react";
import { Container, Typography } from "@material-ui/core";
import { BrowserRouter, Switch, Route, useHistory, useLocation } from "react-router-dom";
import Nav from "./Nav";
import Landing from "./LandingScreen";
import Home from "./HomeScreen";
import Valve from "./ValveScreen";
import Vault from "./VaultScreen";
import { PATH, STORAGE } from "../utils/constants";
import { IValveData } from "../utils/interfaces";
import { requestAccount } from "../utils/helpers";

const VALVE_DATA: IValveData[] = [
    {
        address: process.env.REACT_APP_fUSDC_SUPER_VALVE_ADDRESS || "",
        currency: "fUSDC",
        image_url: "https://s2.coinmarketcap.com/static/img/coins/64x64/3408.png",
    },
];

const checkHasVisited = () => {
    try {
        return localStorage.getItem(STORAGE.HasVisited) === "true";
    } catch {
        return false;
    }
};

const Router = ({ userAddress, setUserAddress }: { userAddress: string, setUserAddress: (x: string) => void }) => {
    const history = useHistory();
    const location = useLocation();

    useEffect(() => {
        if (location.pathname !== PATH.Landing) return;
        const hasEntered = checkHasVisited();

        if (hasEntered) {
            history.push(PATH.Home);
        } else {
            history.push(PATH.Landing);
        }
    }, [history, location.pathname]);

    const title = () => {
        return location.pathname.split("/")[1];
    };

    const currencyOrVault = () => {
        const splitPathname = location.pathname.split("/");
        const currencyData = VALVE_DATA.find(x => x.address === splitPathname[2]);
        const currencyName = currencyData ? currencyData.currency : "";
        return splitPathname.length < 3 ? "" : splitPathname[1] === "valve" ? currencyName : "vault name ";
    };

    return (
        <div className="router-container">
            <Typography className="title" variant="h1">
                {currencyOrVault() + " " + title()}
            </Typography>
            <Switch>
                <Route exact path={PATH.Landing}>
                    <Landing userAddress={userAddress} />
                </Route>
                <Route exact path={PATH.Home}>
                    <Home valveData={VALVE_DATA} />
                </Route>
                <Route exact path={PATH.Valve}>
                    <Valve currency={currencyOrVault()} userAddress={userAddress} setUserAddress={x => setUserAddress(x)} />
                </Route>
                <Route exact path={PATH.Vault}>
                    <Vault />
                </Route>
            </Switch>
        </div>
    );
};

const PipedPiper = () => {
    const [userAddress, setUserAddress] = useState("");
    useEffect(() => {
        (async () => {
            const result = await requestAccount();
            setUserAddress(result[0].toLowerCase());
        })();
    }, []);

    return (
        <Container className="container">
            <BrowserRouter>
                <Nav userAddress={userAddress} setUserAddress={x => setUserAddress(x)} />
                <Router userAddress={userAddress} setUserAddress={x => setUserAddress(x)} />
            </BrowserRouter>
        </Container>
    );
};

export default PipedPiper;
