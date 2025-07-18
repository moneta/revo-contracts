// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev

interface IBaseToken {
    function stake(address _to) external payable;

    function unstake(address _from) external;
    
    function unstake(address _from, uint256 _amount) external;

    function addNodeStake(address node, uint256 amount) external;

    function removeNodeStake(address node) external;

    function stakeOf(address _account) external view returns (uint256);
    
    function delegatedTo(address _account) external view returns (uint256);

    function delegation(address _from, address _to) external view returns (uint256);

    function balanceOf(uint256) external view returns (uint256);

    function transferFromTo(address _from, address _to, uint256 _amount) external;

    function totalSupply() external view returns (uint256);

    function mint(address _account, uint256 _amount) external;

    function withdraw(address _l1Receiver) external payable;

    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable;

    event Mint(address indexed account, uint256 amount);

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount);

    event WithdrawalWithMessage(
        address indexed _l2Sender,
        address indexed _l1Receiver,
        uint256 _amount,
        bytes _additionalData
    );

    event GrantCreatorPool(address indexed pool, address indexed node);
    
    event RevokeCreatorPool(address indexed pool, address indexed node);
    
    event Stake(address indexed from, address indexed pool, uint256 value);
    
    event Unstake(address indexed from, address indexed pool, uint256 value);

    event FanUnstaked(address indexed fan, address indexed creator, uint256 unstakedAmount, uint256 remainingStake);
    
    event NodeStake(address indexed node, uint256 value);
    
    event NodeUnstake(address indexed node, uint256 value);

    event DelegationChanged(
        address indexed delegator,
        address indexed delegatee,
        uint256 oldAmount,
        uint256 newAmount,
        bool increased
    );
}
