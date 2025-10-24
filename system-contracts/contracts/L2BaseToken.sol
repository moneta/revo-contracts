// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {NODE_CONTRACT_ADDR, MINIMUM_NODE_STAKE} from "./Constants.sol";
import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {INodeContract} from "./interfaces/INodeContract.sol";
import {ICreatorPool} from "./interfaces/ICreatorPool.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {BOOTLOADER_FORMAL_ADDRESS, DEPLOYER_SYSTEM_CONTRACT, L1_MESSENGER_CONTRACT, MSG_VALUE_SYSTEM_CONTRACT} from "./Constants.sol";
import {IMailbox} from "./interfaces/IMailbox.sol";
import {Unauthorized, InsufficientFunds, SelfStake, SelfUnstake, NodeStakeNotAllowed, CreatorToCreatorSake, MultiNodeStakeError, ZeroAmountError, InsufficientStake, InsufficientDelegation, CreatorLimitReached, UnstakingCooldown} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Native ETH contract.
 * @dev It does NOT provide interfaces for personal interaction with tokens like `transfer`, `approve`, and `transferFrom`.
 * Instead, this contract is used by the bootloader and `MsgValueSimulator`/`ContractDeployer` system contracts
 * to perform the balance changes while simulating the `msg.value` Ethereum behavior.
 */
