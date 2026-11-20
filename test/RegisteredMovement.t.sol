// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AccessControl.sol";
import "../src/AdminMultisig.sol";
import "../src/TokenManager.sol";
import "../src/OSTTransferModule.sol";
import "../src/TokenOperatorController.sol";
import "../src/BSARegistry.sol";
import "../src/HolderRegistry.sol";

abstract contract MovementFixture is Test {
    AccessControl ac;
    AdminMultisig ms;
    TokenManager tm;
    OSTTransferModule escrow;
    HolderRegistry slots;
    TokenOperatorController operators;
    address owner = address(0xA0);
    address first = address(0xA1);
    address second = address(0xA2);
    address third = address(0xA3);
    address alice = address(0x1001);
    address bob = address(0x1002);
    bytes32 constant REF = keccak256("signed source document");
    bytes32 constant REASON = keccak256("abort evidence");
    ITokenManager.RegisteredMovementType constant ISSUE = ITokenManager.RegisteredMovementType.Issue;
    ITokenManager.RegisteredMovementType constant CANCEL = ITokenManager.RegisteredMovementType.Cancel;
    ITokenManager.RegisteredMovementType constant MOVE = ITokenManager.RegisteredMovementType.Move;

    function setUp() public {
        vm.warp(100);
        vm.startPrank(owner);
        ac = new AccessControl(owner);
        ac.addAdmin(first); ac.addAdmin(second); ac.addAdmin(third);
        address[] memory signers = new address[](3);
        signers[0] = first; signers[1] = second; signers[2] = third;
        ms = new AdminMultisig(address(ac), signers, 2);
        ac.setAdminSignerController(address(ms));
        tm = new TokenManager(address(ac));
        escrow = new OSTTransferModule(address(ac), address(tm), address(ms));
        slots = new HolderRegistry(address(tm), address(new BSARegistry(address(ac), address(tm), address(ms))));
        tm.setHolderRegistry(address(slots));
        tm.setTokenOperator(address(escrow), true);
        tm.setTokenOperator(owner, true);
        tm.setOSTEscrowAddress(address(escrow));
        operators = new TokenOperatorController(address(ac), address(ms), address(tm));
        tm.setTokenOperatorController(address(operators));
        ms.setActionConsumer(address(tm), true);
        ms.setActionConsumer(address(operators), true);
        ac.setRole(ac.ROLE_ACCOUNT_MANAGER(), address(tm), true);
        ac.setRole(ac.ROLE_EMERGENCY(), owner, true);
        ac.approveHolder(alice); ac.approveHolder(bob);
        vm.stopPrank();
    }

    function _request(address from, address to, uint256 amount, ITokenManager.RegisteredMovementType kind)
        internal returns (uint256 id)
    {
        vm.prank(first); return tm.requestRegisteredMovement(from, to, amount, kind, REF);
    }
    function _propose(bytes32 hash, address consumer, bytes memory data) internal {
        bytes4 selector;
        assembly { selector := mload(add(data, 32)) }
        vm.prank(first); ms.proposeAction(hash, consumer, selector, keccak256(data), "Opaque legal evidence", block.timestamp + 7 days);
    }
    function _approve(bytes32 hash, address consumer, address signer) internal {
        vm.prank(signer); ms.approveActionForConsumer(hash, consumer);
    }
    function _quorum(bytes32 hash, address consumer, bytes memory data) internal {
        _propose(hash, consumer, data);
        _approve(hash, consumer, first); _approve(hash, consumer, second);
    }
    function _approveMovement(uint256 id) internal returns (bytes32 hash) {
        hash = tm.getRegisteredMovementActionHash(id);
        _quorum(hash, address(tm), abi.encodeCall(tm.executeRegisteredMovement, (id)));
    }
    function _execute(uint256 id) internal { vm.prank(owner); tm.executeRegisteredMovement(id); }
    function _readyExecute(uint256 id) internal {
        _approveMovement(id); vm.warp(tm.registeredMovementReadyAt(id)); _execute(id);
    }
    function _seed(uint256 amount) internal {
        vm.prank(owner); tm.mintOSTTo(alice, amount, REF);
    }
    function _unconsumed(bytes32 hash) internal view {
        (, bool consumed,) = ms.getApprovalState(hash); assertFalse(consumed);
    }
    function _abort(uint256 id) internal {
        bytes32 hash = tm.getAbortRegisteredMovementActionHash(id, REASON);
        _quorum(hash, address(tm), abi.encodeCall(tm.abortRegisteredMovement, (id, REASON)));
        vm.prank(owner); tm.abortRegisteredMovement(id, REASON);
    }
    function _fillSlots() internal {
        vm.startPrank(owner);
        for (uint256 i; i < 148; i++) {
            address wallet = address(uint160(0x2000 + i)); ac.approveHolder(wallet); tm.mintOSTTo(wallet, 1, REF);
        }
        vm.stopPrank();
    }

}

