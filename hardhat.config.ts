import { HardhatUserConfig, task } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
// Hopefully this is equivalent to 1. `import * as dotenv from "dotenv"` 2. `dotenv.config()`
import "dotenv/config";

import { boolean } from "hardhat/internal/core/params/argumentTypes";
import addresses, { mumbaiAddresses } from "./utils/addresses";
import { tokens } from "./utils/tokens";

task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  console.log("taskArgs:", taskArgs);
  console.log("hre:", hre);

  const accounts = await hre.ethers.getSigners();

  accounts.forEach((account) => {
    console.log(account.address);
  });
});

task("deployOffsetHelper", "Deploys and verifies OffsetHelper")
  // ** How does adding optional params work?
  .addOptionalParam(
    "verify",
    "Set false to not verify the OffsetHelper after deployment",
    true,
    boolean
  )
  .setAction(async (taskArgs, hre) => {
    // I'd rename it to OffsetHelperFactory
    const OffsetHelper = await hre.ethers.getContractFactory("OffsetHelper");

    const addressesToUse =
      hre.network.name == "mumbai" ? mumbaiAddresses : addresses;

    const oh = await OffsetHelper.deploy(tokens, [
      addressesToUse.bct,
      addressesToUse.nct,
      addressesToUse.usdc,
      addressesToUse.weth,
      addressesToUse.wmatic,
    ]);

    await oh.deployed();
    console.log(`OffsetHelper deployed on ${hre.network.name} to:`, oh.address);

    // ** What does `taskArgs.verify` mean?
    if (taskArgs.verify === true) {
      // Getting the deployment transaction after waiting for 5 blocks
      // ** But we aren't putting the deployment tx into a variable. Why wait for 5 blocks then?
      await oh.deployTransaction.wait(5);
      await hre.run("verify:verify", {
        address: oh.address,
        constructorArguments: [
          tokens,
          [
            addressesToUse.bct,
            addressesToUse.nct,
            addressesToUse.usdc,
            addressesToUse.weth,
            addressesToUse.wmatic,
          ],
        ],
      });
      console.log(
        `OffsetHelper verified on ${hre.network.name} to:`,
        oh.address
      );
    }
  });

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  solidity: {
    version: "0.8.4",
    settings: {
      optimizer: {
        enabled: true,
        // ** Is `200` a lot or not?
        runs: 200,
      },
    },
  },
  networks: {
    polygon: {
      url:
        process.env.POLYGON_URL || "https://matic-mainnet.chainstacklabs.com",
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    mumbai: {
      url: process.env.MUMBAI_URL || "https://matic-mainnet.chainstacklabs.com",
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    hardhat: {
      forking: {
        url: process.env.POLYGON_URL || "",
      },
    },
  },
  mocha: {
    timeout: 150000,
  },
  etherscan: {
    apiKey: process.env.POLYGONSCAN_API_KEY || "",
  },
  gasReporter: {
    enabled: true,
    outputFile: "gas-report.txt",
    noColors: true,
    currency: "USD",
    // This will make an API call to coinmarketcap whenever we run the gas reporter
    // coinmarketcap: COINMARKETCAP_API_KEY,
    token: "MATIC", // Shows how much deploying to Polygon would cost (default is ETH mainnet)
  },
};

export default config;
