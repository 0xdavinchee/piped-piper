export interface IValveData {
    address: string;
    currency: string;
    image_url: string;
}

export interface IPipeData {
    pipeAddress: string;
    name: string;
}

export interface IUserPipeData extends IPipeData {
    percentage: string;
}
