const hre = require("hardhat");
const fs = require("fs");
const BN = require("bn.js");
const { parse } = require("yaml");
const { utils } = require("ethers");

const facetAction = {
  add: 0,
  replace: 1,
  remove: 2,
};

// Update these values
const ECOSYSTEM_PATH = "/home/revolution/tst_revo";
const CHAIN_NAME = "libertas";
const chainId = 73863;

const ecoContract = fs.readFileSync(`${ECOSYSTEM_PATH}/configs/contracts.yaml`, "utf8");
const ecosystemCfg = parse(ecoContract, { intAsBigInt: true });

const chainContract = fs.readFileSync(`${ECOSYSTEM_PATH}/chains/${CHAIN_NAME}/configs/contracts.yaml`, "utf8");
const chainCfg = parse(chainContract, { intAsBigInt: true });

const config = {
  bridgeHubProxyAddress: `0x${ecosystemCfg.ecosystem_contracts.bridgehub_proxy_addr.toString(16)}`,
  stmAddress: `0x${ecosystemCfg.ecosystem_contracts.state_transition_proxy_addr.toString(16)}`,
  governanceAddress: `0x${ecosystemCfg.l1.governance_addr.toString(16)}`,
  upgradeAddress: `0x${ecosystemCfg.l1.default_upgrade_addr.toString(16)}`,
  chainAdminAddress: `0x${chainCfg.l1.chain_admin_addr.toString(16)}`,
  diamondProxyAddress: `0x${chainCfg.l1.diamond_proxy_addr.toString(16)}`,
};
const Bytes32Zero = "0x0000000000000000000000000000000000000000000000000000000000000000";
const AddressZero = "0x0000000000000000000000000000000000000000";
const PatchZero = 2n**32n;

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const info = async () => {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());
};

const governanceExecuteInstant = async (calls, predecessor, salt) => {
  const governance = await hre.ethers.getContractAt("Governance", config.governanceAddress);
  console.log("governance scheduling transparent");
  const scheduleResult = await governance.scheduleTransparent([calls, predecessor, salt], 0);
  console.log("Schedule result is ", scheduleResult);
  await sleep(60000); // wait until it is scheduled
  const executeResult = await governance.executeInstant([calls, predecessor, salt], { value: 0 });
  console.log("Final governanceExecuteInstant result: ", executeResult);
};

// return DiamondCut data for setProtocolVersionUpgrade and UpgradeChainFromVersion
const setNewVersionUpgradeFunctionData = async (
  isPatchUpgrade,
  timestamp,
  deadline,
  oldProtocolVersion,
  newProtocolVersion,
  forceDeploymentData,
  factoryDepHashes
) => {
  console.log(`Preversion: ${oldProtocolVersion} Next Version: ${newProtocolVersion}`);
  console.log("Factory Deps", factoryDepHashes);
  const stm = await hre.ethers.getContractAt("ChainTypeManager", config.stmAddress);
  const upgrade = await hre.ethers.getContractFactory("DefaultUpgrade");

  const minor = BigInt(newProtocolVersion) >> 32n;
  console.log("minor:", minor);
  
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
      minor, // nonce.toString(),    // nonce: same as minor >> Refer to: getProtocolUpgradeNonce
      0,        // value
      [0,0,0,0], // reserved
      forceDeploymentData, // data
      "0x",     // signature
      factoryDepHashes, // factoryDeps
      "0x",     // paymasterInput
      "0x"      // reservedDynamic
    ],
    Bytes32Zero, // bootloaderHash >> Zero means we don't want to upgrade
    Bytes32Zero, // defaultAccountHash
    Bytes32Zero, // evmEmulatorHash
    AddressZero, // verifier address
    [Bytes32Zero, Bytes32Zero, Bytes32Zero], // VerifierParams
    "0x",        // l1ContractsUpgradeCalldata
    "0x",        // postUpgradeCalldata
    timestamp,   // upgrade timestamp
    newProtocolVersion      // newProtocolVersion
  ]]); 

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
      deadline,                 // _oldProtocolVersionDeadline
      newProtocolVersion        // _newProtocolVersion
    ]
  );

  return {
    callData: functionData,
    initialCallData: initCalldata,
  };
};

