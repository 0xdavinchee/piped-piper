import { useEffect } from "react";
import { Container, Typography } from "@material-ui/core";
import { BrowserRouter, Switch, Route, useHistory, useLocation } from "react-router-dom";
import Nav from "./Nav";
import Landing from "./LandingScreen";
import Home from "./HomeScreen";
import Valve from "./ValveScreen";
import Vault from "./VaultScreen";
import { PATH, STORAGE } from "../utils/constants";
import { IValveData } from "../utils/interfaces";

// TODO: Might need to implement a subgraph in order to get data on user's flowrate into the various

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

const Router = () => {
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
    }, []);

    const title = () => {
        return location.pathname.split("/")[1];
    };

    const currencyOrVault = () => {
        const splitPathname = location.pathname.split("/");
        const currencyData = VALVE_DATA.find(x => x.address === splitPathname[2]);
        const currencyName = currencyData ? currencyData.currency : "";
        return splitPathname.length < 3 ? "" : splitPathname[1] === "valve" ? currencyName + " " : "vault name ";
    };

    return (
        <div className="router-container">
            <Typography variant="h1">{currencyOrVault() + title()}</Typography>
            <Switch>
                <Route exact path={PATH.Landing}>
                    <Landing />
                </Route>
                <Route exact path={PATH.Home}>
                    <Home valveData={VALVE_DATA} />
                </Route>
                <Route exact path={PATH.Valve}>
                    <Valve />
                </Route>
                <Route exact path={PATH.Vault}>
                    <Vault />
                </Route>
            </Switch>
        </div>
    );
};

const PipedPiper = () => {
    return (
        <Container className="container">
            <BrowserRouter>
                <Nav />
                <Router />
            </BrowserRouter>
        </Container>
    );
};

export default PipedPiper;
