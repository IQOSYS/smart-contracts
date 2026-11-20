// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IHolderRegistry.sol";

interface IHolderSlotTokenManager {
    function balanceOfOST(address account) external view returns (uint256);
    function ostEscrowAddress() external view returns (address);
    function retiredHolderWallet(address wallet) external view returns (bool);
}

interface IHolderSlotEscrow {
    function escrowedOSTOf(address seller) external view returns (uint256);
}

interface IHolderSlotBSARegistry {
    function holderSlotExpiryOf(address holder) external view returns (uint256);
}

/// @title Holder Registry
/// @notice Counts holders at a given time. The EU threshold is LESS THAN 150
///         persons, so at most 149 slots can be held at once.
/// @dev A wallet holds a slot while any of these is true:
///        - OST in the wallet;
///        - OST of the wallet in the P2P escrow;
///        - IQS in an exercise in progress;
///        - a BSA that is not expired, cancelled or fully exercised (this also
///          covers IQS credited under that BSA and not yet converted).
///      The first three have no end date. The last one ends at the BSA expiry
///      date: the slot then frees itself with no transaction, because dated
///      slots are indexed by expiry timestamp in a Fenwick tree and the count
///      subtracts everything already expired (<=64 reads, no holder scan).
///
///      syncHolder is permissionless: it stores nothing but what it reads from
///      TokenManager, the escrow module and BSARegistry. Those modules call it
///      whenever one of the inputs changes, and a new slot is refused at 149.
///
///      This is a wallet/ledger guard, NOT proof of how many people received an
///      off-chain offer or of the identity/country/qualification of a person.
contract HolderRegistry is IHolderRegistry {
    uint256 public constant override MAX_HOLDERS = 149;
    uint64 private constant NO_END_DATE = type(uint64).max;

    address public immutable override tokenManager;
    address public immutable override bsaRegistry;

    mapping(address => uint64) private slotExpiry;
    uint256 private openEndedHolders;
    uint256 private datedHolders;
    mapping(uint256 => uint256) private datedHoldersByExpiry;

    event HolderSlotTaken(address indexed wallet, uint256 expiry, uint256 holderCount);
    /// @dev Not emitted when a slot frees itself at expiry: that needs no transaction.
    event HolderSlotReleased(address indexed wallet, uint256 holderCount);

    constructor(address _tokenManager, address _bsaRegistry) {
        require(_tokenManager != address(0), "Invalid token manager");
        require(_bsaRegistry != address(0), "Invalid BSA registry");
        tokenManager = _tokenManager;
        bsaRegistry = _bsaRegistry;
    }

    function holderCount() public view override returns (uint256) {
        uint256 timestamp = block.timestamp;
        if (timestamp >= NO_END_DATE) return openEndedHolders;
        uint256 expired;
        for (uint256 index = timestamp; index != 0; index &= index - 1) {
            expired += datedHoldersByExpiry[index];
        }
        return openEndedHolders + datedHolders - expired;
    }

    function hasHolderSlot(address wallet) public view override returns (bool) {
        return slotExpiry[wallet] > block.timestamp;
    }

    function holderSlotExpiryOf(address wallet) external view override returns (uint256) {
        uint64 expiry = slotExpiry[wallet];
        return expiry > block.timestamp ? expiry : 0;
    }

    function canTakeSlot(address wallet) external view override returns (bool) {
        return hasHolderSlot(wallet) || holderCount() < MAX_HOLDERS;
    }

    function canTakeSlots(address[] calldata wallets) external view override returns (bool) {
        uint256 count = holderCount();
        for (uint256 i = 0; i < wallets.length; i++) {
            if (!hasHolderSlot(wallets[i])) count++;
        }
        return count <= MAX_HOLDERS;
    }

    function syncHolder(address wallet) external override {
        uint64 previous = slotExpiry[wallet];
        uint64 current = _currentExpiry(wallet);
        if (current == previous) return;

        bool held = previous > block.timestamp;
        if (previous == NO_END_DATE) {
            openEndedHolders--;
        } else if (previous != 0) {
            datedHolders--;
            _updateDated(previous, false);
        }

        if (current != 0) {
            if (!held) {
                // A wallet migrated out can never hold a slot again.
                require(
                    !IHolderSlotTokenManager(tokenManager).retiredHolderWallet(wallet),
                    "Retired holder wallet"
                );
                require(holderCount() < MAX_HOLDERS, "Holder cap reached");
            }
            if (current == NO_END_DATE) {
                openEndedHolders++;
            } else {
                datedHolders++;
                _updateDated(current, true);
            }
        }
        slotExpiry[wallet] = current;

        if (current != 0 && !held) emit HolderSlotTaken(wallet, current, holderCount());
        else if (current == 0 && held) emit HolderSlotReleased(wallet, holderCount());
    }

    function _currentExpiry(address wallet) private view returns (uint64) {
        IHolderSlotTokenManager tm = IHolderSlotTokenManager(tokenManager);
        address escrow = tm.ostEscrowAddress();
        // The escrow is a custodian: the seller keeps the slot, not the escrow.
        if (wallet == address(0) || wallet == escrow) return 0;
        if (tm.balanceOfOST(wallet) != 0) return NO_END_DATE;
        if (escrow != address(0) && IHolderSlotEscrow(escrow).escrowedOSTOf(wallet) != 0) return NO_END_DATE;

        uint256 expiry = IHolderSlotBSARegistry(bsaRegistry).holderSlotExpiryOf(wallet);
        if (expiry >= NO_END_DATE) return NO_END_DATE;
        return expiry > block.timestamp ? uint64(expiry) : 0;
    }

    function _updateDated(uint256 expiry, bool increase) private {
        for (uint256 index = expiry; index <= type(uint64).max; index += index & (~index + 1)) {
            if (increase) datedHoldersByExpiry[index] += 1;
            else datedHoldersByExpiry[index] -= 1;
        }
    }
}
