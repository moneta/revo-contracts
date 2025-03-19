// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry contract interface
interface IConsensusRegistry {
    /// @dev Represents a consensus node.
    /// @param validatorLastUpdateCommit The latest `validatorsCommit` where the node's validator attributes were updated.
    /// @param validatorLatest Validator attributes to read if `node.validatorLastUpdateCommit` < `validatorsCommit`.
    /// @param validatorSnapshot Validator attributes to read if `node.validatorLastUpdateCommit` == `validatorsCommit`.
    /// @param nodeOwnerIdx Index of the node owner within the array of node owners.
    struct Node {
        uint32 validatorLastUpdateCommit;
        uint32 nodeOwnerIdx;
        ValidatorAttr validatorLatest;
        ValidatorAttr validatorSnapshot;
    }

    /// @dev Represents the validator attributes of a consensus node.
    /// @param active A flag stating if the validator is active.
    /// @param removed A flag stating if the validator has been removed (and is pending a deletion).
    /// @param weight Validator's voting weight.
    /// @param pubKey Validator's BLS12-381 public key.
    /// @param proofOfPossession Validator's Proof-of-possession (a signature over the public key).
    struct ValidatorAttr {
        bool active;
        bool removed;
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature proofOfPossession;
    }

    /// @dev Represents a validator within a committee.
    /// @param weight Validator's voting weight.
    /// @param pubKey Validator's BLS12-381 public key.
    /// @param proofOfPossession Validator's Proof-of-possession (a signature over the public key).
    struct CommitteeValidator {
        uint32 weight;
        BLS12_381PublicKey pubKey;
        BLS12_381Signature proofOfPossession;
    }

    /// @dev Represents BLS12_381 public key.
    /// @param a First component of the BLS12-381 public key.
    /// @param b Second component of the BLS12-381 public key.
    /// @param c Third component of the BLS12-381 public key.
    struct BLS12_381PublicKey {
        bytes32 a;
        bytes32 b;
        bytes32 c;
    }

    /// @dev Represents BLS12_381 signature.
    /// @param a First component of the BLS12-381 signature.
    /// @param b Second component of the BLS12-381 signature.
    struct BLS12_381Signature {
        bytes32 a;
        bytes16 b;
    }

    error UnauthorizedOnlyOwnerOrNodeOwner();
    error NodeOwnerExists();
    error NodeOwnerDoesNotExist();
    error NodeOwnerNotFound();
    error ValidatorPubKeyExists();
    error InvalidInputNodeOwnerAddress();
    error InvalidInputBLS12_381PublicKey();
    error InvalidInputBLS12_381Signature();

    event NodeAdded(
        address indexed nodeOwner,
        uint32 validatorWeight,
        BLS12_381PublicKey validatorPubKey,
        BLS12_381Signature validatorPoP
    );
    event NodeDeactivated(address indexed nodeOwner);
    event NodeActivated(address indexed nodeOwner);
    event NodeRemoved(address indexed nodeOwner);
    event NodeDeleted(address indexed nodeOwner);
    event NodeValidatorWeightChanged(address indexed nodeOwner, uint32 newWeight);
    event NodeValidatorKeyChanged(address indexed nodeOwner, BLS12_381PublicKey newPubKey, BLS12_381Signature newPoP);
    event ValidatorsCommitted(uint32 commit);

    function add(
        address _nodeOwner,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP
    ) external;

    function deactivate(address _nodeOwner) external;

    function activate(address _nodeOwner) external;

    function remove(address _nodeOwner) external;

    function changeValidatorWeight(address _nodeOwner, uint32 _weight) external;

    function changeValidatorKey(
        address _nodeOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external;

    function commitValidatorCommittee() external;

    function getValidatorCommittee() external view returns (CommitteeValidator[] memory);
}