contract RegisteredMovementTest is MovementFixture {
    function testIssueFromZeroSupplyAndRepeatedIssueRemainAvailable() public {
        uint256 id = _request(address(0), alice, 40, ISSUE);
        assertEq(tm.balanceOfOST(alice), 0);
        _readyExecute(id);
        _readyExecute(_request(address(0), bob, 60, ISSUE));
        assertEq(tm.totalSupplyOSTf(), 100); assertEq(tm.balanceOfOST(alice), 40); assertEq(tm.balanceOfOST(bob), 60);
        assertEq(slots.holderCount(), 2); assertEq(tm.registeredMovementCount(), 2);
        assertFalse(tm.initialShareRegistrationLocked());
    }
    function testIssueAfterLockedGenesis() public {
        address[] memory holders = new address[](1); holders[0] = alice;
        uint256[] memory amounts = new uint256[](1); amounts[0] = 100;
        vm.prank(first); uint256 id = tm.requestInitialShareRegistration(holders, amounts, 100, REF);
        _quorum(tm.getInitialShareRegistrationActionHash(id), address(tm),
            abi.encodeCall(tm.registerInitialShares, (id, holders, amounts, 100, REF)));
        vm.warp(tm.initialShareRegistrationReadyAt(id));
        vm.prank(owner); tm.registerInitialShares(id, holders, amounts, 100, REF);
        _readyExecute(_request(address(0), bob, 50, ISSUE));
        assertEq(tm.totalSupplyOSTf(), 150); assertTrue(tm.initialShareRegistrationLocked());
    }
    function testCancelAllFreesHolderSlotThenIssueAgain() public {
        _seed(100); assertEq(slots.holderCount(), 1);
        _readyExecute(_request(alice, address(0), 100, CANCEL));
        assertEq(tm.totalSupplyOSTf(), 0); assertEq(tm.balanceOfOST(alice), 0);
        assertEq(slots.holderCount(), 0); assertFalse(slots.hasHolderSlot(alice));
        (address[] memory registered,) = tm.getOSTHolders(); assertEq(registered.length, 0);
        _readyExecute(_request(address(0), bob, 50, ISSUE)); assertEq(tm.totalSupplyOSTf(), 50);
        assertEq(slots.holderCount(), 1); assertTrue(slots.hasHolderSlot(bob));
    }
    function testMoveChangesBalancesAndRegisterWithoutChangingSupply() public {
        _seed(100); _readyExecute(_request(alice, bob, 100, MOVE));
        assertEq(tm.totalSupplyOSTf(), 100); assertEq(tm.balanceOfOST(alice), 0); assertEq(tm.balanceOfOST(bob), 100);
        (address[] memory registered, uint256[] memory balances) = tm.getOSTHolders();
        assertEq(registered.length, 1); assertEq(registered[0], bob); assertEq(balances[0], 100);
        assertFalse(slots.hasHolderSlot(alice)); assertTrue(slots.hasHolderSlot(bob));
        assertEq(slots.holderCount(), 1);
    }
    function testRequestEmitsInitiationAndExactParametersWithoutMutatingSupply() public {
        vm.recordLogs(); uint256 id = _request(address(0), alice, 40, ISSUE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); assertEq(logs[0].emitter, address(tm));
        assertEq(logs[0].topics[0], keccak256("RegisteredMovementRequested(uint256,bytes32,bytes32,address,address,uint256,uint8,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(id)); assertEq(logs[0].topics[2], tm.getRegisteredMovementActionHash(id));
        assertEq(logs[0].topics[3], REF); assertEq(tm.totalSupplyOSTf(), 0); assertEq(slots.holderCount(), 0);
        ITokenManager.RegisteredMovement memory m = tm.registeredMovements(id);
        assertEq(m.to, alice); assertEq(m.quantity, 40); assertEq(m.requestedBy, first);
    }
    function testDelayStartsAtSecondSignatureAndBoundaryIsExact() public {
        uint256 id = _request(address(0), alice, 40, ISSUE); bytes32 hash = tm.getRegisteredMovementActionHash(id);
        _propose(hash, address(tm), abi.encodeCall(tm.executeRegisteredMovement, (id)));
        _approve(hash, address(tm), first); vm.warp(block.timestamp + 1 days);
        assertEq(tm.registeredMovementReadyAt(id), 0);
        vm.expectRevert("Action not approved"); _execute(id);
        _approve(hash, address(tm), second); uint256 ready = tm.registeredMovementReadyAt(id);
        assertEq(ready, block.timestamp + 48 hours);
        vm.warp(ready - 1); vm.expectRevert(TokenManager.RegistrationDelayNotElapsed.selector); _execute(id); _unconsumed(hash);
        vm.warp(ready); _execute(id); assertEq(tm.registeredMovements(id).executedAt, ready);
        assertEq(tm.registeredMovementReadyAt(id), 0);
        vm.expectRevert(TokenManager.RegisteredMovementNotPending.selector); _execute(id);
    }
    function testWrongExecutionIntentAndCrossAttemptApprovalAreRejected() public {
        uint256 id = _request(address(0), alice, 40, ISSUE);
        uint256 other = _request(address(0), bob, 60, ISSUE);
        bytes32 hash = tm.getRegisteredMovementActionHash(id);
        assertTrue(hash != tm.getRegisteredMovementActionHash(other));
        _quorum(hash, address(tm), abi.encodeCall(tm.executeRegisteredMovement, (other)));
        vm.warp(tm.registeredMovementReadyAt(id));
        vm.expectRevert("Initial registration intent mismatch"); _execute(id); _unconsumed(hash);
        vm.expectRevert("Action not approved"); _execute(other);
    }
    function testAbortRequiresIndependentQuorumAndWorksWhilePaused() public {
        uint256 id = _request(address(0), alice, 40, ISSUE); bytes32 original = _approveMovement(id);
        bytes32 hash = tm.getAbortRegisteredMovementActionHash(id, REASON);
        _propose(hash, address(tm), abi.encodeCall(tm.abortRegisteredMovement, (id, REASON)));
        _approve(hash, address(tm), first);
        vm.prank(owner); vm.expectRevert("Action not approved"); tm.abortRegisteredMovement(id, REASON);
        _approve(hash, address(tm), second);
        vm.prank(owner); tm.pause();
        vm.prank(owner); tm.abortRegisteredMovement(id, REASON);
        assertTrue(tm.registeredMovements(id).aborted); assertEq(tm.registeredMovementReadyAt(id), 0);
        vm.prank(owner); tm.unpause(); vm.warp(block.timestamp + 3 days);
        vm.expectRevert(TokenManager.RegisteredMovementNotPending.selector); _execute(id); _unconsumed(original);
        uint256 retry = _request(address(0), alice, 40, ISSUE);
        assertTrue(tm.getRegisteredMovementActionHash(retry) != original); _readyExecute(retry);
    }
    function testAbortReasonBindingAndExecutedActionCannotAbort() public {
        uint256 id = _request(address(0), alice, 40, ISSUE);
        bytes32 hash = tm.getAbortRegisteredMovementActionHash(id, REASON);
        _quorum(hash, address(tm), abi.encodeCall(tm.abortRegisteredMovement, (id, REF)));
        vm.prank(owner); vm.expectRevert("Initial registration intent mismatch"); tm.abortRegisteredMovement(id, REASON);
        _readyExecute(id);
        vm.prank(owner); vm.expectRevert(TokenManager.RegisteredMovementNotPending.selector); tm.abortRegisteredMovement(id, REASON);
    }
    function testRequestAndExecuteRequireAdminAndRequestAlsoSigner() public {
        vm.prank(alice); vm.expectRevert("Caller is not an admin"); tm.requestRegisteredMovement(address(0), alice, 1, ISSUE, REF);
        vm.prank(owner); vm.expectRevert("Caller is not a signer"); tm.requestRegisteredMovement(address(0), alice, 1, ISSUE, REF);
        uint256 id = _request(address(0), alice, 40, ISSUE); _approveMovement(id); vm.warp(tm.registeredMovementReadyAt(id));
        vm.prank(alice); vm.expectRevert("Caller is not an admin"); tm.executeRegisteredMovement(id);
        vm.prank(alice); vm.expectRevert("Caller is not an admin"); tm.abortRegisteredMovement(id, REASON);
    }
    function testMalformedEndpointsAmountsReferencesAndEnumAreRejected() public {
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(alice, bob, 1, ISSUE);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(address(0), address(0), 1, ISSUE);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(address(0), alice, 0, ISSUE);
        vm.prank(first); vm.expectRevert("Reference hash required"); tm.requestRegisteredMovement(address(0), alice, 1, ISSUE, bytes32(0));
        _seed(100);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(alice, bob, 1, CANCEL);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(address(0), address(0), 1, CANCEL);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(alice, alice, 1, MOVE);
        vm.expectRevert("Insufficient OST balance"); _request(alice, address(0), 101, CANCEL);
        vm.prank(first);
        (bool ok,) = address(tm).call(abi.encodeWithSignature("requestRegisteredMovement(address,address,uint256,uint8,bytes32)", address(0), alice, 1, 3, REF));
        assertFalse(ok);
    }
    function testEscrowAndRetiredWalletCannotBeMovementEndpoints() public {
        _seed(100);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(address(0), address(escrow), 1, ISSUE);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(address(escrow), address(0), 1, CANCEL);
        vm.startPrank(owner); tm.setWalletMigrationController(owner); tm.adminMigrateWallet(alice, address(0x1003), REF); vm.stopPrank();
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(address(0), alice, 1, ISSUE);
        vm.expectRevert(TokenManager.InvalidRegisteredMovement.selector); _request(alice, bob, 1, MOVE);
    }
    function testRecipientEligibilityRecheckedAndFrozenSourceCanFollowLegalDecision() public {
        _seed(100); uint256 id = _request(alice, bob, 40, MOVE); bytes32 hash = _approveMovement(id);
        vm.prank(owner); ac.freezeAddress(bob); vm.warp(tm.registeredMovementReadyAt(id));
        vm.expectRevert("Sender is frozen"); _execute(id); _unconsumed(hash);
        vm.startPrank(owner); ac.unfreezeAddress(bob); ac.freezeAddress(alice); vm.stopPrank();
        _execute(id); assertEq(tm.balanceOfOST(bob), 40);
    }
    function testCap149RejectsIssueAndMoveToNewHolderButAllowsExistingSlotsAndCancel() public {
        _seed(100); _fillSlots(); assertEq(slots.holderCount(), 149);
        vm.expectRevert("Holder cap reached"); _request(address(0), bob, 1, ISSUE);
        vm.expectRevert("Holder cap reached"); _request(alice, bob, 1, MOVE);
        _readyExecute(_request(address(0), alice, 1, ISSUE));
        _readyExecute(_request(alice, address(0), 1, CANCEL));
        assertEq(slots.holderCount(), 149); assertEq(tm.totalSupplyOSTf(), 248);
    }
    function testAt149MoveOfWholeBalanceHandsTheSlotToANewHolder() public {
        _seed(100); _fillSlots();
        _readyExecute(_request(alice, bob, 100, MOVE));
        assertEq(slots.holderCount(), 149);
        assertFalse(slots.hasHolderSlot(alice)); assertTrue(slots.hasHolderSlot(bob));
    }
    function testAt149CancelOfWholeBalanceFreesSlotForANewIssue() public {
        _seed(100); _fillSlots();
        _readyExecute(_request(alice, address(0), 100, CANCEL));
        assertEq(slots.holderCount(), 148);
        _readyExecute(_request(address(0), bob, 1, ISSUE));
        assertEq(slots.holderCount(), 149); assertTrue(slots.hasHolderSlot(bob));
    }
    function testCapRecheckedAtExecutionAndFailureIsAtomic() public {
        _seed(100); uint256 id = _request(address(0), bob, 10, ISSUE); bytes32 hash = _approveMovement(id);
        _fillSlots(); vm.warp(tm.registeredMovementReadyAt(id));
        vm.expectRevert("Holder cap reached"); _execute(id); _unconsumed(hash);
        assertEq(tm.balanceOfOST(bob), 0); assertEq(tm.totalSupplyOSTf(), 248); assertEq(tm.registeredMovements(id).executedAt, 0);
    }
    function testBalanceRecheckedAfterAnotherMovementAndAbortRemainsAvailable() public {
        _seed(100); uint256 id = _request(alice, address(0), 80, CANCEL); bytes32 hash = _approveMovement(id);
        _readyExecute(_request(alice, bob, 60, MOVE));
        vm.expectRevert("Insufficient OST balance"); _execute(id); _unconsumed(hash);
        assertEq(tm.totalSupplyOSTf(), 100); _abort(id);
    }
    function testGenesisPendingBlocksRequestAndPreviouslyApprovedMovement() public {
        uint256 id = _request(address(0), bob, 1, ISSUE); bytes32 hash = _approveMovement(id);
        address[] memory holders = new address[](1); holders[0] = alice;
        uint256[] memory amounts = new uint256[](1); amounts[0] = 100;
        vm.prank(first); tm.requestInitialShareRegistration(holders, amounts, 100, REF);
        vm.expectRevert("Initial registration pending"); _request(address(0), bob, 1, ISSUE);
        vm.warp(tm.registeredMovementReadyAt(id)); vm.expectRevert("Initial registration pending"); _execute(id); _unconsumed(hash);
        _abort(id);
    }
    function testApprovalRevocationResetsDelayAndExpiryFailsClosed() public {
        uint256 id = _request(address(0), alice, 40, ISSUE); bytes32 hash = _approveMovement(id);
        vm.warp(block.timestamp + 1 days); vm.prank(second); ms.revokeApproval(hash);
        assertEq(tm.registeredMovementReadyAt(id), 0);
        _approve(hash, address(tm), second); assertEq(tm.registeredMovementReadyAt(id), block.timestamp + 48 hours);
        vm.warp(block.timestamp + 8 days); assertEq(tm.registeredMovementReadyAt(id), 0);
        vm.expectRevert("Action not approved"); _execute(id);
    }
    function testPausedRequestAndExecutionFailButAbortWorks() public {
        uint256 id = _request(address(0), alice, 40, ISSUE); _approveMovement(id); vm.warp(tm.registeredMovementReadyAt(id));
        vm.prank(owner); tm.pause();
        vm.expectRevert(); _request(address(0), bob, 1, ISSUE);
        vm.expectRevert(); _execute(id); _abort(id);
    }
    function testFuzzIssueThenPartialCancelConservesSupply(uint96 amount, uint96 burn) public {
        amount = uint96(bound(amount, 1, type(uint96).max)); burn = uint96(bound(burn, 1, amount));
        _readyExecute(_request(address(0), alice, amount, ISSUE));
        _readyExecute(_request(alice, address(0), burn, CANCEL));
        assertEq(tm.totalSupplyOSTf(), uint256(amount) - burn); assertEq(tm.balanceOfOST(alice), uint256(amount) - burn);
    }
}
