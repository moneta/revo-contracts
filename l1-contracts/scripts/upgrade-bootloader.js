const hre = require("hardhat");
const fs = require('fs');
const { parse } = require('yaml');

const ContractDeployerAbi = [
  {
    "anonymous": false,
    "inputs": [
      {
        "indexed": false,
        "internalType": "enum IContractDeployer.AllowedBytecodeTypes",
        "name": "mode",
        "type": "uint8"
      }
    ],
    "name": "AllowedBytecodeTypesModeUpdated",
    "type": "event"
  },
  {
    "inputs": [],
    "name": "allowedBytecodeTypesToDeploy",
    "outputs": [
      {
        "internalType": "enum IContractDeployer.AllowedBytecodeTypes",
        "name": "",
        "type": "uint8"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {
        "internalType": "enum IContractDeployer.AllowedBytecodeTypes",
        "name": "newAllowedBytecodeTypes",
        "type": "uint8"
      }
    ],
    "name": "setAllowedBytecodeTypesToDeploy",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  }
]

const facetAction = {
  add: 0,
  replace: 1,
  remove: 2
};

const AllowedBytecodeTypes = {
    EraVm: 0,       // - `EraVm` means that only native contracts can be deployed
    EraVmAndEVM: 1  // - `EraVmAndEVM` means that native contracts and EVM contracts can be deployed
}

// Update these values
const ECOSYSTEM_PATH = '/home/revolution/dev_revo';
const CHAIN_NAME = 'revolution';
const chainId = 73861

const ecoContract = fs.readFileSync(`${ECOSYSTEM_PATH}/configs/contracts.yaml`, 'utf8');
const ecosystemCfg = parse(ecoContract, { intAsBigInt: true }); 

const chainContract = fs.readFileSync(`${ECOSYSTEM_PATH}/chains/${CHAIN_NAME}/configs/contracts.yaml`, 'utf8');
const chainCfg = parse(chainContract, { intAsBigInt: true }); 

const config = {
  bridgeHubProxyAddress: `0x${ecosystemCfg.ecosystem_contracts.bridgehub_proxy_addr.toString(16)}`,
  stmAddress: `0x${ecosystemCfg.ecosystem_contracts.state_transition_proxy_addr.toString(16)}`,
  governanceAddress: `0x${ecosystemCfg.l1.governance_addr.toString(16)}`,
  upgradeAddress: `0x${ecosystemCfg.l1.default_upgrade_addr.toString(16)}`,
  chainAdminAddress: `0x${chainCfg.l1.chain_admin_addr.toString(16)}`,
  diamondProxyAddress: `0x${chainCfg.l1.diamond_proxy_addr.toString(16)}`
};
const Bytes32Zero = "0x0000000000000000000000000000000000000000000000000000000000000000";
const AddressZero = "0x0000000000000000000000000000000000000000";
const PatchZero = 2**32;

const sleep = (milliseconds) =>  new Promise((resolve) => setTimeout(resolve, milliseconds));

const info = async () => {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());
}

const governanceExecuteInstant = async (calls, predecessor, salt) => {
  const governance = await hre.ethers.getContractAt("Governance", config.governanceAddress);
  const scheduleResult = await governance.scheduleTransparent([calls, predecessor, salt], 0);
  console.log("Schedule result is ", scheduleResult);
  await sleep(60000); // wait until it is scheduled
  const executeResult = await governance.executeInstant([calls, predecessor, salt], {value: 0});
  console.log("Final governanceExecuteInstant result: ", executeResult);
}

