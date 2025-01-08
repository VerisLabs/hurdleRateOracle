import { ethers } from "ethers";
import dotenv from 'dotenv';
dotenv.config();

async function requestUpdate() { 
  const oracleAddress = "0x5EDd8bD98d96404a2387C2fD37b48d363DF67803";
  
  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const oracleAbi = [
    "function updateRates() external"
  ];

  const oracle = new ethers.Contract(oracleAddress, oracleAbi, wallet);

  try {
    console.log("\nRequesting rate update...");
    const tx = await oracle.updateRates({
      gasLimit: 500000
    });
    
    console.log("Transaction sent! Hash:", tx.hash);
    console.log("\nWaiting for confirmation...");
    
    const receipt = await tx.wait();
    console.log("Transaction confirmed!");
    console.log("Gas used:", receipt.gasUsed.toString());
    
  } catch (error) {
    console.error("Error:", error);
  }
}

requestUpdate().catch(console.error);
