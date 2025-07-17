// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICreatorPool
/// @notice Minimal interface for CreatorPool interaction from L2BaseToken
interface ICreatorPool {
    /// @notice Called by L2BaseToken when a fan updates stake
    /// @param fan The address of the fan
    /// @param newStake The new stake value after the update
    function updateFanStake(address fan, uint256 newStake) external;
}
