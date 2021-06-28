import { AppBar, Button, Toolbar, Typography } from "@material-ui/core";
import { Link } from "react-router-dom";
import pipe from "../images/pipe.png";
import { PATH } from "../utils/constants";
import { requestAccount } from "../utils/helpers";

const Nav = () => {
    return (
        <AppBar position="static">
            <Toolbar className="nav-container">
                <div className="anchor logo-container">
                    <Link className="link" to={PATH.Home} />
                    <img className="pipe-logo" src={pipe} />
                    <Typography variant="h4" className="nav-title">
                        piped piper
                    </Typography>
                </div>
                <Button className="button nav-button" variant="contained" onClick={() => requestAccount()}>
                    Connect Wallet
                </Button>
            </Toolbar>
        </AppBar>
    );
};

export default Nav;
