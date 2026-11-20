// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./ITokenManager.sol";
import "./IAccessControl.sol";
import "./IAdminMultisig.sol";
import "./IHolderRegistry.sol";

/// @dev OSTTransferModule exposes immutable escrowAddress() and tokenManager() getters.
///      Verifying both during bootstrap prevents accidentally excluding a real holder.
interface IOSTEscrowModuleBinding {
    function activeTransferCount(address wallet) external view returns (uint256);
    function openTransferCount() external view returns (uint256);
    function escrowAddress() external view returns (address);
    function tokenManager() external view returns (address);
    function paused() external view returns (bool);
}

/// @title Token Manager Module
/// @notice AMF production model: IQS are non-transferable BSA rights; OST are ordinary shares moved only by controlled modules.
contract TokenManager is
    ITokenManager,
    ReentrancyGuard,
    Pausable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    IAccessControl public accessControl;

    // -------------------------------------------------------------------------
    // IQS Token / BSA rights
    // -------------------------------------------------------------------------

    string public constant override nameIQS =
        "IQOSYS Subscription Right";

    string public constant override symbolIQS =
        "IQS";

    uint8 public constant override decimalsIQS =
        0;

    uint256 public override totalSupplyIQS;


    mapping(address => uint256) private _balancesIQS;
    EnumerableSet.AddressSet private tokenHoldersIQS;

    event TransferIQS(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event IQSAwarded(
        address indexed to,
        uint256 amount,
        bytes32 indexed referenceHash,
        uint256 timestamp
    );

    event BurnIQS(
        address indexed from,
        uint256 amount
    );

    // -------------------------------------------------------------------------
    // OST Token / ordinary shares
    // -------------------------------------------------------------------------

    string public constant override nameOST =
        "IQOSYS Ordinary Share Token";

    string public constant override symbolOST =
        "OST";

    uint256 public totalSupplyOST;

    mapping(address => uint256) private _balancesOST;
    EnumerableSet.AddressSet private tokenHoldersOST;

    // M-9: at most 149 holders at a given time, counted by HolderRegistry.
    // TokenManager reports every OST balance change to it; a slot is freed as
    // soon as nothing keeps it. A holder-wallet migration carries the slot.
    address public override holderRegistry;
    mapping(address => bool) public retiredHolderWallet;

    uint256 public constant override INITIAL_SHARE_REGISTRATION_DELAY = 48 hours;
    bool public override initialShareRegistrationLocked;
    uint256 public override pendingInitialShareRegistrationId;
    uint256 public override initialShareRegistrationCount;
    mapping(uint256 => InitialShareRegistration) private _initialShareRegistrations;

    /// @dev Consumers relay this event to the existing all-admin email/SMS alert outbox.
    event InitialShareRegistrationRequested(uint256 indexed id, bytes32 indexed actionHash,
        bytes32 indexed registerSha256, bytes32 allocationsHash, uint256 declaredTotal,
        uint256 holderCount, address requestedBy, uint256 timestamp);
    event InitialSharesRegistered(uint256 indexed id, bytes32 indexed actionHash,
        bytes32 indexed registerSha256, uint256 declaredTotal, uint256 holderCount,
        address executedBy, uint256 timestamp);
    event InitialShareRegistrationAborted(uint256 indexed id, bytes32 indexed actionHash,
        bytes32 indexed reasonHash, address executedBy, uint256 timestamp);

    error InvalidRegisteredMovement();
    error RegisteredMovementNotPending();
    error RegistrationDelayNotElapsed();
    error InvalidInitialShareRegistration();
    error InvalidHolderRegistry();
    error HolderSlotRequired();
    uint256 public override registeredMovementCount;
    mapping(uint256 => RegisteredMovement) private _registeredMovements;
    event RegisteredMovementRequested(uint256 indexed id, bytes32 indexed actionHash,
        bytes32 indexed referenceHash, address from, address to, uint256 quantity,
        RegisteredMovementType movementType, address requestedBy, uint256 timestamp);
    event RegisteredMovementExecuted(uint256 indexed id, bytes32 indexed actionHash,
        bytes32 indexed referenceHash, address from, address to, uint256 quantity,
        RegisteredMovementType movementType, address executedBy, uint256 timestamp);
    event RegisteredMovementAborted(uint256 indexed id, bytes32 indexed actionHash,
        bytes32 indexed reasonHash, address executedBy, uint256 timestamp);

    event HolderRegistryUpdated(address indexed holderRegistry, uint256 timestamp);
    event HolderSlotMigrated(address indexed oldWallet, address indexed newWallet);

    /// @notice The OSTTransferModule holds custody of escrowed OST, not beneficial ownership.
    /// @dev Configured once during deployment, after OSTTransferModule becomes a token operator.
    address public ostEscrowAddress;

    event OSTEscrowAddressConfigured(address indexed escrowAddress);

    event OSTEscrowAddressRotated(
        address indexed oldEscrow,
        address indexed newEscrow,
        uint256 timestamp
    );

    event TransferOST(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event MintOST(
        address indexed to,
        uint256 amount,
        bytes32 indexed referenceHash,
        uint256 timestamp
    );

    // -------------------------------------------------------------------------
    // Controlled token operators
    // -------------------------------------------------------------------------

    mapping(address => bool) private tokenOperators;
    mapping(bytes32 => bool) private usedWalletMigrationReferences;
    address public override walletMigrationController;
    address public override tokenOperatorController;
    event TokenOperatorUpdated(
        address indexed operator,
        bool status
    );

    event TokenManagerPaused(
        address indexed admin,
        uint256 timestamp
    );
    event TokenOperatorControllerUpdated(
        address indexed tokenOperatorController,
        uint256 timestamp
    );
    event TokenManagerUnpaused(
        address indexed admin,
        uint256 timestamp
    );

    event WalletMigrated(
        address indexed oldWallet,
        address indexed newWallet,
        uint256 iqsAmount,
        uint256 ostAmount,
        bytes32 referenceHash
    );
    event WalletMigrationControllerUpdated(
        address indexed walletMigrationController,
        uint256 timestamp
    );
    constructor(
        address _accessControl
    ) {
        require(
            _accessControl != address(0),
            "Invalid access control"
        );

        accessControl =
            IAccessControl(_accessControl);
    }

    modifier onlyAdmin() {
        require(
            accessControl.isAdmin(msg.sender),
            "Caller is not an admin"
        );
        _;
    }

    modifier onlyEmergency() {
        require(accessControl.hasRole(accessControl.ROLE_EMERGENCY(), msg.sender), "Caller is not emergency controller");
        _;
    }

    modifier onlyAdminOrEmergency() {
        require(accessControl.isAdmin(msg.sender) || accessControl.hasRole(accessControl.ROLE_EMERGENCY(), msg.sender), "Caller is not an admin or emergency controller");
        _;
    }
    modifier onlyTokenOperator() {
        require(
            tokenOperators[msg.sender],
            "Caller is not a token operator"
        );
        _;
    }
    modifier onlyTokenOperatorControllerOrBootstrapAdmin() {
        require(
            msg.sender == tokenOperatorController ||
                (
                    tokenOperatorController == address(0) &&
                    accessControl.isAdmin(msg.sender)
                ),
            "Caller is not token operator controller"
        );
        _;
    }
    modifier onlyWalletMigrationController() {
        require(
            msg.sender == walletMigrationController,
            "Caller is not wallet migration controller"
        );
        _;
    }
    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause()
        external
        override
        onlyAdminOrEmergency
    {
        _pause();

        emit TokenManagerPaused(
            msg.sender,
            block.timestamp
        );
    }

    function unpause()
        external
        override
        onlyEmergency
    {
        _unpause();

        emit TokenManagerUnpaused(
            msg.sender,
            block.timestamp
        );
    }

    function paused()
        public
        view
        override(ITokenManager, Pausable)
        returns (bool)
    {
        return super.paused();
    }

    // -------------------------------------------------------------------------
    // Token operator management
    // -------------------------------------------------------------------------

    function setTokenOperator(
        address operator,
        bool status
    )
        external
        override
        onlyTokenOperatorControllerOrBootstrapAdmin
    {
        require(
            operator != address(0),
            "Invalid operator"
        );

        // M-8: never revoke the only permission that can release assets
        // held in a token operator's custody (notably OSTTransferModule).
        // Applies to every operator, including a former escrow module.
        if (!status) {
            require(_balancesOST[operator] == 0, "Operator holds OST");
        }

        tokenOperators[operator] =
            status;

        emit TokenOperatorUpdated(
            operator,
            status
        );
    }

    function isTokenOperator(
        address operator
    )
        external
        view
        override
        returns (bool)
    {
        return tokenOperators[operator];
    }
    function setTokenOperatorController(
        address _tokenOperatorController
    )
        external
        override
        onlyAdmin
    {
        require(
            _tokenOperatorController != address(0),
            "Invalid token operator controller"
        );

        require(
            tokenOperatorController == address(0),
            "Token operator controller already set"
        );

        tokenOperatorController =
            _tokenOperatorController;

        emit TokenOperatorControllerUpdated(
            _tokenOperatorController,
            block.timestamp
        );
    }
    function setWalletMigrationController(
        address _walletMigrationController
    )
        external
        override
        onlyAdmin
    {
        require(
            _walletMigrationController != address(0),
            "Invalid wallet migration controller"
        );

        require(
            walletMigrationController == address(0),
            "Wallet migration controller already set"
        );

        walletMigrationController =
            _walletMigrationController;

        emit WalletMigrationControllerUpdated(
            _walletMigrationController,
            block.timestamp
        );
    }
    /// @dev One-time binding, set at deployment before any token exists.
    function setHolderRegistry(address _holderRegistry) external override onlyAdmin {
        if (
            holderRegistry != address(0) ||
            IHolderRegistry(_holderRegistry).tokenManager() != address(this)
        ) revert InvalidHolderRegistry();
        holderRegistry = _holderRegistry;
        emit HolderRegistryUpdated(_holderRegistry, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Escrow / holder register setup (M-6)
    // -------------------------------------------------------------------------

    /// @notice One-time binding to the exact OSTTransferModule escrow address.
    /// @dev Does not move or burn OST. It excludes the custodial address from
    ///      getOSTHolders(), while balanceOfOST(escrow) remains the source of
    ///      truth for all OST temporarily in escrow.
    function setOSTEscrowAddress(address escrow) external onlyAdmin {
        require(ostEscrowAddress == address(0), "OST escrow already configured");
        require(escrow != address(0), "Invalid OST escrow");
        require(tokenOperators[escrow], "Escrow is not a token operator");
        require(escrow.code.length > 0, "Escrow must be a contract");
        require(
            IOSTEscrowModuleBinding(escrow).escrowAddress() == escrow,
            "Escrow address mismatch"
        );
        require(
            IOSTEscrowModuleBinding(escrow).tokenManager() == address(this),
            "Escrow token manager mismatch"
        );

        ostEscrowAddress = escrow;
        // Also cleans a pre-existing entry if configured after an escrow transfer.
        tokenHoldersOST.remove(escrow);

        emit OSTEscrowAddressConfigured(escrow);
    }

    /// @notice Safely change the custodial escrow after retiring the old module.
    /// @dev Drain old escrow via ordinary settlement / dispute / reclaim first.
    ///      Pause the old module to prevent a deposit race. Neither this
    ///      function nor operator revocation moves or burns any shares.
    function rotateOSTEscrowAddress(address newEscrow) external onlyAdmin {
        address oldEscrow = ostEscrowAddress;
        require(oldEscrow != address(0), "OST escrow not configured");
        require(newEscrow != address(0), "Invalid OST escrow");
        require(newEscrow != oldEscrow, "Escrow unchanged");
        require(_balancesOST[oldEscrow] == 0, "Old escrow not drained");
        require(IOSTEscrowModuleBinding(oldEscrow).openTransferCount() == 0, "Old escrow has open transfers");
        require(
            IOSTEscrowModuleBinding(oldEscrow).paused(),
            "Old escrow must be paused"
        );
        require(_balancesOST[newEscrow] == 0, "New escrow must be empty");
        require(tokenOperators[newEscrow], "Escrow is not a token operator");
        require(newEscrow.code.length > 0, "Escrow must be a contract");
        require(
            IOSTEscrowModuleBinding(newEscrow).escrowAddress() == newEscrow,
            "Escrow address mismatch"
        );
        require(
            IOSTEscrowModuleBinding(newEscrow).tokenManager() == address(this),
            "Escrow token manager mismatch"
        );

        ostEscrowAddress = newEscrow;
        tokenHoldersOST.remove(newEscrow);

        emit OSTEscrowAddressRotated(oldEscrow, newEscrow, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // IQS functions
    // -------------------------------------------------------------------------

    function balanceOfIQS(
        address account
    )
        external
        view
        override
        returns (uint256)
    {
        return _balancesIQS[account];
    }


    /// @notice Credits IQS/BSA rights directly to a whitelisted holder.
    /// @dev Called by BSA/distribution backend or future BSARegistry module.
    function mintIQSTo(
        address account,
        uint256 amount,
        bytes32 referenceHash
    )
        external
        override
        onlyTokenOperator
        whenNotPaused
        nonReentrant
    {
        require(
            account != address(0),
            "Invalid account"
        );

        require(
            amount > 0,
            "Amount must be greater than zero"
        );

        require(
            referenceHash != bytes32(0),
            "Reference hash required"
        );

        accessControl.onlyValidSender(account);

        // IQS exist only under a BSA, and the BSA already holds the slot.
        if (!IHolderRegistry(holderRegistry).hasHolderSlot(account)) revert HolderSlotRequired();

        _balancesIQS[account] +=
            amount;


        totalSupplyIQS +=
            amount;


        _syncIQSHolder(account);

        emit IQSAwarded(
            account,
            amount,
            referenceHash,
            block.timestamp
        );

        emit TransferIQS(
            address(0),
            account,
            amount
        );
    }

    /// @notice Burns IQS from holder during finalized IQS exercise into OST.
    function burnIQS(
        uint256 amount,
        address account
    )
        external
        override
        onlyTokenOperator
        whenNotPaused
        nonReentrant
    {
        require(
            account != address(0),
            "Invalid account"
        );

        require(
            amount > 0,
            "Amount must be greater than zero"
        );

        require(
            _balancesIQS[account] >= amount,
            "Insufficient IQS balance"
        );


        _balancesIQS[account] -=
            amount;


        totalSupplyIQS -=
            amount;


        _syncIQSHolder(account);

        emit BurnIQS(
            account,
            amount
        );

        emit TransferIQS(
            account,
            address(0),
            amount
        );
    }

    // -------------------------------------------------------------------------
    // OST functions
    // -------------------------------------------------------------------------

    function balanceOfOST(
        address account
    )
        external
        view
        override
        returns (uint256)
    {
        return _balancesOST[account];
    }

    function totalSupplyOSTf()
        external
        view
        override
        returns (uint256)
    {
        return totalSupplyOST;
    }

    /// @notice Mints OST, normally when IQS exercise is finalized.
    function mintOSTTo(
        address account,
        uint256 amount,
        bytes32 referenceHash
    )
        external
        override
        onlyTokenOperator
        whenNotPaused
        nonReentrant
    {
        require(pendingInitialShareRegistrationId == 0, "Initial registration pending");
        require(
            account != address(0),
            "Invalid account"
        );

        require(
            amount > 0,
            "Amount must be greater than zero"
        );

        require(
            referenceHash != bytes32(0),
            "Reference hash required"
        );

        accessControl.onlyValidSender(account);
        // An escrow address is a custodian, never a primary-issuance holder.
        require(account != ostEscrowAddress, "Cannot mint OST to escrow");

        _balancesOST[account] +=
            amount;

        totalSupplyOST +=
            amount;

        _syncOSTHolder(account);
        _syncHolderSlot(account);

        emit MintOST(
            account,
            amount,
            referenceHash,
            block.timestamp
        );

        emit TransferOST(
            address(0),
            account,
            amount
        );
    }

    /// @notice Controlled OST transfer. Users cannot call this directly unless they are an authorized token operator/admin.
    function transferOSTfromAtoB(
        address from,
        address to,
        uint256 amount
    )
        external
        override
        onlyTokenOperator
        whenNotPaused
        nonReentrant
    {
        _transferOST(
            from,
            to,
            amount
        );
    }

    function _transferOST(
        address from,
        address to,
        uint256 amount
    )
        internal
    {
        require(
            from != address(0),
            "Invalid from"
        );

        require(
            to != address(0),
            "Invalid to"
        );

        require(
            amount > 0,
            "Amount must be greater than zero"
        );

        require(
            _balancesOST[from] >= amount,
            "Insufficient OST balance"
        );

        // Fail closed: reporting and transferring OST without identifying the
        // custodial escrow would silently pollute the shareholder register.
        require(ostEscrowAddress != address(0), "OST escrow not configured");

        _balancesOST[from] -=
            amount;

        _balancesOST[to] +=
            amount;

        _syncOSTHolder(from);
        _syncOSTHolder(to);

        // Escrow itself takes no holder slot; its seller keeps the slot while
        // their OST is in custody, so reclaim cannot deadlock. The sender is
        // synced first: a holder who sells everything frees the slot the
        // recipient then takes.
        if (from != ostEscrowAddress) {
            _syncHolderSlot(from);
        }
        if (to != ostEscrowAddress) {
            _syncHolderSlot(to);
        }

        emit TransferOST(
            from,
            to,
            amount
        );
    }

    // -------------------------------------------------------------------------
    // Holders
    // -------------------------------------------------------------------------

    function getIQSHolders()
        external
        view
        override
        returns (
            address[] memory,
            uint256[] memory
        )
    {
        uint256 count =
            tokenHoldersIQS.length();

        address[] memory addrs =
            new address[](count);

        uint256[] memory balances =
            new uint256[](count);

        for (
            uint256 i = 0;
            i < count;
            i++
        ) {
            address account =
                tokenHoldersIQS.at(i);

            addrs[i] =
                account;

            balances[i] =
                _balancesIQS[account];
        }

        return (
            addrs,
            balances
        );
    }

    function getOSTHolders()
        external
        view
        override
        returns (
            address[] memory,
            uint256[] memory
        )
    {
        require(ostEscrowAddress != address(0), "OST escrow not configured");

        uint256 count =
            tokenHoldersOST.length();

        address[] memory addrs =
            new address[](count);

        uint256[] memory balances =
            new uint256[](count);

        for (
            uint256 i = 0;
            i < count;
            i++
        ) {
            address account =
                tokenHoldersOST.at(i);

            addrs[i] =
                account;

            balances[i] =
                _balancesOST[account];
        }

        return (
            addrs,
            balances
        );
    }

    // -------------------------------------------------------------------------
    // Wallet migration
    // -------------------------------------------------------------------------

    function adminMigrateWallet(
        address oldWallet,
        address newWallet,
        bytes32 referenceHash
    )
        external
        override
        onlyWalletMigrationController
        whenNotPaused
        nonReentrant
        returns (
            uint256 iqsAmount,
            uint256 ostAmount
        )
    {
        require(
            oldWallet != address(0),
            "Invalid old wallet"
        );

        require(
            newWallet != address(0),
            "Invalid new wallet"
        );

        require(
            oldWallet != newWallet,
            "Wallets must be different"
        );

        require(
            referenceHash != bytes32(0),
            "Invalid reference hash"
        );

        require(
            !usedWalletMigrationReferences[referenceHash],
            "Reference already used"
        );

        require(
            !tokenOperators[oldWallet] && !tokenOperators[newWallet] &&
                oldWallet != ostEscrowAddress && newWallet != ostEscrowAddress,
            "Cannot migrate token operator wallet"
        );

        require(
            oldWallet != accessControl.owner(),
            "Cannot migrate owner wallet"
        );

        require(
            newWallet != accessControl.owner(),
            "New wallet cannot be owner"
        );

        require(
            !accessControl.isAdmin(oldWallet),
            "Cannot migrate admin wallet"
        );

        require(
            !accessControl.isAdmin(newWallet),
            "New wallet cannot be admin"
        );

        require(
            !accessControl.isFrozen(oldWallet),
            "Old wallet is frozen"
        );

        require(
            !accessControl.isFrozen(newWallet),
            "New wallet is frozen"
        );

        require(
            _balancesIQS[newWallet] == 0 &&
                _balancesOST[newWallet] == 0,
            "New wallet already has funds"
        );
        require(!retiredHolderWallet[newWallet], "New wallet was retired");
        require(IHolderRegistry(holderRegistry).hasHolderSlot(oldWallet), "Old wallet has no holder slot");
        require(ostEscrowAddress != address(0), "OST escrow not configured");
        require(
            IOSTEscrowModuleBinding(ostEscrowAddress).activeTransferCount(oldWallet) == 0 &&
            IOSTEscrowModuleBinding(ostEscrowAddress).activeTransferCount(newWallet) == 0,
            "Wallet has open OST transfers"
        );

        iqsAmount =
            _balancesIQS[oldWallet];

        ostAmount =
            _balancesOST[oldWallet];

        retiredHolderWallet[oldWallet] = true;

        usedWalletMigrationReferences[referenceHash] =
            true;

        if (!accessControl.isWhiteListed(newWallet)) {
            accessControl.addToWhiteList(newWallet);
        }

        if (!accessControl.isAuthorized(newWallet)) {
            accessControl.authorizeAddress(newWallet);
        }

        if (iqsAmount > 0) {
            _balancesIQS[oldWallet] =
                0;

            _balancesIQS[newWallet] =
                iqsAmount;


            _syncIQSHolder(oldWallet);
            _syncIQSHolder(newWallet);

            emit TransferIQS(
                oldWallet,
                newWallet,
                iqsAmount
            );
        }

        if (ostAmount > 0) {
            _balancesOST[oldWallet] =
                0;

            _balancesOST[newWallet] =
                ostAmount;

            _syncOSTHolder(oldWallet);
            _syncOSTHolder(newWallet);

            emit TransferOST(
                oldWallet,
                newWallet,
                ostAmount
            );
        }

        // Carry the same holder slot to the replacement wallet: the old wallet
        // is released first, so a holder who lost their key never needs a 150th slot.
        _syncHolderSlot(oldWallet);
        _syncHolderSlot(newWallet);
        emit HolderSlotMigrated(oldWallet, newWallet);

        if (accessControl.isAuthorized(oldWallet)) {
            accessControl.revokeAuthorization(oldWallet);
        }

        if (accessControl.isWhiteListed(oldWallet)) {
            accessControl.removeFromWhiteList(oldWallet);
        }

        if (!accessControl.isFrozen(oldWallet)) {
            accessControl.freezeAddress(oldWallet);
        }

        emit WalletMigrated(
            oldWallet,
            newWallet,
            iqsAmount,
            ostAmount,
            referenceHash
        );
    }

    // -------------------------------------------------------------------------
    // Genesis registration of the complete existing ordinary-share register
    // -------------------------------------------------------------------------

    function initialShareRegistrations(uint256 id) external view override returns (InitialShareRegistration memory) {
        return _initialShareRegistrations[id];
    }

    /// @notice Commit to a complete, sorted register before requesting multisig signatures.
    /// @dev The hash is SHA-256 of the exact signed off-chain extract. Its completeness,
    ///      signature and one verified canonical wallet per holder are checked off-chain.
    function requestInitialShareRegistration(address[] calldata holders, uint256[] calldata quantities,
        uint256 declaredTotal, bytes32 registerSha256)
        external override onlyAdmin whenNotPaused nonReentrant returns (uint256 id)
    {
        require(!initialShareRegistrationLocked, "Initial registration locked");
        require(pendingInitialShareRegistrationId == 0, "Initial registration pending");
        IAdminMultisig multisig = _registrationMultisig();
        require(multisig.isSigner(msg.sender), "Caller is not a signer");
        require(multisig.isActionConsumer(address(this)), "TokenManager consumer not registered");
        _validateInitialShares(holders, quantities, declaredTotal, registerSha256);
        id = ++initialShareRegistrationCount;
        _initialShareRegistrations[id] = InitialShareRegistration({
            allocationsHash: keccak256(abi.encode(holders, quantities)), registerSha256: registerSha256,
            declaredTotal: declaredTotal, holderCount: holders.length, requestedAt: block.timestamp,
            executedAt: 0, requestedBy: msg.sender, aborted: false
        });
        pendingInitialShareRegistrationId = id;
        emit InitialShareRegistrationRequested(id, getInitialShareRegistrationActionHash(id),
            registerSha256, _initialShareRegistrations[id].allocationsHash, declaredTotal,
            holders.length, msg.sender, block.timestamp);
    }

    function getInitialShareRegistrationActionHash(uint256 id) public view override returns (bytes32) {
        InitialShareRegistration storage registration = _initialShareRegistrations[id];
        require(id != 0 && id <= initialShareRegistrationCount, "Initial registration not found");
        return keccak256(abi.encode(address(this), block.chainid, "INITIAL_SHARE_REGISTRATION", id,
            registration.allocationsHash, registration.declaredTotal, registration.registerSha256));
    }

    function initialShareRegistrationReadyAt(uint256 id) external view override returns (uint256) {
        if (initialShareRegistrationLocked || id == 0 || pendingInitialShareRegistrationId != id) return 0;
        return _registrationReadyAt(_registrationMultisig(), getInitialShareRegistrationActionHash(id),
            _initialShareRegistrations[id].requestedAt);
    }

    /// @notice Issue the entire approved existing register atomically and permanently close genesis.
    function registerInitialShares(uint256 id, address[] calldata holders, uint256[] calldata quantities,
        uint256 declaredTotal, bytes32 registerSha256) external override onlyAdmin whenNotPaused nonReentrant
    {
        require(!initialShareRegistrationLocked, "Initial registration locked");
        require(id != 0 && pendingInitialShareRegistrationId == id, "Initial registration not pending");
        InitialShareRegistration storage registration = _initialShareRegistrations[id];
        require(registration.allocationsHash == keccak256(abi.encode(holders, quantities))
            && registration.declaredTotal == declaredTotal && registration.registerSha256 == registerSha256,
            "Initial registration data mismatch");
        _validateInitialShares(holders, quantities, declaredTotal, registerSha256);
        bytes32 actionHash = getInitialShareRegistrationActionHash(id);
        _consumeRegistrationAction(actionHash, registration.requestedAt);

        initialShareRegistrationLocked = true;
        pendingInitialShareRegistrationId = 0;
        registration.executedAt = block.timestamp;
        totalSupplyOST = declaredTotal;
        for (uint256 i; i < holders.length; i++) {
            address holder = holders[i];
            _balancesOST[holder] += quantities[i];
            _syncOSTHolder(holder);
            _syncHolderSlot(holder);
            emit MintOST(holder, quantities[i], registerSha256, block.timestamp);
            emit TransferOST(address(0), holder, quantities[i]);
        }
        emit InitialSharesRegistered(id, actionHash, registerSha256, declaredTotal, holders.length, msg.sender, block.timestamp);
    }

    function getAbortInitialShareRegistrationActionHash(uint256 id, bytes32 reasonHash)
        public view override returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, "ABORT_INITIAL_SHARE_REGISTRATION",
            getInitialShareRegistrationActionHash(id), reasonHash));
    }

    /// @notice A separate quorum can abort at any time before execution, including while paused.
    /// A retry uses a fresh attempt ID and new approvals, even for the same signed extract.
    function abortInitialShareRegistration(uint256 id, bytes32 reasonHash) external override onlyAdmin nonReentrant {
        require(!initialShareRegistrationLocked, "Initial registration locked");
        require(id != 0 && pendingInitialShareRegistrationId == id, "Initial registration not pending");
        require(reasonHash != bytes32(0), "Reason hash required");
        IAdminMultisig multisig = _registrationMultisig();
        bytes32 actionHash = getAbortInitialShareRegistrationActionHash(id, reasonHash);
        _requireRegistrationIntent(multisig, actionHash);
        multisig.consumeApprovedActionWithRequiredSignatures(actionHash, multisig.requiredSignatures());
        _initialShareRegistrations[id].aborted = true;
        pendingInitialShareRegistrationId = 0;
        emit InitialShareRegistrationAborted(id, getInitialShareRegistrationActionHash(id), reasonHash, msg.sender, block.timestamp);
    }

    function _registrationMultisig() private view returns (IAdminMultisig multisig) {
        address controller = accessControl.adminSignerController();
        require(controller != address(0), "Admin multisig not configured");
        multisig = IAdminMultisig(controller);
        require(multisig.signerCount() == 3 && multisig.requiredSignatures() >= 2, "Initial registration requires 2-of-3");
    }

    function _registrationReadyAt(IAdminMultisig multisig, bytes32 actionHash, uint256 requestedAt)
        private view returns (uint256)
    {
        uint256 quorumAt = multisig.getActionQuorumReachedAt(actionHash, multisig.requiredSignatures());
        if (quorumAt != 0 && quorumAt < requestedAt) quorumAt = requestedAt;
        return quorumAt == 0 ? 0 : quorumAt + INITIAL_SHARE_REGISTRATION_DELAY;
    }

    function _consumeRegistrationAction(bytes32 actionHash, uint256 requestedAt) private {
        IAdminMultisig multisig = _registrationMultisig();
        uint256 readyAt = _registrationReadyAt(multisig, actionHash, requestedAt);
        require(readyAt != 0, "Action not approved");
        if (block.timestamp < readyAt) revert RegistrationDelayNotElapsed();
        _requireRegistrationIntent(multisig, actionHash);
        multisig.consumeApprovedActionWithRequiredSignatures(actionHash, multisig.requiredSignatures());
    }

    function _requireRegistrationIntent(IAdminMultisig multisig, bytes32 actionHash) private view {
        (bool exists,, address consumer, bytes4 selector, bytes32 calldataHash,,,) = multisig.getActionProposal(actionHash);
        require(exists && consumer == address(this) && selector == msg.sig && calldataHash == keccak256(msg.data),
            "Initial registration intent mismatch");
    }

    function _validateInitialShares(address[] calldata holders, uint256[] calldata quantities,
        uint256 declaredTotal, bytes32 registerSha256) private view
    {
        require(totalSupplyOST == 0, "Initial registration requires zero OST supply");
        require(ostEscrowAddress != address(0), "OST escrow not configured");
        if (!(registerSha256 != bytes32(0))) revert InvalidInitialShareRegistration();
        if (!(declaredTotal != 0)) revert InvalidInitialShareRegistration();
        if (!(holders.length != 0)) revert InvalidInitialShareRegistration();
        if (!(holders.length == quantities.length)) revert InvalidInitialShareRegistration();
        uint256 total;
        address previous;
        for (uint256 i; i < holders.length; i++) {
            address holder = holders[i];
            if (!(holder > previous)) revert InvalidInitialShareRegistration();
            if (!(holder != ostEscrowAddress && !retiredHolderWallet[holder])) revert InvalidInitialShareRegistration();
            if (!(quantities[i] != 0)) revert InvalidInitialShareRegistration();
            accessControl.onlyValidSender(holder);
            total += quantities[i];
            previous = holder;
        }
        if (!(total == declaredTotal)) revert InvalidInitialShareRegistration();
        require(IHolderRegistry(holderRegistry).canTakeSlots(holders), "Holder cap reached");
    }

    // Registered legal movements use the same quorum and exact-intent checks as genesis.
    // Evidence validity and the underlying legal decision remain off-chain.
    function registeredMovements(uint256 id) external view override returns (RegisteredMovement memory) {
        return _registeredMovements[id];
    }

    function requestRegisteredMovement(address from, address to, uint256 quantity,
        RegisteredMovementType movementType, bytes32 referenceHash)
        external override onlyAdmin whenNotPaused nonReentrant returns (uint256 id)
    {
        IAdminMultisig multisig = _registrationMultisig();
        require(multisig.isSigner(msg.sender), "Caller is not a signer");
        require(multisig.isActionConsumer(address(this)), "TokenManager consumer not registered");
        _validateRegisteredMovement(from, to, quantity, movementType, referenceHash);
        id = ++registeredMovementCount;
        _registeredMovements[id] = RegisteredMovement(from, to, quantity, movementType,
            referenceHash, block.timestamp, 0, msg.sender, false);
        emit RegisteredMovementRequested(id, getRegisteredMovementActionHash(id), referenceHash,
            from, to, quantity, movementType, msg.sender, block.timestamp);
    }

    function getRegisteredMovementActionHash(uint256 id) public view override returns (bytes32) {
        if (!(id != 0 && id <= registeredMovementCount)) revert InvalidRegisteredMovement();
        RegisteredMovement storage movement = _registeredMovements[id];
        return keccak256(abi.encode(address(this), block.chainid, "REGISTERED_MOVEMENT", id,
            movement.from, movement.to, movement.quantity, movement.movementType, movement.referenceHash));
    }

    function registeredMovementReadyAt(uint256 id) external view override returns (uint256) {
        RegisteredMovement storage movement = _registeredMovements[id];
        if (id == 0 || id > registeredMovementCount || movement.aborted || movement.executedAt != 0) return 0;
        return _registrationReadyAt(_registrationMultisig(), getRegisteredMovementActionHash(id), movement.requestedAt);
    }

    function executeRegisteredMovement(uint256 id) external override onlyAdmin whenNotPaused nonReentrant {
        bytes32 actionHash = getRegisteredMovementActionHash(id);
        RegisteredMovement storage movement = _registeredMovements[id];
        if (!(!movement.aborted && movement.executedAt == 0)) revert RegisteredMovementNotPending();
        _validateRegisteredMovement(movement.from, movement.to, movement.quantity, movement.movementType, movement.referenceHash);
        _consumeRegistrationAction(actionHash, movement.requestedAt);
        movement.executedAt = block.timestamp;
        if (movement.movementType == RegisteredMovementType.Issue) {
            totalSupplyOST += movement.quantity;
            emit MintOST(movement.to, movement.quantity, movement.referenceHash, block.timestamp);
        } else {
            _balancesOST[movement.from] -= movement.quantity;
            _syncOSTHolder(movement.from);
            _syncHolderSlot(movement.from);
        }
        if (movement.movementType == RegisteredMovementType.Cancel) {
            totalSupplyOST -= movement.quantity;
        } else {
            _balancesOST[movement.to] += movement.quantity;
            _syncOSTHolder(movement.to);
            _syncHolderSlot(movement.to);
        }
        emit TransferOST(movement.from, movement.to, movement.quantity);
        emit RegisteredMovementExecuted(id, actionHash, movement.referenceHash, movement.from,
            movement.to, movement.quantity, movement.movementType, msg.sender, block.timestamp);
    }

    function getAbortRegisteredMovementActionHash(uint256 id, bytes32 reasonHash)
        public view override returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, "ABORT_REGISTERED_MOVEMENT",
            getRegisteredMovementActionHash(id), reasonHash));
    }

    function abortRegisteredMovement(uint256 id, bytes32 reasonHash) external override onlyAdmin nonReentrant {
        bytes32 actionHash = getAbortRegisteredMovementActionHash(id, reasonHash);
        RegisteredMovement storage movement = _registeredMovements[id];
        if (!(!movement.aborted && movement.executedAt == 0)) revert RegisteredMovementNotPending();
        require(reasonHash != bytes32(0), "Reason hash required");
        IAdminMultisig multisig = _registrationMultisig();
        _requireRegistrationIntent(multisig, actionHash);
        multisig.consumeApprovedActionWithRequiredSignatures(actionHash, multisig.requiredSignatures());
        movement.aborted = true;
        emit RegisteredMovementAborted(id, getRegisteredMovementActionHash(id), reasonHash, msg.sender, block.timestamp);
    }

    function _validateRegisteredMovement(address from, address to, uint256 quantity,
        RegisteredMovementType movementType, bytes32 referenceHash) private view
    {
        require(pendingInitialShareRegistrationId == 0, "Initial registration pending");
        require(ostEscrowAddress != address(0), "OST escrow not configured");
        if (!(quantity != 0)) revert InvalidRegisteredMovement();
        require(referenceHash != bytes32(0), "Reference hash required");
        if (movementType == RegisteredMovementType.Issue) {
            if (!(from == address(0))) revert InvalidRegisteredMovement();
        } else {
            if (!(from != address(0) && from != ostEscrowAddress && !retiredHolderWallet[from])) revert InvalidRegisteredMovement();
            require(_balancesOST[from] >= quantity, "Insufficient OST balance");
        }
        if (movementType == RegisteredMovementType.Cancel) {
            if (!(to == address(0))) revert InvalidRegisteredMovement();
        } else {
            if (!(to != address(0) && to != from && to != ostEscrowAddress && !retiredHolderWallet[to])) revert InvalidRegisteredMovement();
            accessControl.onlyValidSender(to);
            // A Move of the sender's whole balance may free the slot the recipient
            // takes; execution releases the sender first and enforces the cap.
            require(
                IHolderRegistry(holderRegistry).canTakeSlot(to) ||
                    (movementType == RegisteredMovementType.Move && _balancesOST[from] == quantity),
                "Holder cap reached"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Called after a balance change. Reverts with "Holder cap reached"
    ///      when the wallet would become the 150th holder, and with "Retired
    ///      holder wallet" when a migrated-out wallet would take a slot again.
    function _syncHolderSlot(address account) internal {
        IHolderRegistry(holderRegistry).syncHolder(account);
    }

    function _syncIQSHolder(
        address account
    )
        internal
    {
        if (_balancesIQS[account] > 0) {
            tokenHoldersIQS.add(account);
        } else {
            tokenHoldersIQS.remove(account);
        }
    }

    function _syncOSTHolder(
        address account
    )
        internal
    {
        // Escrow is a custodial system account, never a registered shareholder.
        // Its actual token balance is intentionally retained in _balancesOST.
        if (account == ostEscrowAddress) {
            tokenHoldersOST.remove(account);
        } else if (_balancesOST[account] > 0) {
            tokenHoldersOST.add(account);
        } else {
            tokenHoldersOST.remove(account);
        }
    }
}
