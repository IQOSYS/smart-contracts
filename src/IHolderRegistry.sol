// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Holder Registry Interface
/// @notice Counts the holders at a given time against the 149-holder limit.
interface IHolderRegistry {
    function MAX_HOLDERS() external view returns (uint256);
    function tokenManager() external view returns (address);
    function bsaRegistry() external view returns (address);

    /// @notice Number of holders at the current block timestamp.
    function holderCount() external view returns (uint256);

    /// @notice True while the wallet holds a slot at the current block timestamp.
    function hasHolderSlot(address wallet) external view returns (bool);

    /// @notice 0 = no slot, type(uint64).max = no end date, otherwise the
    ///         timestamp at which the slot frees itself.
    function holderSlotExpiryOf(address wallet) external view returns (uint256);

    /// @notice True when the wallet already holds a slot or one is available.
    function canTakeSlot(address wallet) external view returns (bool);

    /// @notice True when all listed (distinct) wallets can hold a slot at once.
    function canTakeSlots(address[] calldata wallets) external view returns (bool);

    /// @notice Re-derives the wallet's slot from the token, escrow and BSA state.
    function syncHolder(address wallet) external;
}
