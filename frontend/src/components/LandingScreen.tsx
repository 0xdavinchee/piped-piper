import { Button, Typography } from "@material-ui/core";
import { useHistory } from "react-router-dom";
import { PATH, STORAGE } from "../utils/constants";

const Landing = ({ userAddress }: { userAddress: string }) => {
    const history = useHistory();
    const enterApp = () => {
        history.push(PATH.Home);
        try {
            localStorage.setItem(STORAGE.HasVisited, "true");
        } catch (err) {
            console.error(err);
        }
    };
    return (
        <div className="landing">
            <Typography variant="h1" className="title">
                welcome to piped piper
            </Typography>
            <div className="landing-button-container">
                <Button className="button" variant="contained" color="primary" disabled={!userAddress} onClick={() => enterApp()}>
                    enter app
                </Button>
            </div>
            <div className="landing-text">
                {!userAddress && <Typography variant="body2" color="textSecondary">Please connect your wallet to use the app.</Typography>}
            </div>
        </div>
    );
};

export default Landing;
