import {
  SecretsManager,
  ReturnType,
  decodeResult,
} from "@chainlink/functions-toolkit";
import { ethers } from "ethers";
import dotenv from 'dotenv';

dotenv.config();

const makeRequest = async () => {
  const routerAddress = "0xC22a79eBA640940ABB6dF0f7982cc119578E11De";
  const consumerAddress = "0xBe3B17cf049e82A381f88090C018CdE02eC9d6B9"; 
  const donId = "fun-polygon-amoy-1";
  const gatewayUrls = [
    "https://01.functions-gateway.testnet.chain.link/",
    "https://02.functions-gateway.testnet.chain.link/"
  ];
  
  const slotId = 0;
  const expirationTimeMinutes = 15;
  const gasLimit = 300000;

  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY);
  const signer = wallet.connect(provider);

  console.log("\nUploading secrets to DON...");
  
  // Initialize SecretsManager
  const secretsManager = new SecretsManager({
    signer: signer,
    functionsRouterAddress: routerAddress,
    donId: donId
  });

  await secretsManager.initialize();

  // Prepare secrets
  const secrets = {
    signature: process.env.MAXAPY_SIGNATURE
  };

  // Encrypt and upload secrets
  console.log("Encrypting secrets...");
  const encryptedSecretsObj = await secretsManager.encryptSecrets(secrets);

  console.log("Uploading encrypted secrets...");
  const uploadResult = await secretsManager.uploadEncryptedSecretsToDON({
    encryptedSecretsHexstring: encryptedSecretsObj.encryptedSecrets,
    gatewayUrls,
    slotId: slotId,
    minutesUntilExpiration: expirationTimeMinutes,
  });

  if (!uploadResult.success) throw new Error("Failed to upload secrets");

  console.log("✅ Secrets uploaded successfully!");
  console.log("Slot ID:", slotId);
  console.log("Version:", uploadResult.version);

  const oracleAbi = [
    "function requestRateUpdate(uint8 donHostedSecretsSlotID, uint64 donHostedSecretsVersion) external"
  ];
  
  const oracle = new ethers.Contract(consumerAddress, oracleAbi, signer);
  
  const feeData = await provider.getFeeData();
  const baseFee = feeData.lastBaseFeePerGas || ethers.utils.parseUnits("50", "gwei");
  const maxPriorityFeePerGas = ethers.utils.parseUnits("25", "gwei");
  const maxFeePerGas = baseFee.add(maxPriorityFeePerGas);

  console.log("\nGas settings:");
  console.log("Base fee:", ethers.utils.formatUnits(baseFee, "gwei"), "gwei");
  console.log("Max priority fee:", ethers.utils.formatUnits(maxPriorityFeePerGas, "gwei"), "gwei");
  console.log("Max fee:", ethers.utils.formatUnits(maxFeePerGas, "gwei"), "gwei");

  console.log("\nSending request to oracle...");
  console.log("Parameters:", {
    slotId: slotId,
    version: uploadResult.version
  });

  try {
    const tx = await oracle.requestRateUpdate(
      slotId,
      uploadResult.version,
      {
        maxFeePerGas,
        maxPriorityFeePerGas,
        gasLimit
      }
    );

    console.log(`Request sent! Hash: ${tx.hash}`);
    
    const receipt = await tx.wait(1);
    console.log("Transaction confirmed! Gas used:", receipt.gasUsed.toString());
    
    return receipt;
  } catch (error) {
    console.error("Transaction failed:", error);
    throw error;
  }
};

makeRequest().catch(console.error);
