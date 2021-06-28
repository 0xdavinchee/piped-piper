export interface IValveData {
    address: string;
    currency: string;
    image_url: string;
}

export interface IPipeData {
    address: string;
    name: string;
}

export interface IUserPipeData extends IPipeData {
    allocation: string;
}
