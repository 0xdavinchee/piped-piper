import { AppBar, Toolbar, Typography } from "@material-ui/core";
import { Link } from "react-router-dom";
import pipe from "../images/pipe.png";
import { PATH } from "../utils/constants";

const Nav = () => {
    return (
        <AppBar position="static">
            <Toolbar>
                <div className="anchor logo-container">
                    <Link className="link" to={PATH.Home} />
                    <img className="pipe-logo" src={pipe} />
                    <Typography variant="h4" className="nav-title">
                        piped piper
                    </Typography>
                </div>
            </Toolbar>
        </AppBar>
    );
};

export default Nav;
