const hre = require("hardhat");
const fs = require("fs");
require("dotenv").config();

async function main() {
  // Get the deployment configuration based on the network
  const networkConfig = getNetworkConfig(hre.network.name);
  console.log(`Deploying to ${hre.network.name} network...`);

  // Deploy EnergyToken
  const EnergyToken = await hre.ethers.getContractFactory("EnergyToken");
  const energyToken = await EnergyToken.deploy(
    "Equilux Token",
    "EQT",
    networkConfig.initialTokenAmount
  );
  await energyToken.deployed();
  console.log(`EnergyToken deployed to: ${energyToken.address}`);

  // Deploy EnergyTrade with the token address
  const EnergyTrade = await hre.ethers.getContractFactory("EnergyTrade");
  const energyTrade = await EnergyTrade.deploy(energyToken.address);
  await energyTrade.deployed();
  console.log(`EnergyTrade deployed to: ${energyTrade.address}`);

  // Update .env file with the deployed contract addresses
  updateEnvFile(hre.network.name, energyToken.address, energyTrade.address);
}

function getNetworkConfig(networkName) {
  // Default values
  const config = {
    initialTokenAmount: 1000000, // 1 million tokens by default
  };

  // Network-specific adjustments
  switch (networkName) {
    case "mainnet":
      // Conservative amount for mainnet
      config.initialTokenAmount = 100000;
      break;
    case "holesky":
    case "sepolia":
      // More tokens for testnets for testing
      config.initialTokenAmount = 10000000;
      break;
    case "ganacheUI":
      // Even more for local development
      config.initialTokenAmount = 50000000;
      break;
  }

  return config;
}

function updateEnvFile(networkName, tokenAddress, energyTradeAddress) {
  try {
    const envPath = "./.env";
    let envContent = fs.readFileSync(envPath, "utf8");

    const tokenVarName = `TOKEN_ADDRESS_${networkName.toUpperCase()}`;
    const tradeVarName = `CONTRACT_ENERGY_TRADE_ADDRESS_${networkName.toUpperCase()}`;

    // Update token address
    if (envContent.includes(tokenVarName)) {
      envContent = envContent.replace(
        new RegExp(`${tokenVarName}=.*`),
        `${tokenVarName}=${tokenAddress}`
      );
    } else {
      envContent += `\n${tokenVarName}=${tokenAddress}`;
    }

    // Update trade address
    if (envContent.includes(tradeVarName)) {
      envContent = envContent.replace(
        new RegExp(`${tradeVarName}=.*`),
        `${tradeVarName}=${energyTradeAddress}`
      );
    } else {
      envContent += `\n${tradeVarName}=${energyTradeAddress}`;
    }

    fs.writeFileSync(envPath, envContent);
    console.log(
      `Updated .env file with deployed contract addresses for ${networkName}`
    );
  } catch (error) {
    console.error("Failed to update .env file:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
