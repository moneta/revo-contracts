// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts-v4/contracts/security/ReentrancyGuard.sol";
import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {INodeContract, NodeData, SCALE_FACTOR, PENALTY_FACTOR} from "./interfaces/INodeContract.sol";
import {InsufficientDelegation, Unauthorized, CooldownActive, NodeCutTooHigh, CreatorLimitReached, EmptyNodeSet, ZeroAmountError, InvalidNode, TransferEthFailed} from "./SystemContractErrors.sol";
import {BOOTLOADER_FORMAL_ADDRESS, BASE_TOKEN_ADDRESS} from "./Constants.sol";

contract NodeContract is INodeContract, ReentrancyGuard {
    uint256 public constant MAX_NODE_NUMBER = 250;
    uint256 public constant MAX_CREATORS_PER_NODE = 200;
    uint256 internal constant BATCHES_PER_EPOCH = 194_400;
    uint256 public constant GUARANTOR_COOLDOWN = 1 hours;   // or e.g., 3600 for 1hr
    
    uint256 public constant MAX_NODE_CUT_BPS = 5000;        // 50%
    uint256 public constant DEFAULT_NODE_CUT_BPS = 2000;    // 20%
    uint256 public constant BPS_DENOMINATOR = 10000;

    int256 private _maxP;
    int256 private _minP;
    int256 private _totalP;
    
    uint256 public batchReward;
    uint256 public batchCount;
    address public guarantor;
    bool public selectedOnce = false;
    address[] public nodes;
    uint256 public lastGuarantorChange;

    mapping(address => NodeData) public nodeSet;
    mapping(address => uint256) public nodeCutBps;
    mapping(address => address[]) public nodeDelegators;                // node => list of creator addresses
    mapping(address => mapping(address => bool)) public isDelegator;    // prevent duplication
    mapping(address => uint256) public creatorPendingReward;            // unclaimed rewards
    mapping(address => uint256) public nodeTotalDelegation;             // node => total delegated from creators
    mapping(address => uint256) public pendingGuarantorRefunds;

    constructor() {
        batchReward = 80 * 10 ** 18;
        batchCount = 0;
    }

    event NodeRewardPaid(address indexed node, uint256 amount);
    event CreatorRewardPaid(address indexed creator, address indexed node, uint256 amount);
    event RewardTransferFailed(address indexed creator, uint256 amount);
    event NodeCutUpdated(address indexed node, uint256 newCut);
    event RefundDeferred(address indexed guarantor, uint256 amount);
    event RefundClaimed(address indexed guarantor, uint256 amount);

    modifier onlyBootloader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyL2BaseToken() {
        if (msg.sender != BASE_TOKEN_ADDRESS) revert Unauthorized(msg.sender);
        _;
    }

    function setNodeCut(uint256 cutBps) external {
        if (nodeSet[msg.sender].stakeAmount <= 0) {
            revert Unauthorized(msg.sender);
        }

        if(cutBps > MAX_NODE_CUT_BPS) {
            revert NodeCutTooHigh();
        }

        nodeCutBps[msg.sender] = cutBps;

        emit NodeCutUpdated(msg.sender, cutBps);
    }

    function _removeCreatorFromNode(address node, address creator) internal {
        address[] storage list = nodeDelegators[node];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ) {
            if (list[i] == creator) {
                list[i] = list[len - 1];
                list.pop();
                isDelegator[node][creator] = false;
                return;
            }

            unchecked { ++i; }
        }
    }

    function distributeToCreators(address node, uint256 totalReward) internal nonReentrant {
        uint256 cut = nodeCutBps[node];
        if (cut == 0) {
            cut = DEFAULT_NODE_CUT_BPS; // fallback to default if unset
        }

        uint256 nodeCut = (totalReward * cut) / BPS_DENOMINATOR;
        uint256 creatorPool = totalReward - nodeCut;

        // Pay node's reward cut
        (bool nodePaid, ) = node.call{value: nodeCut}("");
        if (!nodePaid) {
            revert TransferEthFailed();
        }
        emit NodeRewardPaid(node, nodeCut);

        uint256 totalDelegation = nodeTotalDelegation[node];
        if (totalDelegation == 0) return;

        address[] memory creators = nodeDelegators[node];
        uint256 distributed;

        uint256 len = creators.length;
        for (uint256 i = 0; i < len; ) {
            address creator = creators[i];
            uint256 creatorDelegation = IBaseToken(BASE_TOKEN_ADDRESS).delegation(creator, node);
            if (creatorDelegation == 0) { unchecked { ++i; } continue; }

            uint256 share = (creatorPool * creatorDelegation) / totalDelegation;
            distributed += share;

            (bool success, ) = creator.call{value: share}("");
            if (!success) {
                creatorPendingReward[creator] += share;
                emit RewardTransferFailed(creator, share);
            } else {
                emit CreatorRewardPaid(creator, node, share);
            }
            unchecked { ++i; }
        }

        // Refund any leftover (due to division rounding) to node
        uint256 remainder = creatorPool - distributed;
        if (remainder > 0) {
            (bool ok, ) = node.call{value: remainder}("");
            if (!ok) revert TransferEthFailed();
        }
    }

    function claimPendingReward() external nonReentrant {
        uint256 amount = creatorPendingReward[msg.sender];
        if (amount == 0) revert ZeroAmountError();

        creatorPendingReward[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            creatorPendingReward[msg.sender] = amount; // restore on failure
            revert TransferEthFailed();
        }

        emit RewardClaimed(msg.sender, amount);
    }

    // implement only bootloader
    function selectNode() external override onlyBootloader returns (address winner) {
        // if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
        //     revert Unauthorized(msg.sender);
        // }
        if (nodes.length == 0) {
            return address(0);
        }

        int256 diff = _maxP - _minP;
        int256 threshold = 2 * _totalP;
        if (diff > threshold) {
            int256 scale = diff * SCALE_FACTOR / threshold;
            winner = _selectNodeInRange(scale);
        } else {
            winner = _selectNodeInStableSet();
        }
        if (!selectedOnce) selectedOnce = true;
        
        batchReward = rewardPerBlock(batchCount);
        if (batchReward > 0 && address(this).balance >= batchReward) {
            distributeToCreators(winner, batchReward);
            ++batchCount;
        }

        emit NodeSelected(winner);
    }

    function _selectNodeInStableSet() internal returns (address) {
        uint256 winnerIndex;
        _totalP = 0;
        _maxP = type(int256).min;
        _minP = type(int256).max;

        uint256 len = nodes.length;
        for (uint256 i = 0; i < len; ) {
            NodeData storage node = nodeSet[nodes[i]];
            node.priority += int256(node.stakeAmount);

            _totalP += int256(node.stakeAmount);
            if (_updateMinMaxP(node.priority) == 1) winnerIndex = i; // 1: update maxP

            unchecked { ++i; }
        }

        address winner = nodes[winnerIndex];
        nodeSet[winner].priority -= _totalP;
        return winner;
    }

    function _selectNodeInRange(int256 scale) internal returns (address) {
        int256 sum = 0;
        
        uint256 nodeCount = nodes.length;
        for (uint256 i=0; i<nodeCount; ) {
            nodeSet[nodes[i]].priority = nodeSet[nodes[i]].priority * SCALE_FACTOR  / scale;
            sum += nodeSet[nodes[i]].priority;

            unchecked { ++i; }
        }

        int256 avg = sum / int256(nodeCount);
        uint256 winnerIndex;

        _totalP = 0;
        _maxP = type(int256).min;
        _minP = type(int256).max;
        for (uint256 i=0; i<nodeCount; ) {
            NodeData storage node = nodeSet[nodes[i]];
            node.priority -= avg;
            node.priority += int256(node.stakeAmount);

            _totalP += int256(node.stakeAmount);
            
            if (_updateMinMaxP(node.priority) == 1) winnerIndex = i;

            unchecked { ++i; }
        }

        address winner = nodes[winnerIndex];
        nodeSet[winner].priority -= _totalP;
        _updateMinMaxP(nodeSet[winner].priority);

        return winner;
    }

    function _updateMinMaxP(int256 value) internal returns (uint256) {
        // compare new value with minP and maxP
        if (_maxP < value) {
            _maxP = value;
            return 1;
        }
        if (_minP > value) {
            _minP = value;
            return 2;
        }
        return 0;
    }

    function onNodeStaked(address node, uint256 amount) external onlyL2BaseToken {
        uint256 delegation = IBaseToken(BASE_TOKEN_ADDRESS).delegatedTo(node);
        uint256 totalStakeAmount = amount + delegation;

        // Optional eviction logic if full
        if (nodes.length == MAX_NODE_NUMBER) {
            uint256 index = getMinimumDelegation();
            if (totalStakeAmount <= nodeSet[nodes[index]].stakeAmount) {
                revert InsufficientDelegation(nodeSet[nodes[index]].stakeAmount, totalStakeAmount);
            }

            _unstake(nodes[index], true); // safe internal cleanup
        }

        int256 priority = selectedOnce
            ? -PENALTY_FACTOR * _totalP / SCALE_FACTOR
            : int256(0);

        nodeSet[node] = NodeData(nodes.length, priority, totalStakeAmount);
        nodes.push(node);

        if (selectedOnce) {
            _totalP += int256(totalStakeAmount);
            // move priority values by average like removal
            _movePriorityByAvg();
        }

        emit NewNode(node);
    }


    function onNodeUnstaked(address node) external onlyL2BaseToken {
        _unstake(node, false); // local-only cleanup
    }


    function increaseDelegation(address node, address creator, uint256 amount) external onlyL2BaseToken returns(uint256) {
        return updateDelegation(node, creator, amount, true);
    }

    function decreaseDelegation(address node, address creator, uint256 amount) external onlyL2BaseToken returns(uint256) {
        return updateDelegation(node, creator, amount, false);
    }

    function updateDelegation(address node, address creator, uint256 amount, bool flag) internal onlyL2BaseToken returns(uint256) {
        if (nodeSet[node].stakeAmount == 0) {
            revert InvalidNode(msg.sender);
        }

        NodeData storage data = nodeSet[node];
        if (flag) {
            // ADD delegation
            nodeTotalDelegation[node] += amount;
            data.stakeAmount += amount;

            // If creator not yet in list, enforce limit
            if (!isDelegator[node][creator]) {
                if(nodeDelegators[node].length >= MAX_CREATORS_PER_NODE) {
                    revert CreatorLimitReached();
                }

                isDelegator[node][creator] = true;
                nodeDelegators[node].push(creator);
            }
        } else {
            // REMOVE delegation
            data.stakeAmount -= amount;
            nodeTotalDelegation[node] -= amount;

            // remove creator from list when balance hits zero (see below)
            if (IBaseToken(BASE_TOKEN_ADDRESS).delegation(creator, node) == 0) {
                _removeCreatorFromNode(node, creator);
            }
        }

        return data.stakeAmount;
    }

    function _unstake(address node, bool evicted) internal {
        NodeData memory data = nodeSet[node];
        if (data.stakeAmount == 0) {
            revert Unauthorized(msg.sender);
        }

        uint256 index = data.index;
        address lastNode = nodes[nodes.length - 1];
        nodes[index] = lastNode;
        nodeSet[lastNode].index = index;
        nodes.pop();

        if (selectedOnce) {
            _totalP -= int256(data.stakeAmount);
            _maxP = type(int256).min;
            _minP = type(int256).max;
            _movePriorityByAvg();
        }

        emit NodeRemoved({
            node: node,
            finalStakeAmount: data.stakeAmount,
            totalDelegation: nodeTotalDelegation[node],
            creatorCount: nodeDelegators[node].length,
            evicted: evicted // if evicted, or false if voluntary
        });

        delete nodeCutBps[node];
        delete nodeTotalDelegation[node];
        address[] storage list = nodeDelegators[node];
        uint256 len = list.length;
        for (uint256 i = len; i > 0; ) {
            address creator = list[i - 1] ;
            isDelegator[node][creator] = false;
            list.pop();
            unchecked { --i; }
        }
        delete nodeSet[node];
    }

    function _movePriorityByAvg() internal {
        int256 sum = 0;

        uint256 nodeCount = nodes.length;
        for (uint256 i=0; i<nodeCount; ) {
            sum += nodeSet[nodes[i]].priority;
            unchecked { ++i; }
        }
        int256 avg = sum / int256(nodeCount);

        for (uint256 i=0; i<nodeCount; ) {
            NodeData storage node = nodeSet[nodes[i]];
            node.priority -= avg;
            
            _updateMinMaxP(node.priority);
            unchecked { ++i; }
        }
    }

    function claimRefund() external nonReentrant {
        uint256 amount = pendingGuarantorRefunds[msg.sender];
        if(amount <= 0) {
            revert ZeroAmountError();
        }

        pendingGuarantorRefunds[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if(!success) {
            revert TransferEthFailed();
        }

        emit RefundClaimed(msg.sender, amount);
    }

    function deposit() external payable nonReentrant {
        uint256 balanceBefore = address(this).balance - msg.value;

        if (msg.value >= batchReward ) {
            // Check cooldown if changing guarantor
            if (msg.sender != guarantor) {
                if (guarantor != address(0) && balanceBefore >= batchReward) {
                    revert Unauthorized(msg.sender); // optional: prevent mid-cycle changes
                }

                if(block.timestamp < lastGuarantorChange + GUARANTOR_COOLDOWN) {
                    revert CooldownActive();
                }

                // refund previous guarantor if needed
                if (guarantor != address(0) && balanceBefore > 0) {
                    (bool success, ) = guarantor.call{value: balanceBefore}("");
                    if (!success) {
                        pendingGuarantorRefunds[guarantor] += balanceBefore;
                        emit RefundDeferred(guarantor, balanceBefore);
                    }
                }

                // set new guarantor
                guarantor = msg.sender;
                lastGuarantorChange = block.timestamp;
            }

            emit RewardDeposit(msg.sender, msg.value);
        }
    }

    function withdraw() external payable nonReentrant {
        if (msg.sender != guarantor) {
            revert Unauthorized(msg.sender);
        }
        uint256 amount = address(this).balance;
        if (amount > 0) {
            (bool success, ) = guarantor.call{value: amount}("");
            if (!success) {
                revert TransferEthFailed();
            }
            guarantor = address(0);

            emit RewardWithdrawal(msg.sender, amount);
        }
    }

    function getMinimumDelegation() public view returns (uint256) {
        if (nodes.length == 0) {
            revert EmptyNodeSet();
        }

        uint256 minD = type(uint256).max;
        uint256 minIndex;
        uint256 nodeCount = nodes.length;
        for (uint256 i=0; i<nodeCount; ) {
            NodeData memory node = nodeSet[nodes[i]];
            if (minD > node.stakeAmount) {
                minD = node.stakeAmount;
                minIndex = i;
            }
            unchecked { ++i; }
        }

        return minIndex;
    }

    function isNode(address _node) external view override returns (bool) {
        return nodeSet[_node].stakeAmount > 0;
    }

    function getNodeAtIndex(uint256 index) external override view returns (address) {
        return nodes[index];
    }

    function getNodeCount() external override view returns (uint256) {
        return nodes.length;
    }
    
    function getNodes() external override view returns (address[] memory) {
        return nodes;
    }
    
    function getNode(address _node) external override view returns (NodeData memory) {
        return nodeSet[_node];
    }

    function getNodeDelegatorCount(address node) external view returns (uint256) {
        return nodeDelegators[node].length;
    }

    function getLowestDelegator(address node) external view returns (address lowest, uint256 amount) {
        address[] memory creators = nodeDelegators[node];
        uint256 minAmount = type(uint256).max;
        address minCreator = address(0);

        uint256 len = creators.length;
        for (uint256 i = 0; i < len; ) {
            address creator = creators[i];
            uint256 creatorDelegation = IBaseToken(BASE_TOKEN_ADDRESS).delegation(creator, node);
            if (creatorDelegation < minAmount) {
                minAmount = creatorDelegation;
                minCreator = creator;
            }
            unchecked { ++i; }
        }

        return (minCreator, minAmount);
    }

    function rewardPerBlock(uint256 batchNum) public pure returns (uint256) {
        uint256 e = batchNum / BATCHES_PER_EPOCH;
        if (e >= 40) return 0;

        uint256[40] memory REWARD_PER_BATCH_WEI = [
            uint256(80000000000000000000),
            uint256(75519649942760000000),
            uint256(71290219093462600000),
            uint256(67297654878512000000),
            uint256(63528691729923800000),
            uint256(59970807009567000000),
            uint256(56612179401841400000),
            uint256(53441649636547400000),
            uint256(50448683411446100000),
            uint256(47623336391319200000),
            uint256(44956221167234100000),
            uint256(42438476066235200000),
            uint256(40061735707828500000),
            uint256(37818103209432200000),
            uint256(35700123948443600000),
            uint256(33700760793745100000),
            uint256(31813370724354000000),
            uint256(30031682757530800000),
            uint256(28349777113009300000),
            uint256(26762065544121600000),
            uint256(25263272770465800000),
            uint256(23848418950425500000),
            uint256(22512803135305200000),
            uint256(21251987650106500000),
            uint256(20061783349048800000),
            uint256(18938235696845700000),
            uint256(17877611629490800000),
            uint256(16876387150897000000),
            uint256(15931235624178000000),
            uint256(15039016718669300000),
            uint256(14196765975965300000),
            uint256(13401684960302300000),
            uint256(12651131960564800000),
            uint256(11942613213018900000),
            uint256(11273774615612100000),
            uint256(10642393906307500000),
            uint256(10046373279466300000),
            uint256(9483732415744940000),
            uint256(8952601902348290000),
            uint256(8451217021777880000)
        ];
        
        return REWARD_PER_BATCH_WEI[e];
    }
}
