// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ITokenOperatorController.sol";
import "./IAccessControl.sol";
import "./IAdminMultisig.sol";

interface IControlledTokenManager {
    function setTokenOperator(
        address operator,
        bool status
    ) external;
}

/// @title Token Operator Controller
/// @notice Multisig-controlled controller for adding/removing token operator modules.
/// @dev Prevents a single admin from granting themselves token operator rights.
contract TokenOperatorController is ITokenOperatorController {
    IAccessControl public accessControl;
    IAdminMultisig public adminMultisig;
    IControlledTokenManager public tokenManager;

    uint256 public constant override TOKEN_OPERATOR_CHANGE_DELAY = 48 hours;
    mapping(bytes32 => bool) public override abortedTokenOperatorChanges;
    mapping(bytes32 => bool) public override executedTokenOperatorChanges;
    event TokenOperatorChangeAborted(bytes32 indexed actionHash, bytes32 indexed reasonHash,
        address indexed executedBy, uint256 timestamp);

    uint256 private nextChangeId;

    mapping(uint256 => TokenOperatorChange) private changes;

    event TokenOperatorChangeExecuted(
        uint256 indexed changeId,
        address indexed operator,
        bool status,
        bytes32 indexed referenceHash,
        address executedBy,
        uint256 timestamp
    );

    constructor(
        address _accessControl,
        address _adminMultisig,
        address _tokenManager
    ) {
        require(_accessControl != address(0), "Invalid access control");
        require(_adminMultisig != address(0), "Invalid admin multisig");
        require(_tokenManager != address(0), "Invalid token manager");

        accessControl = IAccessControl(_accessControl);
        adminMultisig = IAdminMultisig(_adminMultisig);
        tokenManager = IControlledTokenManager(_tokenManager);
    }

    modifier onlyAdmin() {
        require(
            accessControl.isAdmin(msg.sender),
            "Caller is not an admin"
        );
        _;
    }

    function getSetTokenOperatorActionHash(
        address operator,
        bool status,
        bytes32 referenceHash
    )
        public
        view
        override
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                "SET_TOKEN_OPERATOR",
                operator,
                status,
                referenceHash
            )
        );
    }

    function setTokenOperator(
        address operator,
        bool status,
        bytes32 referenceHash
    )
        external
        override
        onlyAdmin
        returns (uint256)
    {
        require(operator != address(0), "Invalid operator");
        require(referenceHash != bytes32(0), "Reference hash required");

        bytes32 actionHash =
            getSetTokenOperatorActionHash(
                operator,
                status,
                referenceHash
            );

        require(!abortedTokenOperatorChanges[actionHash], "Token operator change aborted");
        require(!executedTokenOperatorChanges[actionHash], "Token operator change already executed");
        uint256 threshold = _changeThreshold();
        uint256 quorumAt = adminMultisig.getActionQuorumReachedAt(actionHash, threshold);
        require(quorumAt != 0, "Action not approved");
        require(block.timestamp >= quorumAt + TOKEN_OPERATOR_CHANGE_DELAY, "Token operator delay not elapsed");
        adminMultisig.consumeApprovedActionWithRequiredSignatures(actionHash, threshold);
        executedTokenOperatorChanges[actionHash] = true;

        tokenManager.setTokenOperator(
            operator,
            status
        );

        uint256 changeId =
            nextChangeId++;

        changes[changeId] =
            TokenOperatorChange({
                id: changeId,
                operator: operator,
                status: status,
                referenceHash: referenceHash,
                executedBy: msg.sender,
                executedAt: block.timestamp
            });

        emit TokenOperatorChangeExecuted(
            changeId,
            operator,
            status,
            referenceHash,
            msg.sender,
            block.timestamp
        );

        return changeId;
    }

    function tokenOperatorChangeReadyAt(address operator, bool status, bytes32 referenceHash)
        external view override returns (uint256)
    {
        bytes32 hash = getSetTokenOperatorActionHash(operator, status, referenceHash);
        if (abortedTokenOperatorChanges[hash] || executedTokenOperatorChanges[hash]) return 0;
        uint256 quorumAt = adminMultisig.getActionQuorumReachedAt(hash, _changeThreshold());
        return quorumAt == 0 ? 0 : quorumAt + TOKEN_OPERATOR_CHANGE_DELAY;
    }

    function getAbortTokenOperatorChangeActionHash(address operator, bool status, bytes32 referenceHash, bytes32 reasonHash)
        public view override returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, "ABORT_SET_TOKEN_OPERATOR",
            getSetTokenOperatorActionHash(operator, status, referenceHash), reasonHash));
    }

    /// @notice A quorum can abort before execution without waiting 48 hours.
    /// Retrying an aborted or executed change requires a fresh reference and approvals.
    function abortTokenOperatorChange(address operator, bool status, bytes32 referenceHash, bytes32 reasonHash)
        external override onlyAdmin
    {
        require(operator != address(0), "Invalid operator");
        require(referenceHash != bytes32(0) && reasonHash != bytes32(0), "Reference and reason required");
        bytes32 hash = getSetTokenOperatorActionHash(operator, status, referenceHash);
        require(!abortedTokenOperatorChanges[hash], "Token operator change aborted");
        require(!executedTokenOperatorChanges[hash], "Token operator change already executed");
        adminMultisig.consumeApprovedActionWithRequiredSignatures(
            getAbortTokenOperatorChangeActionHash(operator, status, referenceHash, reasonHash), _changeThreshold());
        abortedTokenOperatorChanges[hash] = true;
        emit TokenOperatorChangeAborted(hash, reasonHash, msg.sender, block.timestamp);
    }

    function _changeThreshold() private view returns (uint256) {
        uint256 configured = adminMultisig.requiredSignatures();
        return configured < 2 ? 2 : configured;
    }

    function changesf(
        uint256 changeId
    )
        external
        view
        override
        returns (TokenOperatorChange memory)
    {
        return changes[changeId];
    }

    function changeCount()
        external
        view
        override
        returns (uint256)
    {
        return nextChangeId;
    }
}