require("@nomicfoundation/hardhat-toolbox")
require("dotenv").config()

const LOCAL_RPC_URL = process.env.LOCAL_RPC_URL
const LOCAL_CHAIN_ID = process.env.LOCAL_CHAIN_ID
const LOCAL_PRIVATE_KEY = process.env.LOCAL_PRIVATE_KEY
const PRIVATE_KEY = process.env.PRIVATE_KEY
const MAINNET_RPC_URL = process.env.MAINNET_RPC_URL
const HOLESKY_RPC_URL = process.env.HOLESKY_RPC_URL
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL

module.exports = {
    solidity: "0.8.20",
    networks: {
        ganacheUI: {
            url: LOCAL_RPC_URL, // Ensure Hardhat Network is running
            accounts: [LOCAL_PRIVATE_KEY],
            chainId: LOCAL_CHAIN_ID,
        },
        sepolia: {
            url: SEPOLIA_RPC_URL,
            accounts: [PRIVATE_KEY],
            chainId: 11155111,
        },
        holesky: {
            url: HOLESKY_RPC_URL,
            accounts: [PRIVATE_KEY],
            chainId: 17000,
        },
        mainnet: {
            url: MAINNET_RPC_URL,
            accounts: [PRIVATE_KEY],
            chainId: 1,
        },
    },
}
module.exports = {
    solidity: {
        version: "0.8.20",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
            viaIR: true,
        },
    },
    networks: {
        ganacheUI: {
            url: LOCAL_RPC_URL, // Ensure Hardhat Network is running
            accounts: [LOCAL_PRIVATE_KEY],
            chainId: 1337,
        },
    },
}
