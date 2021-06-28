import { useEffect } from "react";
import { Container } from "@material-ui/core";
import { BrowserRouter, Switch, Route, useHistory } from "react-router-dom";
import Nav from "./Nav";
import Landing from "./LandingScreen";
import Home from "./HomeScreen";
import Valve from "./ValveScreen";
import Vault from "./VaultScreen";
import { PATH, STORAGE } from "../utils/constants";

// TODO: Might need to implement a subgraph in order to get data on user's flowrate into the various

interface ICurrency {
    address: string;
    symbol: string;
}

const checkHasVisited = () => {
    try {
        return localStorage.getItem(STORAGE.HasVisited) === "true";
    } catch {
        return false;
    }
};

const Router = () => {
    const history = useHistory();
    useEffect(() => {
        const hasEntered = checkHasVisited();
        if (hasEntered) {
            history.push(PATH.Home);
        } else {
            history.push(PATH.Landing);
        }
    }, []);

    return (
        <Switch>
            <Route exact path={PATH.Landing}>
                <Landing />
            </Route>
            <Route exact path={PATH.Home}>
                <Home />
            </Route>
            <Route exact path={PATH.Valve}>
                <Valve />
            </Route>
            <Route exact path={PATH.Vault}>
                <Vault />
            </Route>
        </Switch>
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
