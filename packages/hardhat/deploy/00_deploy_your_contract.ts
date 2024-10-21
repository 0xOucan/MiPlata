import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { Contract } from "ethers";

/**
 * Deploys a contract named "YourContract" using the deployer account and
 * constructor arguments set to the deployer address
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployYourContract: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  /*
    On localhost, the deployer account is the one that comes with Hardhat, which is already funded.

    When deploying to live networks (e.g `yarn deploy --network sepolia`), the deployer account
    should have sufficient balance to pay for the gas fees for contract creation.

    You can generate a random account with `yarn generate` which will fill DEPLOYER_PRIVATE_KEY
    with a random private key in the .env file (then used on hardhat.config.ts)
    You can run the `yarn account` command to check your balance in every network.
  */
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // Despliegue de YourContract
  await deploy("YourContract", {
    from: deployer,
    args: [deployer],
    log: true,
    autoMine: true,
  });

  const yourContract = await hre.ethers.getContract<Contract>("YourContract", deployer);
  console.log("👋 Initial greeting:", await yourContract.greeting());

  // Despliegue de MiPlata
  await deploy("MiPlata", {
    from: deployer,
    args: [
      "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // usdc
      "0x4200000000000000000000000000000000000006", // weth
      "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4", // uniswapRouter
      "0xbE781D7Bdf469f3d94a62Cdcc407aCe106AEcA74", // aavePool
      "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1", // ethUsdPriceFeed
      "0xB39b858e70d1df1d3ec8CEC542189c3b96F13E45", // uniswapPool
      "0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2", // positionManager
      "0x7B3B786C36720F0d367F62dDb4e4B98e6f54DffD"  // feeCollector
    ],
    log: true,
    autoMine: true,
  });

  const miPlata = await hre.ethers.getContract<Contract>("MiPlata", deployer);
  console.log("🪙 MiPlata deployed at:", miPlata.address);
};

export default deployYourContract;

// Tags are useful if you have multiple deploy files and only want to run one of them.
// e.g. yarn deploy --tags YourContract
deployYourContract.tags = ["YourContract", "MiPlata"];

const deployContracts: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // Despliegue de MiPlata
  await deploy("MiPlata", {
    from: deployer,
    args: [
      "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // usdc
      "0x4200000000000000000000000000000000000006", // weth
      "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4", // uniswapRouter
      "0xbE781D7Bdf469f3d94a62Cdcc407aCe106AEcA74", // aavePool
      "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1", // ethUsdPriceFeed
      "0xB39b858e70d1df1d3ec8CEC542189c3b96F13E45", // uniswapPool
      "0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2", // positionManager
      "0x7B3B786C36720F0d367F62dDb4e4B98e6f54DffD"  // feeCollector
    ],
    log: true,
    autoMine: true,
  });

  const miPlata = await hre.ethers.getContract<Contract>("MiPlata", deployer);
  console.log("🪙 MiPlata deployed at:", miPlata.address);
};

export default deployContracts;

deployContracts.tags = ["MiPlata"];
