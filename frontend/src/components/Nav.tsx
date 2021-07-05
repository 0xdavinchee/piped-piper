import { AppBar, Button, Toolbar, Typography } from "@material-ui/core";
import { Link } from "react-router-dom";
import { Blockie, EthAddress } from "rimble-ui";
import pipe from "../images/pipe.png";
import { PATH } from "../utils/constants";
import { requestAccount } from "../utils/helpers";

const Nav = ({ userAddress, setUserAddress }: { userAddress: string, setUserAddress: (x: string) => void }) => {
    const handleRequestAccount = async () => {
        try {
            const result = await requestAccount();
        setUserAddress(result[0].toLowerCase());
        } catch (err) {
            console.error(err);
        }
    };

    return (
        <AppBar position="static">
            <Toolbar className="nav-container">
                <div className="anchor logo-container">
                    <Link className="link" to={PATH.Home} />
                    <img className="pipe-logo" src={pipe} alt="pipe-logo" />
                    <Typography variant="h4" className="nav-title">
                        piped piper
                    </Typography>
                </div>
                {userAddress === "" && (
                    <Button className="button nav-button" variant="contained" onClick={() => handleRequestAccount()}>
                        Connect Wallet
                    </Button>
                )}
                {userAddress !== "" && (
                    <div className="nav-eth-data">
                        <Blockie address={userAddress} />
                        <EthAddress className="eth-address" address={userAddress} />
                    </div>
                )}
            </Toolbar>
        </AppBar>
    );
};

export default Nav;
