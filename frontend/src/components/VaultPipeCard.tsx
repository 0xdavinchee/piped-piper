import { Card, CardContent, TextField, Typography } from "@material-ui/core";
import { IUserPipeData } from "../utils/interfaces";

interface IVaultPipeCardProps {
    data: IUserPipeData;
    index: number;
    handleUpdateAllocation: (x: string, i: number) => void;
}
const VaultPipeCard = (props: IVaultPipeCardProps) => {
    const data = props.data;
    return (
        <Card key={data.pipeAddress} className="pipe-vault">
            <CardContent>
                <div>
                    <Typography variant="h4">{data.name}</Typography>
                    <Typography variant="body1" color="textSecondary">
                        Yield: 0%
                    </Typography>
                    <Typography variant="body1" color="textSecondary">
                        Flow rate: {data.flowRate} / s
                    </Typography>
                </div>
                <TextField
                    className="text-field"
                    label="Allocation (%)"
                    onChange={e => props.handleUpdateAllocation(e.target.value, props.index)}
                    type="number"
                    value={data.percentage}
                />
            </CardContent>
        </Card>
    );
};

export default VaultPipeCard;
