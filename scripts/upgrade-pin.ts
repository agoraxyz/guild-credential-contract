import { ethers, upgrades } from "hardhat";

// CONFIG
const name = ""; // The name of the token.
const symbol = ""; // The short, usually all caps symbol of the token.

const pinAddress = "0x..."; // The address where the contract was deployed (proxy).

async function main() {
  const GuildPin = await ethers.getContractFactory("GuildPin");
  const guildPin = await upgrades.upgradeProxy(pinAddress, GuildPin, {
    kind: "uups",
    call: { fn: "reInitialize", args: [name, symbol] }
  });

  console.log(
    `Deploying contract to ${
      ethers.provider.network.name !== "unknown" ? ethers.provider.network.name : ethers.provider.network.chainId
    }...`
  );
  console.log(`Tx hash: ${guildPin.deployTransaction.hash}`);

  await guildPin.deployed();

  console.log("GuildPin deployed to:", guildPin.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
