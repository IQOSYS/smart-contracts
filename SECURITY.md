# Security operations

## Compromised token operator

1. **Pause TokenManager first.** One on-chain base Admin can call `TokenManager.pause()` immediately. No proposal, second signature or 48-hour wait is required. Verify `TokenManager.paused() == true` on the configured chain. The platform's emergency **Pause all** action also pauses TokenManager; verify its result on-chain. If the platform is unavailable, use the admin wallet directly against the reviewed TokenManager address.
2. Record the incident privately. Use a nonzero hash of the approved source document as the disable reference; never include personal information in a public description or calldata.
3. Queue `TokenOperatorController.setTokenOperator(operator, false, referenceHash)` through `AdminMultisig.proposeAction` with the exact controller, selector and calldata hash. Collect **2 of the 3 current signers** (or the configured stronger threshold). The 48-hour delay starts when quorum is reached, not when the proposal is created. Check the on-chain `tokenOperatorChangeReadyAt` value; use a proposal deadline long enough for quorum collection and the full delay (normally 72 hours or longer, within the contract validity limit).
4. Keep TokenManager paused throughout approval collection and the entire delay. A separate quorum-approved `abortTokenOperatorChange` can cancel a wrong disable intent without waiting 48 hours. Abort is independent of the disable approval; use a nonzero opaque reason hash. Retrying an aborted/executed change requires a fresh reference and approvals.
5. After the delay, execute the approved disable and verify its finalized `TokenOperatorChangeExecuted` receipt and `TokenManager.isTokenOperator(operator) == false`. Inspect every affected module and reconcile balances, escrow, privileges, keys and pending actions.
6. **Do not unpause automatically.** After incident assessment, make a separate decision and collect 2-of-3 multisig approval for the exact `EmergencyController.unpauseAll(referenceHash)` action before resuming TokenManager. `TokenManager.unpause()` is restricted to the EmergencyController role; token operator permission alone cannot call it. The 48-hour operator-change delay does not replace the separate unpause authorization.

Disabling is subject to the existing custody protections: an operator holding OST cannot be revoked, and the platform also blocks disabling the active escrow. If revocation is blocked, keep TokenManager paused and obtain a reviewed recovery/drain/escrow-rotation plan. Do not bypass these checks or reopen a compromised system merely to clear the disable.

## Deployment bindings

Verify the actual deployment before relying on the procedure: three current multisig signers; threshold at least two; TokenManager's EmergencyController role bound to the reviewed controller; the token-operator controller and all consumer/module bindings correct. Verify the single-admin pause and quorum-only unpause on the fresh Amoy deployment before mainnet. Never grant the EmergencyController role to a token operator wallet to work around the flow.

## Initiation alerts

The platform listener observes `RegisteredMovementRequested`, `ActionProposed` for `executeRegisteredMovement(uint256)` targeting TokenManager, and `ActionProposed` for `setTokenOperator(address,bool,bytes32)` targeting TokenOperatorController. Both the movement request and its proposal generate notices; renewed proposals generate new notices too. Operations sent directly on-chain are covered.

After canonical finality and the configured polling interval, the backend commits the event, one email and one SMS outbox delivery for **every base Admin account**, and its cursor atomically. It immediately dispatches the delivery job; it does not wait for quorum or the 48-hour execution delay. Run the queue worker continuously and the scheduler every minute for retry recovery. Provider failures remain retryable, and missing contact details are shown as undeliverable for correction. Verify real email and SMS provider acceptance for every admin on staging; local mocked tests do not establish production delivery.