const upgradeChainFromVersion = async (protocolVersion, initialCallData) => {
  const diamond = await hre.ethers.getContractAt("AdminFacet", config.diamondProxyAddress);
  const encodedCallData = await diamond.interface.encodeFunctionData("upgradeChainFromVersion", [
    protocolVersion,
    [[], config.upgradeAddress, initialCallData],
  ]);
  const chainAdmin = await hre.ethers.getContractAt("ChainAdminOwnable", config.chainAdminAddress);
  console.log(`Encoded CallData for upgrade chain from version ${encodedCallData}`);
  const txResult = await chainAdmin.multicall([[config.diamondProxyAddress, 0, encodedCallData]], true, { value: 0 });
  console.log("UpgradeChainFromVersion Transaction Result: ", txResult);
  return txResult;
};

const setUpgradeTimestamp = async (protocolVersion, timestamp) => {
  const chainAdmin = await hre.ethers.getContractAt("ChainAdminOwnable", config.chainAdminAddress);
  const result = await chainAdmin.setUpgradeTimestamp(protocolVersion, timestamp);
  console.log("SetUpgradeTimestamp Transaction Result:", result);
  return result;
};

const stmExecuteUpgrade = async (upgradeAddress, action) => {
  const stm = await hre.ethers.getContractAt("ChainTypeManager", config.stmAddress);
  const result = stm.interface.encodeFunctionData("executeUpgrade", [
    chainId,
    [
      [
        [
          upgradeAddress,
          action, // 0: add, 1: replace, 2: Remove
          true,
          ["0x16ef1303"], // upgrade function signature
        ],
      ],
      AddressZero,
      "0x",
    ],
  ]);
  return result;
};

async function addUpgradeFacetToDiamond() {
  // const diamond = await hre.ethers.getContractAt("GettersFacet", config.diamondProxyAddress);
  // console.log(await diamond.facetAddress("0x16ef1303"))
  console.log("Adding upgrade facet to Diamond..")
  const callData = await stmExecuteUpgrade(config.upgradeAddress, facetAction.add);

  console.log('callData: ', callData);
  await governanceExecuteInstant([[config.stmAddress, 0, callData]], Bytes32Zero, Bytes32Zero);
}

async function setProtocolVersionDeadline(version, deadline) {
  const callData = await _setProtocolVersionDeadline(version, deadline);
  await governanceExecuteInstant([[config.stmAddress, 0, callData]], Bytes32Zero, Bytes32Zero);
}

const bridgeHubPauseMigration = async () => {
  const stm = await hre.ethers.getContractAt("Bridgehub", config.bridgeHubProxyAddress);
  const result = stm.interface.encodeFunctionData("pauseMigration", []);
  return result;
};

async function pauseMigration(salt) {
  const stm = await hre.ethers.getContractAt("Bridgehub", config.bridgeHubProxyAddress);
  const encodePauseMigration = stm.interface.encodeFunctionData("pauseMigration", []);
  await governanceExecuteInstant([[config.bridgeHubProxyAddress, 0, encodePauseMigration]], Bytes32Zero, salt);
  console.log("Done - pauseMigration");
}

async function unpauseMigration(salt) {
  const stm = await hre.ethers.getContractAt("Bridgehub", config.bridgeHubProxyAddress);
  const encodeUnpauseMigration = stm.interface.encodeFunctionData("unpauseMigration", []);
  await governanceExecuteInstant([[config.bridgeHubProxyAddress, 0, encodeUnpauseMigration]], Bytes32Zero, salt);
  console.log("Done - unpauseMigration");
}

