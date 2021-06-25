import { ethers } from "ethers";
import SuperValveArtifact from "../artifacts/contracts/SuperValve.sol/SuperValve.json";

export const isGlobalEthereumObjectEmpty = typeof (window as any).ethereum == null;

const contractAddressToABIMap = new Map([[process.env.REACT_APP_USDC_SUPER_VALVE_ADDRESS, SuperValveArtifact.abi]]);

export async function requestAccount() {
    const ethereum = (window as any).ethereum;
    if (isGlobalEthereumObjectEmpty) return;

    return await ethereum.request({ method: "eth_requestAccounts" });
}

export function initializeContract(requiresSigner: boolean, contractAddress: string) {
    const ethereum = (window as any).ethereum;
    const artifact = contractAddressToABIMap.get(contractAddress);
    if (isGlobalEthereumObjectEmpty || !artifact) return;
    const provider = new ethers.providers.Web3Provider(ethereum);
    if (requiresSigner) {
        const signer = provider.getSigner();
        const contract = new ethers.Contract(contractAddress, artifact, signer);
        return contract;
    }
    const contract = new ethers.Contract(contractAddress, artifact, provider);
    return contract;
}