// return DiamondCut data for setProtocolVersionUpgrade and UpgradeChainFromVersion
const setNewVersionUpgradeFunctionData = async (isPatchUpgrade, bootloaderCodHash, timestamp, oldProtocolVersion, newProtocolVersion, minor, factoryDepHashes) => {
  console.log(`Preversion: ${oldProtocolVersion} Next Version: ${newProtocolVersion}`);
  console.log("Factory Deps", factoryDepHashes);
  const stm = await hre.ethers.getContractAt("ChainTypeManager", config.stmAddress);
  const upgrade = await hre.ethers.getContractFactory("DefaultUpgrade");
  const deployerIface = new hre.ethers.utils.Interface(ContractDeployerAbi);
  // const data = deployerIface.encodeFunctionData("forceDeployOnAddresses", [[]]);
  const data = deployerIface.encodeFunctionData("setAllowedBytecodeTypesToDeploy", [AllowedBytecodeTypes.EraVm]);
  console.log("Force Deployment Call Data:", data);

  // Refer to: EcosystemUpgrade.s.sol/generateUpgradeCutData
  const initCalldata = upgrade.interface.encodeFunctionData("upgrade", [[
    // Refer to: EcosystemUpgrade.s.sol/_composeUpgradeTx function
    [
      254,      // txType = SYSTEM_UPGRADE_L2_TX_TYPE
      32775,    // 0x8007: uint256(uint160(L2_FORCE_DEPLOYER_ADDR))
      32774,    // 0x8006: L2_DEPLOYER_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x06),
      72000000, // gasLimit
      800,      // gasPerPubdataByteLimit
      0,        // maxFeePerGas
      0,        // maxPriorityFeePerGas
      0,        // paymaster
      minor,    // nonce: same as minor >> Refer to: getProtocolUpgradeNonce
      0,        // value
      [0,0,0,0], // reserved
      data,     // data
      "0x",     // signature
      factoryDepHashes, // factoryDeps
      "0x",     // paymasterInput
      "0x"      // reservedDynamic
    ],
    bootloaderCodHash,
    Bytes32Zero, // defaultAccountHash
    Bytes32Zero, // evmEmulatorHash
    AddressZero, // verifier address
    [Bytes32Zero, Bytes32Zero, Bytes32Zero], // VerifierParams
    "0x",        // l1ContractsUpgradeCalldata
    "0x",        // postUpgradeCalldata
    timestamp,   // upgrade timestamp
    newProtocolVersion      // newProtocolVersion
  ]]);
  // console.log(initCalldata);
  // const admin = await stm.admin();
  // console.log("Admin address is ", admin);
  // const owner = await stm.owner();
  // console.log("owner address is ", owner);
  const functionData = stm.interface.encodeFunctionData(
    "setNewVersionUpgrade",
    [
      // DiamondCutData
      [
        [],                     // facetCuts
        config.upgradeAddress,  // initAddress
        initCalldata            // initCalldata
      ],
      oldProtocolVersion,       // _oldProtocolVersion
      2743459943,               // _oldProtocolVersionDeadline
      newProtocolVersion        // _newProtocolVersion
    ]
  );

  return {
    callData: functionData,
    initialCallData: initCalldata
  };
}

const stmExecuteUpgrade = async (upgradeAddress, action) => {
  const stm = await hre.ethers.getContractAt("ChainTypeManager", config.stmAddress);
  const result = stm.interface.encodeFunctionData(
    "executeUpgrade",
    [
      chainId,
      [
        [
          [
            upgradeAddress,
            action, // 0: add, 1: replace, 2: Remove
            true,
            ["0x16ef1303"] // upgrade function signature
          ]
        ],
        AddressZero,
        "0x"
      ],
    ]
  );
  return result;
}

const _setProtocolVersionDeadline = async (version, timestamp) => {
  const semVersion = version * PatchZero;
  const stm = await hre.ethers.getContractAt("ChainTypeManager", config.stmAddress);
  const result = stm.interface.encodeFunctionData(
    "setProtocolVersionDeadline",
    [
      semVersion,
      timestamp
    ]
  );
  return result;
}

const bridgeHubPauseMigration = async () => {
  const stm = await hre.ethers.getContractAt("Bridgehub", config.bridgeHubProxyAddress);
  const result = stm.interface.encodeFunctionData(
    "pauseMigration",
    [
    ]
  );
  return result;
}

const upgradeChainFromVersion = async (prevMinor, initialCallData) => {
  const diamond = await hre.ethers.getContractAt("AdminFacet", config.diamondProxyAddress);
  const encodedCallData = await diamond.interface.encodeFunctionData(
    "upgradeChainFromVersion",
    [
      prevMinor * PatchZero,
      [
        [],
        config.upgradeAddress,
        initialCallData
      ]
    ]
  );
  const chainAdmin = await hre.ethers.getContractAt("ChainAdminOwnable", config.chainAdminAddress)
  console.log(`Encoded CallData for upgrade chain from version ${encodedCallData}`);
  const txResult = await chainAdmin.multicall([[config.diamondProxyAddress, 0, encodedCallData]], true, {value: 0});
  console.log("UpgradeChainFromVersion Transaction Result: ", txResult);
  return txResult;
}

const setUpgradeTimestamp = async (minor, timestamp) => {
  const chainAdmin = await hre.ethers.getContractAt("ChainAdminOwnable", config.chainAdminAddress);
  const result = await chainAdmin.setUpgradeTimestamp(minor * PatchZero, timestamp);
  console.log("SetUpgradeTimestamp Transaction Result:", result);
  return result;
}

