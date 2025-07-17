// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct NodeData {
    uint256 index;
    uint256 priority;
    uint256 stakeAmount;
    uint128 rewardDebt;
}

int256 constant PENALTY_FACTOR = 11250;
int256 constant SCALE_FACTOR = 10000;
// address constant BASE_TOKEN_ADDR = 0x000000000000000000000000000000000000800A;
address constant BASE_TOKEN_ADDR = 0x000000000000000000000000000000000000900a; // for test
// address constant BOOTLOADER_ADDR = 0x0000000000000000000000000000000000008001;
address constant BOOTLOADER_ADDR = 0x0000000000000000000000000000000000009001; // for test

interface INodeContract {
    function selectNode() external returns (address winner);

    function stake(uint256 _stakeAmount) external;

    function unstake() external;

    function updateDelegation(address node, uint256 amount, bool flag) external;

    function getNodeAtIndex(uint256 index) external view returns (address);

    function getNodeCount() external view returns (uint256);

    function getNodes() external view returns (address[] memory);

    function isNode(address _node) external view returns (bool);

    function getNode(address _node) external view returns (NodeData memory);

    event NewNode(address indexed node);

    event NodeSelected(address indexed node);
    
    event RewardDeposit(address payer, uint256 amount);
    
    event RewardWithdrawal(address receiver, uint256 amount);

    event NodeRemoved(address indexed node, uint256 finalStake);
}