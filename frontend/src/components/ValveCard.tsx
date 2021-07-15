import { Card, CardContent, Typography } from "@material-ui/core";
import { Link } from "react-router-dom";
import { PATH } from "../utils/constants";
import { IValveData } from "../utils/interfaces";

const ValveCard = ({ valveData }: { valveData: IValveData }) => {
    return (
        <Card className="valve-card anchor">
            <Link className="link" to={PATH.Valve.replace(":address", valveData.address)} />
            <CardContent className="valve-card-content">
                <img src={valveData.image_url} className="valve-card-currency-img" alt="currency-logo" />
                <div className="valve-card-text-container">
                    <Typography variant="h5">{valveData.currency}</Typography>
                </div>
            </CardContent>
        </Card>
    );
};

export default ValveCard;