let STEP = 3;
let isPatchUpgrade = false;
async function main() {
  const gettersFacet = await hre.ethers.getContractAt("GettersFacet", config.diamondProxyAddress);
  const facets = await gettersFacet.facetAddresses();
  console.log("Facets in this diamond:", facets);

  // Protocol version: uint96, 32bit(major).32bit(minor or protocol version).32bit(patch)
  const oldProtocolVersion = await gettersFacet.getProtocolVersion();
  const newProtocolVersion = isPatchUpgrade ?  oldProtocolVersion.add(1) : (() => {
    const preMinor = BigInt(oldProtocolVersion) >> 32n;
    console.log("old minor:", preMinor);
    const newMinor = preMinor + 1n;
    console.log("new minor:", newMinor);
    return newMinor * PatchZero;
  })();
  console.log("Old protocol version:", oldProtocolVersion.toHexString());
  console.log("New protocol version:", '0x' + newProtocolVersion.toString(16));
  const salt = '0x' + newProtocolVersion.toString(16).padStart(64, '0');
  console.log("New salt:", salt);

  const upgradeTimestamp = Math.floor(Date.now() / 1000);
  console.log("Upgrade timestamp:", upgradeTimestamp);

  // 1. A chain has to keep their protocol version up to date, as processing a block requires the latest or previous protocol version
  //    to solve this we will need to add the feature to create batches with only the protocol upgrade tx, without any other txs.
  // 2. A chain might become out of sync if it launches while we are in the middle of a protocol upgrade. This would mean they cannot process their genesis upgrade
  //    as their protocolversion would be outdated, and they also cannot process the protocol upgrade tx as they have a pending upgrade.
  // 3. The protocol upgrade is increased in the BaseZkSyncUpgrade, in the executor only the systemContractsUpgradeTxHash is checked
  const deadline = Math.floor(Date.now() / 1000 + 60 * 60 * 24 * 90); // 90 days since now
  console.log("Upgrade deadline:", deadline);

  console.log(config);

  await info();

  let forceDeploymentData, forceDeploymentHashes;
  if (isPatchUpgrade) {
    const l2DeployerIface = new utils.Interface([
      "function forceDeployOnAddresses((bytes32 bytecodeHash,address newAddress,bool callConstructor,uint256 value,bytes input)[])"
    ]);

    const nodeAddr = "0x00000000000000000000000000000000000080fe";
    forceDeploymentHashes = ["0x0100057d94ccddc7f47f291a612ad0f03a0755749522bba44c90798a0e7e95dc"];

    const deployments = [{
      bytecodeHash: forceDeploymentHashes[0],
      newAddress: nodeAddr,
      callConstructor: false,  // or false if you don’t need constructor
      value: 0,
      input: "0x"
    }];

    forceDeploymentData = l2DeployerIface.encodeFunctionData(
      "forceDeployOnAddresses",
      [deployments]
    );
  } else {
    // Latest NodeContract
    // forceDeploymentData = "0xe9f18c170000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200100057d94ccddc7f47f291a612ad0f03a0755749522bba44c90798a0e7e95dc00000000000000000000000000000000000000000000000000000000000080fe0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000000";
    // forceDeploymentHashes = ["0x0100057d94ccddc7f47f291a612ad0f03a0755749522bba44c90798a0e7e95dc"];

    // L2BaseToken
    forceDeploymentData = "0xe9f18c170000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200100042b16c2d6ed1c17ccfe56e732eb588fdd8cad4fc2409a3c7ec7ee6180e6000000000000000000000000000000000000000000000000000000000000800a0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000000";
    forceDeploymentHashes = ["0x0100042b16c2d6ed1c17ccfe56e732eb588fdd8cad4fc2409a3c7ec7ee6180e6"];
  }
  console.log('forceDeploymentData',forceDeploymentData);
  console.log('forceDeploymentHashes',forceDeploymentHashes);
  
  switch (STEP) {
    case 1:
      await pauseMigration(salt);
      // await addUpgradeFacetToDiamond(); // Run only once
      break;
    case 2:
      // NodeContract/L2BaseToken/...
      const callData = await setNewVersionUpgradeFunctionData(
        isPatchUpgrade,
        upgradeTimestamp,
        deadline,
        oldProtocolVersion,
        newProtocolVersion,
        forceDeploymentData,
        forceDeploymentHashes
      );
      console.log("initialCallData:", callData["initialCallData"]);

      await governanceExecuteInstant([[config.stmAddress, 0, callData["callData"]]], Bytes32Zero, Bytes32Zero);
      await sleep(120000);

      await upgradeChainFromVersion(oldProtocolVersion, callData["initialCallData"]);
      await sleep(120000);

      await setUpgradeTimestamp(newProtocolVersion, upgradeTimestamp);
      break;
    case 3:
      await unpauseMigration(salt);
      break;
    default:
      console.log("Replace a specific step 1 - 2:");
      return;
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
