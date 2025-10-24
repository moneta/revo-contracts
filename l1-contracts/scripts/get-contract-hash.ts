const {Provider} = require("zksync-ethers");
(async () => {
  const p = new Provider(process.env.L2_RPC);
  const ACCOUNT_CODE_STORAGE = "0x0000000000000000000000000000000000008002"; // AccountCodeStorage
  const NODE_ADDR            = "0x00000000000000000000000000000000000080Fe"; // your NodeContract address
  const BASE_TOKEN_ADDR            = "0x000000000000000000000000000000000000800A"; // your NodeContract address
  const codeHash = await p.getStorageAt(ACCOUNT_CODE_STORAGE, NODE_ADDR);
  console.log("NodeContract codehash:", codeHash);
  console.log("L2BaseToken codehash:", await p.getStorageAt(ACCOUNT_CODE_STORAGE, BASE_TOKEN_ADDR));
})();