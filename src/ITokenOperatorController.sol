// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenOperatorController {
    struct TokenOperatorChange {
        uint256 id;
        address operator;
        bool status;
        bytes32 referenceHash;
        address executedBy;
        uint256 executedAt;
    }

    function TOKEN_OPERATOR_CHANGE_DELAY() external view returns (uint256);
    function abortedTokenOperatorChanges(bytes32 actionHash) external view returns (bool);
    function executedTokenOperatorChanges(bytes32 actionHash) external view returns (bool);
    function tokenOperatorChangeReadyAt(address operator, bool status, bytes32 referenceHash) external view returns (uint256);
    function getAbortTokenOperatorChangeActionHash(address operator, bool status, bytes32 referenceHash,
        bytes32 reasonHash) external view returns (bytes32);
    function abortTokenOperatorChange(address operator, bool status, bytes32 referenceHash, bytes32 reasonHash) external;

    function getSetTokenOperatorActionHash(
        address operator,
        bool status,
        bytes32 referenceHash
    ) external view returns (bytes32);

    function setTokenOperator(
        address operator,
        bool status,
        bytes32 referenceHash
    ) external returns (uint256);

    function changesf(
        uint256 changeId
    ) external view returns (TokenOperatorChange memory);

    function changeCount()
        external
        view
        returns (uint256);
}