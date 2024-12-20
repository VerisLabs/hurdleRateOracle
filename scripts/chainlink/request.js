import { ethers } from "ethers";
import dotenv from 'dotenv';
dotenv.config();

async function requestUpdate() {
  const oracleAddress = "0xE6D2AC67F3fCb23c6E0bAbCd2B1c490A1e49CbfA";
  
  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const oracleAbi = [
    "function requestRateUpdate() external"
  ];

  const oracle = new ethers.Contract(oracleAddress, oracleAbi, wallet);

  try {
    console.log("\nRequesting rate update...");
    const tx = await oracle.requestRateUpdate({
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
