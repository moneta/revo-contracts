// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CreatorPool} from "./CreatorPool.sol";
import {ICreatorPool} from "./interfaces/ICreatorPool.sol";
import {IL2BaseToken} from "./interfaces/IL2BaseToken.sol";
import {INodeContract} from "./interfaces/INodeContract.sol";
import {InvalidInput, PoolAlreadyCreated, TooBigCut, InvalidNode, TransferEthFailed} from "./SystemContractErrors.sol";

contract CreatorPoolFactory {
    address public immutable baseToken;
    address public immutable nodeContract;

    mapping(address => address) public creatorToPool;
    address[] public allPools;

    uint256 public constant MAX_CREATOR_CUT = 10000;

    event CreatorPoolCreated(address indexed creator, address indexed pool, address indexed node, uint256 creatorCut);

    constructor(address _baseToken, address _nodeContract) {
        if(_baseToken == address(0) || _nodeContract == address(0)) revert InvalidInput();
        baseToken = _baseToken;
        nodeContract = _nodeContract;
    }

    function createPool(address node, uint256 creatorCut) external payable returns (address poolAddr) {
        if(creatorToPool[msg.sender] != address(0)) revert PoolAlreadyCreated();

        if(creatorCut > MAX_CREATOR_CUT) revert TooBigCut();

        if(!INodeContract(nodeContract).isNode(node)) revert InvalidNode(node);

        // Deploy pool contract
        CreatorPool pool = new CreatorPool(baseToken, node, address(this), msg.sender, creatorCut);
        poolAddr = address(pool);

        // Track this pool before attempting stake to avoid race conditions
        creatorToPool[msg.sender] = poolAddr;
        allPools.push(poolAddr);

        // Stake to node and register the pool
        try pool.registerAsCreatorPool{value: msg.value}() {
            emit CreatorPoolCreated(msg.sender, poolAddr, node, creatorCut);
        } catch {
            // Rollback pool mapping and list
            delete creatorToPool[msg.sender];
            allPools.pop();

            // Attempt to refund ETH
            (bool refundSuccess, ) = msg.sender.call{value: msg.value}("");
            if(!refundSuccess) revert TransferEthFailed();

            revert("Pool creation failed: stake registration reverted");
        }
    }


    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    function getPoolForCreator(address creator) external view returns (address) {
        return creatorToPool[creator];
    }
}
