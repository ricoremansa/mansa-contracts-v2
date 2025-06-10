const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();

  console.log("👷 Deploying VaultMathLib...");
  const VaultMathLib = await ethers.deployContract("VaultMathLib");
  await VaultMathLib.waitForDeployment();
  console.log("✅ VaultMathLib deployed at:", VaultMathLib.target);

  console.log("🚀 Deploying Mansa with external library link...");
  const MansaFactory = await ethers.getContractFactory("Mansa", {
    libraries: {
      VaultMathLib: VaultMathLib.target,
    },
  });

  const mansa = await MansaFactory.deploy();
  await mansa.waitForDeployment();
  console.log("✅ Mansa deployed at:", mansa.target);
}

main().catch((error) => {
  console.error("❌ Deployment failed:", error);
  process.exitCode = 1;
});
