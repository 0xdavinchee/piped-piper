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
        <>
            <Typography variant="h1" className="home-title home-welcome-text">
                Welcome to Piped Piper
            </Typography>
            <div></div>
            <Button variant="contained" color="primary" onClick={() => enterApp()}>
                Enter App
            </Button>
        </>
    );
};

export default Landing;