function convertHexBytesToUint256(hexBytes) {
  // Ensure the input is a valid hex string
  if (!ethers.utils.isHexString(hexBytes)) {
    throw new Error("Invalid hex string provided.");
  }

  // Pad the hex string to 32 bytes (64 hex characters) if necessary
  const paddedHexString = ethers.utils.hexZeroPad(hexBytes, 32);

  // Convert the padded hex string to a BigNumber
  const uint256 = ethers.BigNumber.from(paddedHexString);

  return uint256;
}

async function addUpgradeFacetToDiamond() {
  // const diamond = await hre.ethers.getContractAt("GettersFacet", config.diamondProxyAddress);
  // console.log(await diamond.facetAddress("0x16ef1303"))

  const callData = await stmExecuteUpgrade(config.upgradeAddress, facetAction.add);
  await governanceExecuteInstant([[config.stmAddress, 0, callData]], Bytes32Zero, Bytes32Zero);
  
}

async function setProtocolVersionDeadline(version, deadline) {
  const callData = await _setProtocolVersionDeadline(version, deadline);
  await governanceExecuteInstant([[config.stmAddress, 0, callData]], Bytes32Zero, Bytes32Zero);
}

async function pauseMigration() {
  const encodePauseMigration = await bridgeHubPauseMigration();
  console.log(encodePauseMigration)
  await governanceExecuteInstant([[config.bridgeHubProxyAddress, 0, encodePauseMigration]], Bytes32Zero, Bytes32Zero)
}

let STEP = 0;
async function main() {
  const bootloaderCodHash = "0x01000893a8e0a6583f01e452190c1cbec8d500fd9bbe444174f936ec8674a413";
  const timestamp = 1744841636;
  const prevMinor = 33;
  const minor = 34;
  const isPatchUpgrade = false;

  const gettersFacet = await hre.ethers.getContractAt("GettersFacet", config.diamondProxyAddress);
  // console.log("GettersFacet address:", diamond);
  const facets = await gettersFacet.facetAddresses();
  console.log("Facets in this diamond:", facets);

  // Protocol version: uint96, 32bit(major).32bit(minor or protocol version).32bit(patch)
  const oldProtocolVersion = await gettersFacet.getProtocolVersion();
  const newProtocolVersion = oldProtocolVersion.add(1);
  console.log("Current protocol version:", oldProtocolVersion.toHexString());
  console.log("New protocol version:", newProtocolVersion.toHexString());

  // const signer = await ethers.getSigner();
  // console.log('signer:', signer.address);
  // const encodedCallData = await gettersFacet.interface.encodeFunctionData(
  //   "getProtocolVersion",
  //   []
  // );
  // console.log("getProtocolVersion encoded CallData:", encodedCallData);
  // const proxy = await hre.ethers.getContractAt("DiamondProxy", config.diamondProxyAddress);
  // const tx = await signer.sendTransaction({
  //   to: config.diamondProxyAddress,
  //   data: encodedCallData
  // });
  // const txResult = await tx.wait();
  // console.log("txResult result is ", txResult);
  
  // Protocol version: uint96, 32bit(major).32bit(minor or protocol version).32bit(patch)
  // const oldProtocolVersion = prevMinor * PatchZero;
  // const newProtocolVersion = isPatchUpgrade ? oldProtocolVersion + 1 : minor * PatchZero; 

  console.log(config);

  await info();

  switch(STEP) {
    case 1:
      await pauseMigration();
      await addUpgradeFacetToDiamond();
      break;
    case 2:
      await setProtocolVersionDeadline(27, 2743521496);
      break;
    case 3:
      const callData = await setNewVersionUpgradeFunctionData(false, bootloaderCodHash, timestamp, oldProtocolVersion, newProtocolVersion, minor, [bootloaderCodHash]);
      // const callData = await setNewVersionUpgradeFunctionData(true, Bytes32Zero, timestamp, oldProtocolVersion, newProtocolVersion, minor, [bootloaderCodHash]);
      console.log(callData['initialCallData']);
      await governanceExecuteInstant([[config.stmAddress, 0, callData['callData']]], Bytes32Zero, Bytes32Zero);
      await sleep(120000);

      await upgradeChainFromVersion(prevMinor, callData['initialCallData']);
      await sleep(120000);

      await setUpgradeTimestamp(minor, timestamp);
      break;
    default:
        console.log('Replace a specific step 1 - 3:');
        return;
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});