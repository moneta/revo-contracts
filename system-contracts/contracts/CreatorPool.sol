// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts-v4/contracts/security/ReentrancyGuard.sol";
import {InvalidInput, InvalidCreator, Unauthorized, TooBigCut, ZeroAmountError, TransferEthFailed} from "./SystemContractErrors.sol";
import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {NODE_CONTRACT_ADDR} from "./Constants.sol";

/// @title CreatorPool
/// @notice A smart contract pool where fans can stake to support creators who have staked to a node.
contract CreatorPool is ReentrancyGuard {
    uint256 public constant PRECISION = 1e12;
    uint256 public constant MAX_CREATOR_CUT = 10000; // 100% in basis points

    address public immutable baseToken;
    address public immutable node;
    address public immutable factory;
    address public immutable creator;
    uint256 public creatorCut; // out of 10000 (e.g., 2000 = 20%)
  
    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    mapping(address => uint256) public fanStakes;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pendingRewards;    

    event FanStaked(address indexed fan, uint256 amount);
    event RewardReceived(uint256 amount);
    event StakeRegisteredToNode(address indexed node, uint256 amount);
    event RewardClaimed(address indexed fan, uint256 amount);

    modifier onlyFactory() {
        if(msg.sender != factory) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyBaseToken() {
        if(msg.sender != baseToken) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyNodeContract() {
        if (msg.sender != NODE_CONTRACT_ADDR) revert Unauthorized(msg.sender);
        _;
    }

    constructor(address _baseToken, address _node, address _factory, address _creator, uint256 _creatorCut) {
        if(_baseToken == address(0) || _node == address(0)) revert InvalidInput();

        if(_creator == address(0)) revert InvalidCreator(_creator);

        if(_creatorCut > MAX_CREATOR_CUT) revert TooBigCut();

        baseToken = _baseToken;
        node = _node;
        factory = _factory;
        creator = _creator;
        creatorCut = _creatorCut;
    }

    function isValidCreatorCut(uint256 cut) public pure returns (bool) {
      return cut <= MAX_CREATOR_CUT;
    }

    /// @notice Register this pool by staking ETH to the selected node
    function registerAsCreatorPool() external payable nonReentrant onlyFactory {
        if (msg.value <= 0) revert ZeroAmountError();

        IBaseToken(baseToken).stake{value: msg.value}(node);
        emit StakeRegisteredToNode(node, msg.value);
    }

    /// @notice Update fan stake (called by L2BaseToken)
    function updateFanStake(address fan, uint256 newStake) external onlyBaseToken {
        _claimReward(fan);

        totalStaked = totalStaked - fanStakes[fan] + newStake;
        fanStakes[fan] = newStake;
        rewardDebt[fan] = (newStake * accRewardPerShare) / PRECISION;

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
            rewardDebt[fan] = (fanStakes[fan] * accRewardPerShare) / PRECISION;
            (bool sent, ) = payable(fan).call{value: owed}("");

            if(!sent) revert TransferEthFailed();

            emit RewardClaimed(fan, owed);
        }
    }

    /// @notice Receive ETH reward from NodeContract
    receive() external payable onlyNodeContract {
        emit RewardReceived(msg.value);

        uint256 creatorShare = (msg.value * creatorCut) / MAX_CREATOR_CUT;
        uint256 remainingReward = msg.value - creatorShare;

        if (remainingReward > 0 && totalStaked > 0) {
            accRewardPerShare += (remainingReward * PRECISION) / totalStaked;
        }

        if (creatorShare > 0) {
            (bool success, ) = creator.call{value: creatorShare}("");
            if(!success) revert TransferEthFailed();
        }
    }
}
