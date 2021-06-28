import { IValveData } from "../utils/interfaces";
import ValveCard from "./ValveCard";

const Home = ({ valveData }: { valveData: IValveData[] }) => {
    return (
        <div>
            <div>
                {valveData.map(x => (
                    <ValveCard key={x.address} valveData={x} />
                ))}
            </div>
        </div>
    );
};

export default Home;
