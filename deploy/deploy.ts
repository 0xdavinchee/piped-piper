import hre from "hardhat";

async function main() {
  // We get the contract to deploy
  let fakeVaultFactory = await hre.ethers.getContractFactory("FakeVault");
  let vaultPipeFactory = await hre.ethers.getContractFactory("VaultPipe");
  let superValveFactory = await hre.ethers.getContractFactory("SuperValve");

  const fUSDC = "0xbe49ac1eadac65dccf204d4df81d650b50122ab2";
  let fv1 = await fakeVaultFactory.deploy(fUSDC, "fUSDC Vault 1 Token", "vFUSDC1");
  await fv1.deployed();
  console.log("fake vault 1: ", fv1.address);
  
  let fv2 = await fakeVaultFactory.deploy(fUSDC, "fUSDC Vault 2 Token", "vFUSDC2");
  await fv2.deployed();
  console.log("fake vault 2: ", fv2.address);
  
  const fUSDCx = "0x0f1d7c55a2b133e000ea10eec03c774e0d6796e8";

  let vp1 = await vaultPipeFactory.deploy(fUSDCx, fv1.address);
  await vp1.deployed();
  console.log("vault pipe 1: ", vp1.address);
  
  let vp2 = await vaultPipeFactory.deploy(fUSDCx, fv1.address);
  await vp2.deployed();
  console.log("vault pipe 2: ", vp2.address);

  let sv = await superValveFactory.deploy(process.env.HOST_ADDRESS, process.env.CFA_ADDRESS, fUSDCx, [vp1.address, vp2.address]);
  await sv.deployed();
  console.log("super valve: ", sv.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
