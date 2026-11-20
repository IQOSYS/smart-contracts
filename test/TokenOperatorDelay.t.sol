// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./RegisteredMovement.t.sol";

contract TokenOperatorDelayTest is MovementFixture {
    function _operatorHash(bool status) internal view returns (bytes32) {
        return operators.getSetTokenOperatorActionHash(bob, status, REF);
    }
    function _approveOperator(bool status) internal returns (bytes32 hash) {
        hash = _operatorHash(status);
        _quorum(hash, address(operators), abi.encodeCall(operators.setTokenOperator, (bob, status, REF)));
    }
    function _set(bool status) internal returns (uint256) {
        vm.prank(owner); return operators.setTokenOperator(bob, status, REF);
    }
    function _abortOperator(bool status) internal {
        bytes32 hash = operators.getAbortTokenOperatorChangeActionHash(bob, status, REF, REASON);
        _quorum(hash, address(operators), abi.encodeCall(operators.abortTokenOperatorChange, (bob, status, REF, REASON)));
        vm.prank(owner); operators.abortTokenOperatorChange(bob, status, REF, REASON);
    }
    function testDelayStartsAtQuorumAndExecutesAtExactBoundary() public {
        bytes32 hash = _operatorHash(true);
        _propose(hash, address(operators), abi.encodeCall(operators.setTokenOperator, (bob, true, REF)));
        _approve(hash, address(operators), first); vm.warp(block.timestamp + 1 days);
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        vm.expectRevert("Action not approved"); _set(true);
        _approve(hash, address(operators), second);
        uint256 ready = operators.tokenOperatorChangeReadyAt(bob, true, REF);
        assertEq(ready, block.timestamp + 48 hours);
        vm.warp(ready - 1); vm.expectRevert("Token operator delay not elapsed"); _set(true);
        assertFalse(tm.isTokenOperator(bob)); _unconsumed(hash);
        vm.warp(ready); uint256 id = _set(true);
        assertTrue(tm.isTokenOperator(bob)); assertEq(operators.changesf(id).executedAt, ready);
        assertTrue(operators.executedTokenOperatorChanges(hash)); assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        vm.expectRevert("Token operator change already executed"); _set(true);
    }
    function testOneSignatureCannotExecuteOrAbortEvenAfter48Hours() public {
        bytes32 hash = _operatorHash(true);
        _propose(hash, address(operators), abi.encodeCall(operators.setTokenOperator, (bob, true, REF)));
        _approve(hash, address(operators), first); vm.warp(block.timestamp + 3 days);
        vm.expectRevert("Action not approved"); _set(true);
        bytes32 abortHash = operators.getAbortTokenOperatorChangeActionHash(bob, true, REF, REASON);
        _propose(abortHash, address(operators), abi.encodeCall(operators.abortTokenOperatorChange, (bob, true, REF, REASON)));
        _approve(abortHash, address(operators), first);
        vm.prank(owner); vm.expectRevert("Action not approved"); operators.abortTokenOperatorChange(bob, true, REF, REASON);
        assertFalse(tm.isTokenOperator(bob)); assertFalse(operators.abortedTokenOperatorChanges(hash));
    }
    function testQuorumAbortImmediatelyPreventsApprovedExecutionAndOldApprovalsCannotReviveIt() public {
        bytes32 hash = _approveOperator(true); _abortOperator(true);
        assertTrue(operators.abortedTokenOperatorChanges(hash));
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert("Token operator change aborted"); _set(true);
        _unconsumed(hash); assertEq(operators.changeCount(), 0); assertFalse(tm.isTokenOperator(bob));
        bytes32 fresh = operators.getSetTokenOperatorActionHash(bob, true, REASON);
        _quorum(fresh, address(operators), abi.encodeCall(operators.setTokenOperator, (bob, true, REASON)));
        vm.warp(operators.tokenOperatorChangeReadyAt(bob, true, REASON));
        vm.prank(owner); operators.setTokenOperator(bob, true, REASON); assertTrue(tm.isTokenOperator(bob));
    }
    function testAbortAlsoAvailableAfterDelayButNotAfterExecution() public {
        _approveOperator(true); vm.warp(operators.tokenOperatorChangeReadyAt(bob, true, REF)); _abortOperator(true);
        vm.expectRevert("Token operator change aborted"); _set(true);
        _approveOperator(false); vm.warp(operators.tokenOperatorChangeReadyAt(bob, false, REF)); _set(false);
        vm.prank(owner); vm.expectRevert("Token operator change already executed"); operators.abortTokenOperatorChange(bob, false, REF, REASON);
    }
    function testDisableHasSameDelayAndCanBeAborted() public {
        _approveOperator(true); vm.warp(operators.tokenOperatorChangeReadyAt(bob, true, REF)); _set(true);
        _approveOperator(false);
        vm.expectRevert("Token operator delay not elapsed"); _set(false);
        _abortOperator(false); assertTrue(tm.isTokenOperator(bob));
        vm.expectRevert("Token operator change aborted"); _set(false);
    }
    function testRevokingQuorumResetsReadyAtAndReapprovalStartsFreshDelay() public {
        bytes32 hash = _approveOperator(true);
        vm.warp(block.timestamp + 1 days); vm.prank(second); ms.revokeApproval(hash);
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        _approve(hash, address(operators), second);
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), block.timestamp + 48 hours);
        vm.warp(block.timestamp + 1 days); vm.expectRevert("Token operator delay not elapsed"); _set(true);
    }
    function testExpiredApprovalCannotExecuteAfterWaiting() public {
        _approveOperator(true); vm.warp(block.timestamp + 8 days);
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        vm.expectRevert("Action not approved"); _set(true);
    }
    function testSignerRotationInvalidatesPreviousOperatorApprovals() public {
        _approveOperator(true);
        address replacement = address(0xA4);
        bytes32 rotateHash = ms.getReplaceSignerActionHash(third, replacement, REASON);
        _quorum(rotateHash, address(ms), abi.encodeCall(ms.replaceSigner, (third, replacement, REASON)));
        vm.warp(ms.signerRotationReadyAt(third, replacement, REASON));
        vm.prank(owner); ms.replaceSigner(third, replacement, REASON);
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        vm.expectRevert("Action not approved"); _set(true);
    }
    function testThreeSignatureThresholdIsHonoredForExecutionAndAbort() public {
        bytes32 hash = ms.getSetRequiredSignaturesActionHash(3, REASON);
        _quorum(hash, address(ms), abi.encodeCall(ms.setRequiredSignaturesWithApproval, (3, REASON)));
        vm.prank(owner); ms.setRequiredSignaturesWithApproval(3, REASON);
        hash = _approveOperator(true); assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), 0);
        _approve(hash, address(operators), third);
        assertEq(operators.tokenOperatorChangeReadyAt(bob, true, REF), block.timestamp + 48 hours);
        hash = operators.getAbortTokenOperatorChangeActionHash(bob, true, REF, REASON);
        _quorum(hash, address(operators), abi.encodeCall(operators.abortTokenOperatorChange, (bob, true, REF, REASON)));
        vm.prank(owner); vm.expectRevert("Action not approved"); operators.abortTokenOperatorChange(bob, true, REF, REASON);
        _approve(hash, address(operators), third);
        vm.prank(owner); operators.abortTokenOperatorChange(bob, true, REF, REASON);
    }
    function testOnlyAdminsCanExecuteAndAbort() public {
        _approveOperator(true); vm.warp(operators.tokenOperatorChangeReadyAt(bob, true, REF));
        vm.prank(alice); vm.expectRevert("Caller is not an admin"); operators.setTokenOperator(bob, true, REF);
        vm.prank(alice); vm.expectRevert("Caller is not an admin"); operators.abortTokenOperatorChange(bob, true, REF, REASON);
    }
    function testTokenManagerStillBlocksDirectAdminBypass() public {
        vm.prank(owner); vm.expectRevert("Caller is not token operator controller"); tm.setTokenOperator(bob, true);
    }
    function testInvalidAbortInputsAreRejected() public {
        vm.prank(owner); vm.expectRevert("Invalid operator"); operators.abortTokenOperatorChange(address(0), true, REF, REASON);
        vm.prank(owner); vm.expectRevert("Reference and reason required"); operators.abortTokenOperatorChange(bob, true, REF, bytes32(0));
    }
}
