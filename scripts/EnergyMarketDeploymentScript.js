const hre = require("hardhat");
const fs = require("fs");
require("dotenv").config();

async function main() {
  // Get network name from hardhat
  const networkName = hre.network.name.toUpperCase();
  console.log(`Deploying EnergyEscrow to ${networkName} network...`);

  // Load the token address from .env based on network
  const tokenAddressKey = `TOKEN_ADDRESS_${networkName}`;
  const tokenAddress = process.env[tokenAddressKey];

  if (!tokenAddress) {
    console.error(
      `Error: No token address found for ${networkName} in .env file.`
    );
    console.error(`Please ensure ${tokenAddressKey} is set in your .env file.`);
    process.exit(1);
  }

  console.log(`Using EnergyToken at address: ${tokenAddress}`);

  try {
    // Get contract factory
    const EnergyEscrow = await hre.ethers.getContractFactory("EnergyEscrow");

    // Deploy the contract
    console.log("Deploying EnergyEscrow...");
    const escrow = await EnergyEscrow.deploy(tokenAddress);

    // Wait for deployment to complete - updated for ethers v6
    console.log("Waiting for transaction confirmation...");
    await escrow.waitForDeployment();
    const escrowAddress = await escrow.getAddress();

    console.log(`EnergyEscrow deployed to: ${escrowAddress}`);

    // Update .env file with the new contract address
    updateEnvFile(networkName, escrowAddress);

    console.log("Deployment completed successfully!");

    // Log verification command
    console.log("\nTo verify this contract on Etherscan, run:");
    console.log(
      `npx hardhat verify --network ${hre.network.name.toLowerCase()} ${escrowAddress} ${tokenAddress}`
    );
  } catch (error) {
    console.error("Deployment failed:", error);
    process.exit(1);
  }
}

function updateEnvFile(networkName, escrowAddress) {
  try {
    const envPath = "./.env";
    let envContent = fs.readFileSync(envPath, "utf8");

    const escrowVarName = `CONTRACT_ENERGY_TRADE_ADDRESS_${networkName}`;

    // Update escrow address in .env file
    if (envContent.includes(escrowVarName)) {
      const regex = new RegExp(`${escrowVarName}=.*`);
      envContent = envContent.replace(
        regex,
        `${escrowVarName}=${escrowAddress}`
      );
    } else {
      envContent += `\n${escrowVarName}=${escrowAddress}`;
    }

    fs.writeFileSync(envPath, envContent);
    console.log(
      `Updated .env file with EnergyEscrow address for ${networkName}`
    );
  } catch (error) {
    console.error("Failed to update .env file:", error);
  }
}

// Execute the deployment script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
