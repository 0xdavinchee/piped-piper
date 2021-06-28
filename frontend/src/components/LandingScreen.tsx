import { Button, Typography } from "@material-ui/core";
import { useHistory } from "react-router-dom";
import { PATH, STORAGE } from "../utils/constants";

const Landing = () => {
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
        <div>
            <Typography variant="h1" className="landing-title">
                welcome to piped piper
            </Typography>
            <div className="landing-button-container">
                <Button className="button" variant="contained" color="primary" onClick={() => enterApp()}>
                    enter app
                </Button>
            </div>
        </div>
    );
};

export default Landing;
