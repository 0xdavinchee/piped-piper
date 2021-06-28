import { Card, CardContent, TextField, Typography } from "@material-ui/core";
import { IUserPipeData } from "../utils/interfaces";

interface IVaultPipeCardProps {
    data: IUserPipeData;
    index: number;
    handleUpdateAllocation: (x: string, i: number) => void;
}
const VaultPipeCard = (props: IVaultPipeCardProps) => {
    return (
        <Card key={props.data.address} className="pipe-vault">
            <CardContent>
                <div>
                    <Typography variant="h4">{props.data.name}</Typography>
                    <Typography variant="body1" color="textSecondary">
                        Yield: 0%
                    </Typography>
                </div>
                <TextField
                    className="text-field"
                    label="Allocation"
                    onChange={e => props.handleUpdateAllocation(e.target.value, props.index)}
                    type="number"
                    value={props.data.allocation}
                />
            </CardContent>
        </Card>
    );
};

export default VaultPipeCard;
