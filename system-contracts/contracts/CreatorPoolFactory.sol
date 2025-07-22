// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CreatorPool} from "./CreatorPool.sol";
import {INodeContract} from "./interfaces/INodeContract.sol";
import {PoolAlreadyCreated, TooBigCut, InvalidNode, TransferEthFailed, PoolRegistrationError} from "./SystemContractErrors.sol";
import {NODE_CONTRACT_ADDR} from "./Constants.sol";

contract CreatorPoolFactory {
    mapping(address => address) public creatorToPool;
    address[] public allPools;

    uint256 public constant MAX_CREATOR_CUT = 10000;

    event CreatorPoolCreated(address indexed creator, address indexed pool, address indexed node, uint256 creatorCut, string poolName);

    function createPool(address node, uint256 creatorCut, string calldata poolName) external payable returns (address poolAddr) {
        if(creatorToPool[msg.sender] != address(0)) revert PoolAlreadyCreated(msg.sender);

        if(creatorCut > MAX_CREATOR_CUT) revert TooBigCut();

        if(!INodeContract(NODE_CONTRACT_ADDR).isNode(node)) revert InvalidNode(node);

        // Deploy pool contract
        CreatorPool pool = new CreatorPool({
            _node: node, 
            _factory: address(this), 
            _creator: msg.sender, 
            _creatorCut: creatorCut, 
            _poolName: poolName
        });

        poolAddr = address(pool);

        // Track this pool before attempting stake to avoid race conditions
        creatorToPool[msg.sender] = poolAddr;
        allPools.push(poolAddr);

        // Stake to node and register the pool
        try pool.registerAsCreatorPool{value: msg.value}() {
            emit CreatorPoolCreated({
                creator: msg.sender,
                pool: poolAddr,
                node: node,
                creatorCut: creatorCut,
                poolName: poolName
            });
        } catch {
            // Rollback pool mapping and list
            delete creatorToPool[msg.sender];
            allPools.pop();

            // Attempt to refund ETH
            (bool refundSuccess, ) = msg.sender.call{value: msg.value}("");
            if(!refundSuccess) revert TransferEthFailed();

            revert PoolRegistrationError();
        }
    }


    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    function getPoolForCreator(address creator) external view returns (address) {
        return creatorToPool[creator];
    }
}
