import { Typography } from "@material-ui/core";
import { useState } from "react";
import { STORAGE } from "../utils/constants";
import { IValveData } from "../utils/interfaces";
import ValveCard from "./ValveCard";

const VALVE_DATA: IValveData[] = [
    {
        address: "0x4E9c9Cc48Bbfe2A28d1823c502F48A101D1D4090",
        currency: "fUSDC",
        image_url: "https://s2.coinmarketcap.com/static/img/coins/64x64/3408.png",
    },
];

const Home = () => {
    return (
        <div className="home">
            <>
                <Typography variant="h1" className="home-title">
                    Valves
                </Typography>
                <div>
                    {VALVE_DATA.map(x => (
                        <ValveCard valveData={x} />
                    ))}
                </div>
            </>
        </div>
    );
};

export default Home;