contract L2BaseToken is IBaseToken, SystemContractBase {
    /// @notice Fan unstake cooldown period
    uint256 public constant FAN_UNSTAKE_COOLDOWN = 10 minutes;  
    uint256 public constant MAX_CREATORS_PER_NODE = 200;
    /// @notice The balances of the users.
    mapping(address account => uint256 balance) internal balance;

    /// @notice The total amount of tokens that have been minted.
    uint256 public override totalSupply;

    /// Revolution Upgrade
    mapping(address => uint256) internal stakes;
    mapping(address => uint256) internal delegated;
    mapping(address => uint256) public nodes;
    mapping(address => address) internal creatorPools;
    mapping(address => mapping(address => uint256)) internal _delegation;

    /// @notice Time until a fan can unstake from a creator after staking
    mapping(address => mapping(address => uint256)) public stakeCooldownUntil;

    modifier onlyNodeContract() {
        if (msg.sender != NODE_CONTRACT_ADDR) revert Unauthorized(msg.sender);
        _;
    }

    function stake(address _to) external payable override {
        if(msg.sender == _to) revert SelfStake();

        if (INodeContract(NODE_CONTRACT_ADDR).isNode(msg.sender)) {
            revert NodeStakeNotAllowed(msg.sender);
        }

        uint256 _amount = msg.value;

        if(_amount == 0) revert ZeroAmountError();

        if (balance[msg.sender] < _amount) revert InsufficientFunds(_amount, balance[msg.sender]);

        if (INodeContract(NODE_CONTRACT_ADDR).isNode(_to) && creatorPools[msg.sender] != address(0) && creatorPools[msg.sender] != _to) {    
            // don't allow creator stake to different nodes at the same time
            revert MultiNodeStakeError();
        }

        unchecked {
            uint256 old = _delegation[msg.sender][_to];
            balance[msg.sender] -= _amount;
            stakes[msg.sender] += _amount;
            _delegation[msg.sender][_to] += _amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.

            emit DelegationChanged({
                delegator: msg.sender, 
                delegatee: _to,
                oldAmount: old,
                newAmount: _delegation[msg.sender][_to],
                increased: true
            });
        }

        if (INodeContract(NODE_CONTRACT_ADDR).isNode(_to)) {   
            // Creator -> Node 
            // Check for new creator registering
            if (creatorPools[msg.sender] == address(0)) {       // msg.sender is not creator
                address lowestDelegator;
                uint256 minEffective;

                (lowestDelegator, minEffective) = INodeContract(NODE_CONTRACT_ADDR).getLowestDelegator(_to);

                if (INodeContract(NODE_CONTRACT_ADDR).getNodeDelegatorCount(_to) >= MAX_CREATORS_PER_NODE) {
                    uint256 newEffective = delegated[msg.sender] + _amount;

                    if (newEffective > minEffective) {
                        // Evict the lowest: simulate full unstake of own stake and remove contribution of fans
                        uint256 ownLow = _delegation[lowestDelegator][_to];
                        uint256 fansLow = delegated[lowestDelegator];
                        // assert(minEffective == ownLow + fansLow);

                        // First, refund own stake to lowestDelegator
                        _delegation[lowestDelegator][_to] -= ownLow;
                        stakes[lowestDelegator] -= ownLow;
                        balance[lowestDelegator] += ownLow;

                        emit DelegationChanged({
                            delegator: lowestDelegator,
                            delegatee: _to,
                            oldAmount: ownLow,
                            newAmount: 0,
                            increased: false
                        });
                        emit Unstake(lowestDelegator, _to, ownLow);

                        // Then, decrease node totals by total effective (own + fans)
                        INodeContract(NODE_CONTRACT_ADDR).decreaseDelegation(_to, lowestDelegator, ownLow + fansLow);
                        delete creatorPools[lowestDelegator];
                        emit RevokeCreatorPool(lowestDelegator, _to);
                    } else {
                        revert CreatorLimitReached();
                    }
                }

                INodeContract(NODE_CONTRACT_ADDR).increaseDelegation(_to, msg.sender, delegated[msg.sender] + _amount);
                creatorPools[msg.sender] = _to;
                emit GrantCreatorPool(msg.sender, _to);
            } else {
                INodeContract(NODE_CONTRACT_ADDR).increaseDelegation(_to, msg.sender, _amount);
            }

            stakeCooldownUntil[msg.sender][_to] = block.timestamp + FAN_UNSTAKE_COOLDOWN;
        } else if (creatorPools[_to] != address(0)) {
            // Fan -> Creator

            // Prevent self-loop
            if (creatorPools[msg.sender] == _to) {
                revert SelfStake(); 
            }

            // Prevent Creator -> Creator
            if (creatorPools[msg.sender] != address(0)) {
                revert CreatorToCreatorSake(msg.sender, _to);
            }


            unchecked {
                delegated[_to] += _amount;
            }

            // fan's staking
            address node = creatorPools[_to];
            if (node != address(0)) {
                INodeContract(NODE_CONTRACT_ADDR).increaseDelegation(node, _to, _amount);
            }

            // Update CreatorPool stake record
            ICreatorPool(_to).updateFanStake(msg.sender, _delegation[msg.sender][_to]);
        }

        emit Stake(msg.sender, _to, _amount);
    }

    function unstake(address _from) external override {
        _unstake(_from, _delegation[msg.sender][_from]);
    }

    function unstake(address _from, uint256 _amount) external override {
        _unstake(_from, _amount);
    }
    
    /// @notice Unstake tokens from one address to another.
    /// @param _from The address to unstake the ETH from.
    /// @param _amount The amount of ETH in wei being unstake.
    function _unstake(address _from, uint256 _amount) internal {
        if(_amount == 0) {
            revert ZeroAmountError();
        }
        if(msg.sender == _from) {
            revert SelfUnstake();
        }
        uint256 fromStake = _delegation[msg.sender][_from];
        if (fromStake < _amount) {
            revert InsufficientDelegation(_amount, fromStake);
        }

        if (block.timestamp < stakeCooldownUntil[msg.sender][_from]) {
            revert UnstakingCooldown(msg.sender, _from);
        }

        unchecked {
            _delegation[msg.sender][_from] -= _amount;
            stakes[msg.sender] -= _amount;
            balance[msg.sender] += _amount;
            if (_delegation[msg.sender][_from] == 0) {
                delete _delegation[msg.sender][_from];
            }
        }
        
        if (INodeContract(NODE_CONTRACT_ADDR).isNode(_from)) { // creator unstake from node
            if (_delegation[msg.sender][_from] == 0) {
                INodeContract(NODE_CONTRACT_ADDR).decreaseDelegation(_from, msg.sender, delegated[msg.sender] + _amount);
                
                emit RevokeCreatorPool(msg.sender, _from);
            } else {
                INodeContract(NODE_CONTRACT_ADDR).decreaseDelegation(_from, msg.sender, _amount);
            }
        } else if (creatorPools[_from] != address(0)) { // Fan unstake from creator
            unchecked {
                delegated[_from] -= _amount;
            }
            address node = creatorPools[_from];
            if (node != address(0)) {
                INodeContract(NODE_CONTRACT_ADDR).decreaseDelegation(node, _from, _amount);
            }

            // Update CreatorPool stake record
            ICreatorPool(_from).updateFanStake(msg.sender, _delegation[msg.sender][_from]);
            emit FanUnstaked(msg.sender, _from, _amount, _delegation[msg.sender][_from]);
        }

        if (_delegation[msg.sender][_from] == 0) {
            delete _delegation[msg.sender][_from];
            delete stakeCooldownUntil[msg.sender][_from]; // Clean up storage
        }

        emit DelegationChanged({
            delegator: msg.sender,
            delegatee: _from,
            oldAmount: fromStake,
            newAmount: _delegation[msg.sender][_from],
            increased: false
        });
        emit Unstake(msg.sender, _from, _amount);
    }

    function stakeAsNode(uint256 _amount) external {
        if (_amount < MINIMUM_NODE_STAKE) {
            revert InsufficientStake(MINIMUM_NODE_STAKE, _amount);
        }

        uint256 fromBalance = balance[msg.sender];
        if (fromBalance < _amount) {
            revert InsufficientFunds(_amount, fromBalance);
        }

        unchecked {
            balance[msg.sender] = fromBalance - _amount;
            stakes[msg.sender] += _amount;
            nodes[msg.sender] += _amount;
        }

        // Notify the node registry AFTER local state updates succeed
        INodeContract(NODE_CONTRACT_ADDR).onNodeStaked{gas: 1000000}(msg.sender, _amount);

        emit NodeStake(msg.sender, _amount);
    }


    function addNodeStake(address _account, uint256 _amount) external onlyNodeContract {
        uint256 fromBalance = balance[_account];
        if (fromBalance < _amount) {
            revert InsufficientFunds(_amount, fromBalance);
        }

        unchecked {
            balance[_account] = fromBalance - _amount;
            stakes[_account] += _amount;
            nodes[_account] += _amount;
        }
        emit NodeStake(_account, _amount);
    }

    function unstakeAsNode() external {
        uint256 amount = nodes[msg.sender];
        if (amount == 0) {
            revert Unauthorized(msg.sender);
        }

        unchecked {
            balance[msg.sender] += amount;
            stakes[msg.sender] -= amount;
            delete nodes[msg.sender];
        }

        INodeContract(NODE_CONTRACT_ADDR).onNodeUnstaked(msg.sender);

        emit NodeUnstake(msg.sender, amount);
    }
    
    function removeNodeStake(address _account) external {
        if (msg.sender != NODE_CONTRACT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        uint256 amount = nodes[_account];
        unchecked {
            balance[_account] += amount;
            stakes[_account] -= amount;
            delete nodes[_account];
        }
        emit NodeUnstake(_account, amount);
    }

    function canUnstake(address fan, address creator) public view returns (bool) {
        return block.timestamp >= stakeCooldownUntil[fan][creator];
    }

    function stakeOf(address _account) external view override returns (uint256) {
        return stakes[_account];
    }
    
    function delegatedTo(address _account) external view override returns (uint256) {
        return delegated[_account];
    }
    
    function delegation(address _from, address _to) external view override returns (uint256) {
        return _delegation[_from][_to];
    }

    /// @notice Transfer tokens from one address to another.
    /// @param _from The address to transfer the ETH from.
    /// @param _to The address to transfer the ETH to.
    /// @param _amount The amount of ETH in wei being transferred.
    /// @dev This function can be called only by trusted system contracts.
    /// @dev This function also emits "Transfer" event, which might be removed
    /// later on.
    function transferFromTo(address _from, address _to, uint256 _amount) external override {
        if (
            msg.sender != MSG_VALUE_SYSTEM_CONTRACT &&
            msg.sender != address(DEPLOYER_SYSTEM_CONTRACT) &&
            msg.sender != BOOTLOADER_FORMAL_ADDRESS
        ) {
            revert Unauthorized(msg.sender);
        }

        uint256 fromBalance = balance[_from];
        if (fromBalance < _amount) {
            revert InsufficientFunds(_amount, fromBalance);
        }
        unchecked {
            balance[_from] = fromBalance - _amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            balance[_to] += _amount;
        }

        emit Transfer(_from, _to, _amount);
    }

    /// @notice Returns ETH balance of an account
    /// @dev It takes `uint256` as an argument to be able to properly simulate the behaviour of the
    /// Ethereum's `BALANCE` opcode that accepts uint256 as an argument and truncates any upper bits
    /// @param _account The address of the account to return the balance of.
    function balanceOf(uint256 _account) external view override returns (uint256) {
        return balance[address(uint160(_account))];
    }

    /// @notice Increase the total supply of tokens and balance of the receiver.
    /// @dev This method is only callable by the bootloader.
    /// @param _account The address which to mint the funds to.
    /// @param _amount The amount of ETH in wei to be minted.
    function mint(address _account, uint256 _amount) external override onlyCallFromBootloader {
        totalSupply += _amount;
        balance[_account] += _amount;
        emit Mint(_account, _amount);
    }

    /// @notice Initiate the withdrawal of the base token, funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable override {
        uint256 amount = _burnMsgValue();

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getL1WithdrawMessage(_l1Receiver, amount);
        L1_MESSENGER_CONTRACT.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiate the withdrawal of the base token, with the sent message. The funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable override {
        uint256 amount = _burnMsgValue();

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getExtendedWithdrawMessage(_l1Receiver, amount, msg.sender, _additionalData);
        L1_MESSENGER_CONTRACT.sendToL1(message);

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /// @dev The function burn the sent `msg.value`.
    /// NOTE: Since this contract holds the mapping of all ether balances of the system,
    /// the sent `msg.value` is added to the `this` balance before the call.
    /// So the balance of `address(this)` is always bigger or equal to the `msg.value`!
    function _burnMsgValue() internal returns (uint256 amount) {
        amount = msg.value;

        // Silent burning of the ether
        unchecked {
            // This is safe, since this contract holds the ether balances, and if user
            // sends a `msg.value` it will be added to the contract (`this`) balance.
            balance[address(this)] -= amount;
            totalSupply -= amount;
        }
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
    function _getL1WithdrawMessage(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, _to, _amount);
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
    function _getExtendedWithdrawMessage(
        address _to,
        uint256 _amount,
        address _sender,
        bytes memory _additionalData
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IMailbox.finalizeEthWithdrawal.selector, _to, _amount, _sender, _additionalData);
    }
}
