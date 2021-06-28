import { useMemo } from "react";
import { createMuiTheme, CssBaseline, ThemeProvider, useMediaQuery } from "@material-ui/core";
import PipedPiper from "./PipedPiper";
function App() {
    const prefersDarkMode = useMediaQuery("(prefers-color-scheme: dark)");
    const theme = useMemo(
        () =>
            createMuiTheme({
                palette: {
                    type: prefersDarkMode ? "dark" : "light",
                    primary: { main: "#6d8cfc" },
                },
                typography: {
                    fontFamily: "VT323",
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
