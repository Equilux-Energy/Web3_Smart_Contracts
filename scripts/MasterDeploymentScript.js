const hre = require("hardhat");
const fs = require("fs");
require("dotenv").config();

async function main() {
  const networkName = hre.network.name;
  const NETWORK_KEY = networkName.toUpperCase();

  console.log(`====================================`);
  console.log(`🚀 Deploying contracts to ${NETWORK_KEY} network 🚀`);
  console.log(`====================================`);

  // Step 1: Deploy or get EnergyToken
  const tokenAddress = await deployOrGetToken(NETWORK_KEY);

  // Step 2: Deploy EnergyMarketplace with token address
  const marketplaceAddress = await deployMarketplace(tokenAddress);

  // Step 3: Get EnergyEscrow address (created by EnergyMarketplace)
  const escrowAddress = await getEscrowAddress(marketplaceAddress);

  // Step 4: Setup roles (if not on mainnet)
  if (networkName !== "mainnet") {
    await setupRoles(marketplaceAddress);
  }

  // Display deployment summary
  displayDeploymentSummary(
    networkName,
    tokenAddress,
    marketplaceAddress,
    escrowAddress
  );
}

async function deployOrGetToken(networkKey) {
  console.log("📝 Checking for existing EnergyToken deployment...");

  // Check if token is already deployed
  const tokenAddressKey = `TOKEN_ADDRESS_${networkKey}`;
  const existingToken = process.env[tokenAddressKey];

  if (existingToken && existingToken.startsWith("0x")) {
    console.log(`ℹ️ Using existing EnergyToken at: ${existingToken}`);
    return existingToken;
  }

  console.log("📝 No existing token found. Deploying new EnergyToken...");

  // Deploy new token
  const initialSupply = getInitialTokenSupply(hre.network.name);
  const EnergyToken = await hre.ethers.getContractFactory("EnergyToken");

  // Deploy the contract
  console.log("⏳ Deploying EnergyToken...");
  const token = await EnergyToken.deploy("Equilux Token", "EQT", initialSupply);

  // Wait for deployment to complete and get address using ethers v6 method
  console.log("⏳ Waiting for deployment transaction confirmation...");
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();

  console.log(`✅ EnergyToken deployed to: ${tokenAddress}`);

  // Update .env file
  updateEnvFile(tokenAddressKey, tokenAddress);

  return tokenAddress;
}

async function deployMarketplace(tokenAddress) {
  console.log("📝 Deploying EnergyMarketplace contract...");

  // Deploy marketplace
  const EnergyMarketplace = await hre.ethers.getContractFactory(
    "EnergyMarketplace"
  );
  const marketplace = await EnergyMarketplace.deploy(tokenAddress);

  // Wait for deployment to complete and get address using ethers v6 method
  console.log("⏳ Waiting for deployment transaction confirmation...");
  await marketplace.waitForDeployment();
  const marketplaceAddress = await marketplace.getAddress();

  console.log(`✅ EnergyMarketplace deployed to: ${marketplaceAddress}`);

  // Update .env file
  const marketplaceAddressKey = `CONTRACT_ENERGY_TRADE_ADDRESS_${hre.network.name.toUpperCase()}`;
  updateEnvFile(marketplaceAddressKey, marketplaceAddress);

  return marketplaceAddress;
}

async function getEscrowAddress(marketplaceAddress) {
  console.log("📝 Fetching EnergyEscrow address from marketplace contract...");

  const marketplace = await hre.ethers.getContractAt(
    "EnergyMarketplace",
    marketplaceAddress
  );
  const escrowAddress = await marketplace.escrowContract();

  console.log(`✅ EnergyEscrow deployed at: ${escrowAddress}`);

  return escrowAddress;
}

async function setupRoles(marketplaceAddress) {
  console.log("📝 Setting up initial roles...");

  try {
    const [deployer] = await hre.ethers.getSigners();
    console.log(`ℹ️ Setting up roles using deployer: ${deployer.address}`);

    const marketplace = await hre.ethers.getContractAt(
      "EnergyMarketplace",
      marketplaceAddress
    );

    // Grant user role to deployer
    const USER_ROLE = await marketplace.USER_ROLE();
    if (!(await marketplace.hasRole(USER_ROLE, deployer.address))) {
      console.log("📝 Adding deployer as USER...");
      const tx = await marketplace.grantRole(USER_ROLE, deployer.address);
      await tx.wait();
      console.log("✅ Deployer added as USER");
    } else {
      console.log("ℹ️ Deployer already has USER role");
    }

    // Add test addresses if specified in .env
    if (process.env.TEST_USER_ADDRESS) {
      if (
        !(await marketplace.hasRole(USER_ROLE, process.env.TEST_USER_ADDRESS))
      ) {
        console.log(`📝 Adding test user ${process.env.TEST_USER_ADDRESS}...`);
        const tx = await marketplace.grantRole(
          USER_ROLE,
          process.env.TEST_USER_ADDRESS
        );
        await tx.wait();
        console.log("✅ Test user added");
      }
    }

    console.log("✅ Role setup completed");
  } catch (error) {
    console.error("❌ Error setting up roles:", error.message);
  }
}

function getInitialTokenSupply(networkName) {
  switch (networkName) {
    case "mainnet":
      return 1000000; // 1M tokens for mainnet
    case "holesky":
    case "sepolia":
      return 10000000; // 10M tokens for testnets
    default:
      return 100000000; // 100M tokens for local development
  }
}

function updateEnvFile(key, value) {
  try {
    const envPath = "./.env";
    let envContent = fs.readFileSync(envPath, "utf8");

    if (envContent.includes(key)) {
      const regex = new RegExp(`${key}=.*`);
      envContent = envContent.replace(regex, `${key}=${value}`);
    } else {
      envContent += `\n${key}=${value}`;
    }

    fs.writeFileSync(envPath, envContent);
    console.log(`📝 Updated .env file: ${key}=${value}`);
  } catch (error) {
    console.error("❌ Failed to update .env file:", error.message);
  }
}

function displayDeploymentSummary(
  network,
  tokenAddress,
  marketplaceAddress,
  escrowAddress
) {
  console.log("\n====================================");
  console.log("🎉 DEPLOYMENT COMPLETE!");
  console.log("====================================");
  console.log(`Network: ${network}`);
  console.log(`EnergyToken: ${tokenAddress}`);
  console.log(`EnergyMarketplace: ${marketplaceAddress}`);
  console.log(`EnergyEscrow: ${escrowAddress}`);
  console.log("\n📋 Verification Commands:");

  const initialSupply = getInitialTokenSupply(network);
  console.log(
    `npx hardhat verify --network ${network} ${tokenAddress} "Equilux Token" "EQT" ${initialSupply}`
  );
  console.log(
    `npx hardhat verify --network ${network} ${marketplaceAddress} ${tokenAddress}`
  );
  console.log(
    `npx hardhat verify --network ${network} ${escrowAddress} ${tokenAddress}`
  );
  console.log("====================================");
}

// Execute the deployment script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });
