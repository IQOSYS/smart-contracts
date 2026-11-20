// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Interface for Token Manager Module
/// @notice AMF production model: IQS are non-transferable BSA rights, OST are ordinary shares moved only by controlled modules.
interface ITokenManager {
    enum RegisteredMovementType { Issue, Cancel, Move }
    struct RegisteredMovement {
        address from;
        address to;
        uint256 quantity;
        RegisteredMovementType movementType;
        bytes32 referenceHash;
        uint256 requestedAt;
        uint256 executedAt;
        address requestedBy;
        bool aborted;
    }
    function registeredMovementCount() external view returns (uint256);
    function registeredMovements(uint256 id) external view returns (RegisteredMovement memory);
    function requestRegisteredMovement(address from, address to, uint256 quantity,
        RegisteredMovementType movementType, bytes32 referenceHash) external returns (uint256);
    function getRegisteredMovementActionHash(uint256 id) external view returns (bytes32);
    function registeredMovementReadyAt(uint256 id) external view returns (uint256);
    function executeRegisteredMovement(uint256 id) external;
    function getAbortRegisteredMovementActionHash(uint256 id, bytes32 reasonHash) external view returns (bytes32);
    function abortRegisteredMovement(uint256 id, bytes32 reasonHash) external;

    struct InitialShareRegistration {
        bytes32 allocationsHash;
        bytes32 registerSha256;
        uint256 declaredTotal;
        uint256 holderCount;
        uint256 requestedAt;
        uint256 executedAt;
        address requestedBy;
        bool aborted;
    }

    function INITIAL_SHARE_REGISTRATION_DELAY() external view returns (uint256);
    function initialShareRegistrationLocked() external view returns (bool);
    function pendingInitialShareRegistrationId() external view returns (uint256);
    function initialShareRegistrationCount() external view returns (uint256);
    function initialShareRegistrations(uint256 id) external view returns (InitialShareRegistration memory);
    function getInitialShareRegistrationActionHash(uint256 id) external view returns (bytes32);
    function initialShareRegistrationReadyAt(uint256 id) external view returns (uint256);
    function requestInitialShareRegistration(address[] calldata holders, uint256[] calldata quantities,
        uint256 declaredTotal, bytes32 registerSha256) external returns (uint256);
    function registerInitialShares(uint256 id, address[] calldata holders, uint256[] calldata quantities,
        uint256 declaredTotal, bytes32 registerSha256) external;
    function getAbortInitialShareRegistrationActionHash(uint256 id, bytes32 reasonHash) external view returns (bytes32);
    function abortInitialShareRegistration(uint256 id, bytes32 reasonHash) external;

    // -------------------------------------------------------------------------
    // IQS Token / BSA rights
    // -------------------------------------------------------------------------

    function nameIQS() external pure returns (string memory);
    function symbolIQS() external pure returns (string memory);
    function decimalsIQS() external pure returns (uint8);

    function totalSupplyIQS() external view returns (uint256);
    function balanceOfIQS(address account) external view returns (uint256);

    /// @notice Credits IQS/BSA rights directly to a whitelisted holder.
    function mintIQSTo(
        address account,
        uint256 amount,
        bytes32 referenceHash
    ) external;

    /// @notice Burns IQS when IQS are exercised into OST.
    function burnIQS(
        uint256 amount,
        address account
    ) external;

    // -------------------------------------------------------------------------
    // OST Token / ordinary shares
    // -------------------------------------------------------------------------

    function nameOST() external pure returns (string memory);
    function symbolOST() external pure returns (string memory);

    function totalSupplyOSTf() external view returns (uint256);

    function balanceOfOST(address account) external view returns (uint256);

    /// @notice Mints OST during finalized IQS exercise or controlled treasury award.
    function mintOSTTo(
        address account,
        uint256 amount,
        bytes32 referenceHash
    ) external;

    /// @notice Controlled OST movement, normally called only by OSTTransferModule.
    function transferOSTfromAtoB(
        address from,
        address to,
        uint256 amount
    ) external;

    // -------------------------------------------------------------------------
    // Token operators
    // -------------------------------------------------------------------------

    function setTokenOperator(
        address operator,
        bool status
    ) external;

    function isTokenOperator(
        address operator
    ) external view returns (bool);

    // -------------------------------------------------------------------------
    // Wallet migration controller
    // -------------------------------------------------------------------------

    function walletMigrationController()
        external
        view
        returns (address);

    function setWalletMigrationController(
        address walletMigrationController
    ) external;

    // -------------------------------------------------------------------------
    // Holder registry (149 holders at a given time)
    // -------------------------------------------------------------------------

    function holderRegistry()
        external
        view
        returns (address);

    function setHolderRegistry(
        address holderRegistry
    ) external;

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);

    // -------------------------------------------------------------------------
    // Holders
    // -------------------------------------------------------------------------

    function getIQSHolders()
        external
        view
        returns (
            address[] memory,
            uint256[] memory
        );

    function getOSTHolders()
        external
        view
        returns (
            address[] memory,
            uint256[] memory
        );

    function adminMigrateWallet(
        address oldWallet,
        address newWallet,
        bytes32 referenceHash
    )
        external
        returns (
            uint256 iqsAmount,
            uint256 ostAmount
        );
    function tokenOperatorController()
    external
    view
    returns (address);

    function setTokenOperatorController(
        address tokenOperatorController
    ) external;
}
