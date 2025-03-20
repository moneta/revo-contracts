// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {IConsensusRegistry} from "./interfaces/IConsensusRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title ConsensusRegistry
/// @dev Manages validator nodes and committees for the L2 consensus protocol,
/// owned by Matter Labs Multisig. This contract facilitates
/// the rotation of validator committees, which represent a subset of validator nodes
/// expected to actively participate in the consensus process during a specific time window.
/// @dev Designed for use with a proxy for upgradability.
contract ConsensusRegistry is IConsensusRegistry, Initializable, Ownable2StepUpgradeable {
    /// @dev An array to keep track of validator owners.
    address[] public validatorOwners;
    /// @dev A mapping of validator owners => validators.
    mapping(address => Validator) public validators;
    /// @dev A mapping for enabling efficient lookups when checking whether a given validator public key exists.
    mapping(bytes32 => bool) public validatorPubKeyHashes;
    /// @dev Block number that specifies the last commit to the validator committee.
    uint256 public validatorsCommit;

    modifier onlyOwnerOrValidatorOwner(address _validatorOwner) {
        if (owner() != msg.sender && _validatorOwner != msg.sender) {
            revert UnauthorizedOnlyOwnerOrValidatorOwner();
        }
        _;
    }

    function initialize(address _initialOwner) external initializer {
        if (_initialOwner == address(0)) {
            revert InvalidInputValidatorOwnerAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Adds a new validator to the registry.
    /// @dev Fails if validator owner already exists.
    /// @dev Fails if a validator with the same public key already exists.
    /// @param _validatorOwner The address of the validator's owner.
    /// @param _validatorWeight The voting weight of the validator.
    /// @param _validatorPubKey The BLS12-381 public key of the validator.
    /// @param _validatorPoP The proof-of-possession (PoP) of the validator's public key.
    function add(
        address _validatorOwner,
        uint32 _validatorWeight,
        BLS12_381PublicKey calldata _validatorPubKey,
        BLS12_381Signature calldata _validatorPoP
    ) external onlyOwner {
        // Verify input.
        _verifyInputAddress(_validatorOwner);
        _verifyInputBLS12_381PublicKey(_validatorPubKey);
        _verifyInputBLS12_381Signature(_validatorPoP);

        // Verify storage.
        _verifyValidatorOwnerDoesNotExist(_validatorOwner);
        bytes32 validatorPubKeyHash = _hashValidatorPubKey(_validatorPubKey);
        _verifyValidatorPubKeyDoesNotExist(validatorPubKeyHash);

        uint32 ownerIdx = uint32(validatorOwners.length);
        validatorOwners.push(_validatorOwner);
        validators[_validatorOwner] = Validator({
            latest: ValidatorAttr({
                active: true,
                removed: false,
                weight: _validatorWeight,
                pubKey: _validatorPubKey,
                proofOfPossession: _validatorPoP
            }),
            snapshot: ValidatorAttr({
                active: false,
                removed: false,
                weight: 0,
                pubKey: BLS12_381PublicKey({a: bytes32(0), b: bytes32(0), c: bytes32(0)}),
                proofOfPossession: BLS12_381Signature({a: bytes32(0), b: bytes16(0)})
            }),
            lastUpdateCommit: validatorsCommit,
            ownerIdx: ownerIdx
        });
        validatorPubKeyHashes[validatorPubKeyHash] = true;

        emit ValidatorAdded({
            validatorOwner: _validatorOwner,
            validatorWeight: _validatorWeight,
            validatorPubKey: _validatorPubKey,
            validatorPoP: _validatorPoP
        });
    }

    /// @notice Deactivates a validator, preventing it from participating in committees.
    /// @dev Only callable by the contract owner or the validator owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator to be inactivated.
    function deactivate(address _validatorOwner) external onlyOwnerOrValidatorOwner(_validatorOwner) {
        _verifyValidatorOwnerExists(_validatorOwner);
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        _ensureValidatorSnapshot(validator);
        validator.latest.active = false;

        emit ValidatorDeactivated(_validatorOwner);
    }

    /// @notice Activates a previously inactive validator, allowing it to participate in committees.
    /// @dev Only callable by the contract owner or the validator owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator to be activated.
    function activate(address _validatorOwner) external onlyOwnerOrValidatorOwner(_validatorOwner) {
        _verifyValidatorOwnerExists(_validatorOwner);
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        _ensureValidatorSnapshot(validator);
        validator.latest.active = true;

        emit ValidatorActivated(_validatorOwner);
    }

    /// @notice Removes a validator from the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator to be removed.
    function remove(address _validatorOwner) external onlyOwner {
        _verifyValidatorOwnerExists(_validatorOwner);
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        _ensureValidatorSnapshot(validator);
        validator.latest.removed = true;

        emit ValidatorRemoved(_validatorOwner);
    }

    /// @notice Changes the validator weight of a validator in the registry.
    /// @dev Only callable by the contract owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator whose weight will be changed.
    /// @param _weight The new validator weight to assign to the validator.
    function changeValidatorWeight(address _validatorOwner, uint32 _weight) external onlyOwner {
        _verifyValidatorOwnerExists(_validatorOwner);
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        _ensureValidatorSnapshot(validator);
        validator.latest.weight = _weight;

        emit ValidatorWeightChanged(_validatorOwner, _weight);
    }

    /// @notice Changes the validator's public key and proof-of-possession in the registry.
    /// @dev Only callable by the contract owner or the validator owner.
    /// @dev Verifies that the validator owner exists in the registry.
    /// @param _validatorOwner The address of the owner of the validator whose key and PoP will be changed.
    /// @param _pubKey The new BLS12-381 public key to assign to the validator.
    /// @param _pop The new proof-of-possession (PoP) to assign to the validator.
    function changeValidatorKey(
        address _validatorOwner,
        BLS12_381PublicKey calldata _pubKey,
        BLS12_381Signature calldata _pop
    ) external onlyOwnerOrValidatorOwner(_validatorOwner) {
        _verifyInputBLS12_381PublicKey(_pubKey);
        _verifyInputBLS12_381Signature(_pop);
        _verifyValidatorOwnerExists(_validatorOwner);
        (Validator storage validator, bool deleted) = _getValidatorAndDeleteIfRequired(_validatorOwner);
        if (deleted) {
            return;
        }

        bytes32 prevHash = _hashValidatorPubKey(validator.latest.pubKey);
        delete validatorPubKeyHashes[prevHash];
        bytes32 newHash = _hashValidatorPubKey(_pubKey);
        _verifyValidatorPubKeyDoesNotExist(newHash);
        validatorPubKeyHashes[newHash] = true;
        _ensureValidatorSnapshot(validator);
        validator.latest.pubKey = _pubKey;
        validator.latest.proofOfPossession = _pop;

        emit ValidatorKeyChanged(_validatorOwner, _pubKey, _pop);
    }

    /// @notice Adds a new commit to the validator committee using the current block number.
    /// @dev Implicitly updates the validator committee by affecting readers based on the current state of a validator's attributes:
    /// - If "validatorsCommit" > "validator.lastUpdateCommit", read "validator.latest".
    /// - If "validatorsCommit" == "validator.lastUpdateCommit", read "validator.snapshot".
    /// @dev Only callable by the contract owner.
    function commitValidatorCommittee() external onlyOwner {
        validatorsCommit = block.number;

        emit ValidatorsCommitted(validatorsCommit);
    }

    /// @notice Returns an array of `ValidatorAttr` structs representing the current validator committee.
    /// @dev Collects active and non-removed validators based on the latest commit to the committee.
    function getValidatorCommittee() public view returns (CommitteeValidator[] memory) {
        uint256 len = validatorOwners.length;
        CommitteeValidator[] memory committee = new CommitteeValidator[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; ++i) {
            Validator storage validator = validators[validatorOwners[i]];
            ValidatorAttr memory validatorAttr = validatorsCommit > validator.lastUpdateCommit
                ? validator.latest
                : validator.snapshot;
            if (validatorAttr.active && !validatorAttr.removed) {
                committee[count] = CommitteeValidator({
                    weight: validatorAttr.weight,
                    pubKey: validatorAttr.pubKey,
                    proofOfPossession: validatorAttr.proofOfPossession
                });
                ++count;
            }
        }

        // Resize the array.
        assembly {
            mstore(committee, count)
        }
        return committee;
    }

    function numValidators() public view returns (uint256) {
        return validatorOwners.length;
    }

    function _getValidatorAndDeleteIfRequired(address _validatorOwner) private returns (Validator storage, bool) {
        Validator storage validator = validators[_validatorOwner];
        bool pendingDeletion = _isValidatorPendingDeletion(validator);
        if (pendingDeletion) {
            _deleteValidator(_validatorOwner, validator);
        }
        return (validator, pendingDeletion);
    }

    function _isValidatorPendingDeletion(Validator storage _validator) private view returns (bool) {
        bool validatorRemoved = (validatorsCommit > _validator.lastUpdateCommit)
            ? _validator.latest.removed
            : _validator.snapshot.removed;
        return validatorRemoved;
    }

    function _deleteValidator(address _validatorOwner, Validator storage _validator) private {
        // Delete from array by swapping the last validator owner (gas-efficient, not preserving order).
        address lastValidatorOwner = validatorOwners[validatorOwners.length - 1];
        validatorOwners[_validator.ownerIdx] = lastValidatorOwner;
        validatorOwners.pop();
        // Update the validator owned by the last validator owner.
        validators[lastValidatorOwner].ownerIdx = _validator.ownerIdx;

        // Delete from the remaining mapping.
        delete validatorPubKeyHashes[_hashValidatorPubKey(_validator.latest.pubKey)];
        delete validators[_validatorOwner];

        emit ValidatorDeleted(_validatorOwner);
    }

    function _ensureValidatorSnapshot(Validator storage _validator) private {
        if (_validator.lastUpdateCommit < validatorsCommit) {
            _validator.snapshot = _validator.latest;
            _validator.lastUpdateCommit = validatorsCommit;
        }
    }

    function _isValidatorOwnerExists(address _validatorOwner) private view returns (bool) {
        BLS12_381PublicKey storage pubKey = validators[_validatorOwner].latest.pubKey;
        if (pubKey.a == bytes32(0) && pubKey.b == bytes32(0) && pubKey.c == bytes32(0)) {
            return false;
        }
        return true;
    }

    function _verifyValidatorOwnerExists(address _validatorOwner) private view {
        if (!_isValidatorOwnerExists(_validatorOwner)) {
            revert ValidatorOwnerDoesNotExist();
        }
    }

    function _verifyValidatorOwnerDoesNotExist(address _validatorOwner) private view {
        if (_isValidatorOwnerExists(_validatorOwner)) {
            revert ValidatorOwnerExists();
        }
    }

    function _hashValidatorPubKey(BLS12_381PublicKey storage _pubKey) private view returns (bytes32) {
        return keccak256(abi.encode(_pubKey.a, _pubKey.b, _pubKey.c));
    }

    function _hashValidatorPubKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bytes32) {
        return keccak256(abi.encode(_pubKey.a, _pubKey.b, _pubKey.c));
    }

    function _verifyInputAddress(address _validatorOwner) private pure {
        if (_validatorOwner == address(0)) {
            revert InvalidInputValidatorOwnerAddress();
        }
    }

    function _verifyValidatorPubKeyDoesNotExist(bytes32 _hash) private view {
        if (validatorPubKeyHashes[_hash]) {
            revert ValidatorPubKeyExists();
        }
    }

    function _verifyInputBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure {
        if (_isEmptyBLS12_381PublicKey(_pubKey)) {
            revert InvalidInputBLS12_381PublicKey();
        }
    }

    function _verifyInputBLS12_381Signature(BLS12_381Signature calldata _pop) private pure {
        if (_isEmptyBLS12_381Signature(_pop)) {
            revert InvalidInputBLS12_381Signature();
        }
    }

    function _isEmptyBLS12_381PublicKey(BLS12_381PublicKey calldata _pubKey) private pure returns (bool) {
        return _pubKey.a == bytes32(0) && _pubKey.b == bytes32(0) && _pubKey.c == bytes32(0);
    }

    function _isEmptyBLS12_381Signature(BLS12_381Signature calldata _pop) private pure returns (bool) {
        return _pop.a == bytes32(0) && _pop.b == bytes16(0);
    }
}
