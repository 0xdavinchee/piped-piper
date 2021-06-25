import { useMemo } from "react";
import { createMuiTheme, CssBaseline, useMediaQuery } from "@material-ui/core";
import { blue } from "@material-ui/core/colors";
function App() {
    const prefersDarkMode = useMediaQuery("(prefers-color-scheme: dark)");
    const theme = useMemo(
        () =>
            createMuiTheme({
                palette: {
                    type: prefersDarkMode ? "dark" : "light",
                    primary: {
                        main: blue[200],
                    },
                },
            }),
        [prefersDarkMode],
    );
    return <div></div>;
}

export default App;
