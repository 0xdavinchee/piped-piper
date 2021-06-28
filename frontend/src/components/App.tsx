import { useMemo } from "react";
import { createMuiTheme, CssBaseline, ThemeProvider, useMediaQuery } from "@material-ui/core";
import PipedPiper from "./PipedPiper";

function App() {
    const prefersDarkMode = useMediaQuery("(prefers-color-scheme: dark)");
    const theme = useMemo(
        () =>
            createMuiTheme({
                overrides: {
                    MuiInputLabel: {
                        root: {
                            fontSize: "1.4rem",
                            "&$focused": { fontSize: "1.4rem" },
                        },
                        shrink: { fontSize: "1.4rem" },
                    },
                    MuiInputBase: {
                        root: { fontSize: "1.4rem" },
                    },
                },
                palette: {
                    type: prefersDarkMode ? "dark" : "light",
                    primary: { main: "#6d8cfc" },
                },
                typography: {
                    fontFamily: "VT323",
                    body1: {
                        fontSize: "1.2rem",
                    },
                },
            }),
        [prefersDarkMode],
    );
    return (
        <ThemeProvider theme={theme}>
            <CssBaseline />
            <PipedPiper />
        </ThemeProvider>
    );
}

export default App;
