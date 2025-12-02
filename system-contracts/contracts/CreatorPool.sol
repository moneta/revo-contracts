// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts-v4/contracts/security/ReentrancyGuard.sol";
import {InvalidInput, InvalidCreator, Unauthorized, TooBigCut, ZeroAmountError, NotEnoughGas, TransferEthFailed} from "./SystemContractErrors.sol";
import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {BASE_TOKEN_ADDRESS, NODE_CONTRACT_ADDR} from "./Constants.sol";

/// @title CreatorPool
/// @notice A smart contract pool where fans can stake to support creators who have staked to a node.
contract CreatorPool is ReentrancyGuard {
    uint256 public constant PRECISION = 1e12;
    uint256 public constant MAX_CREATOR_CUT = 10000; // 100% in basis points

    address public immutable NODE;
    address public immutable FACTORY;
    address public immutable CREATOR;
    uint256 public creatorCut; // out of 10000 (e.g., 2000 = 20%)
    string public poolName;

    uint256 public creatorStaked;      // Creator's initial stake
    uint256 public totalFanStaked;
    uint256 public accRewardPerShare;
    mapping(address => uint256) public fanStakes;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pendingRewards;    

    event FanStaked(address indexed fan, uint256 amount);
    event RewardReceived(uint256 amount);
    event StakeRegisteredToNode(address indexed node, uint256 amount);
    event RewardClaimed(address indexed fan, uint256 amount);
    event CreatorStaked(uint256 amount);
    event CreatorUnstaked(uint256 amount);

    modifier onlyFactory() {
        if (msg.sender != FACTORY) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyBaseToken() {
        if (msg.sender != BASE_TOKEN_ADDRESS) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != CREATOR) revert Unauthorized(msg.sender);
        _;
    }

    constructor(address _node, address _factory, address _creator, uint256 _creatorCut, string memory _poolName) payable {
        if (_node == address(0)) revert InvalidInput();
        if (_creator == address(0)) revert InvalidCreator(_creator);
        if (_creatorCut > MAX_CREATOR_CUT) revert TooBigCut();

        NODE = _node;
        FACTORY = _factory;
        CREATOR = _creator;
        creatorCut = _creatorCut;
        poolName = _poolName;

        // Creator's initial ETH is recorded separately
        if (msg.value > 0) {
            creatorStaked = msg.value;
            emit CreatorStaked(msg.value);
        }
    }

    function isValidCreatorCut(uint256 cut) public pure returns (bool) {
        return cut <= MAX_CREATOR_CUT;
    }

    /// @notice Register this pool by staking REVO to the selected node
    function registerAsCreatorPool() external payable nonReentrant {
        uint256 amount = creatorStaked;
        if (amount <= 0) revert ZeroAmountError();

        IBaseToken(BASE_TOKEN_ADDRESS).stake(NODE, amount);
        emit StakeRegisteredToNode(NODE, amount);
    }

    /// @notice Update fan stake (called by L2BaseToken)
    function updateFanStake(address fan, uint256 newStake) external onlyBaseToken {
        _claimReward(fan);

        totalFanStaked = totalFanStaked - fanStakes[fan] + newStake;

        if (newStake == 0) {
            // Fan has fully unstaked: clean up mappings
            delete fanStakes[fan];
            delete rewardDebt[fan];
            delete pendingRewards[fan];
        } else {
            fanStakes[fan] = newStake;
            rewardDebt[fan] = (newStake * accRewardPerShare) / PRECISION;
        }

        emit FanStaked(fan, newStake);
    }

    /// @notice Claim rewards for the caller
    function claimReward() external nonReentrant {
        _claimReward(msg.sender);
    }

    function _claimReward(address fan) internal {
        uint256 accumulated = (fanStakes[fan] * accRewardPerShare) / PRECISION;
        uint256 owed = accumulated - rewardDebt[fan] + pendingRewards[fan];
        if (owed > 0) {
            pendingRewards[fan] = 0;
            rewardDebt[fan] = accumulated;
            if (address(this).balance < owed) revert TransferEthFailed();
            (bool sent, ) = payable(fan).call{value: owed}("");
            if (!sent) revert TransferEthFailed();
            emit RewardClaimed(fan, owed);
        }
    }

    /// @notice Creator can unstake their initial stake from the node and withdraw it
    /// @dev Only callable by CREATOR. Fans' rewards are untouched.
    function unstakeFromNode() external onlyCreator nonReentrant {
        if (creatorStaked == 0) revert ZeroAmountError();

        uint256 amount = creatorStaked;
        creatorStaked = 0;

        IBaseToken(BASE_TOKEN_ADDRESS).unstake(NODE, amount);

        (bool sent, ) = payable(CREATOR).call{value: amount}("");
        if (!sent) revert TransferEthFailed();

        emit CreatorUnstaked(amount);
    }

    /// @notice View the pending reward for a fan (does not claim)
    /// @param fan The address of the fan
    /// @return reward The amount of REVO (in wei) the fan can claim
    function pendingReward(address fan) external view returns (uint256 reward) {
        uint256 stake = fanStakes[fan];
        if (stake == 0) return pendingRewards[fan];

        uint256 accumulated = (stake * accRewardPerShare) / PRECISION;
        reward = accumulated - rewardDebt[fan] + pendingRewards[fan];
    }

    /// @notice Receive REVO reward from NodeContract or additional stakes
    receive() external payable nonReentrant {
        if (msg.sender == NODE_CONTRACT_ADDR) {
            emit RewardReceived(msg.value);

            uint256 creatorShare = (msg.value * creatorCut) / MAX_CREATOR_CUT;
            uint256 fanShare = msg.value - creatorShare;

            // Fan share is distributed pro-rata; creator share is sent last
            if (fanShare > 0 && totalFanStaked > 0) {
                accRewardPerShare += (fanShare * PRECISION) / totalFanStaked;
            } else if (fanShare > 0) {
                creatorShare += fanShare; // no fans → creator gets it
            }

            if (creatorShare > 0) {
                (bool sent, ) = CREATOR.call{value: creatorShare}("");
                if (!sent) revert TransferEthFailed();
            }
        } else if (msg.sender != FACTORY) {
            revert Unauthorized(msg.sender);
        }
    }
}
