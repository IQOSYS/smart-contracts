# Registered share movements and token operator governance

This follow-up adds one recurring, privileged register route for the single OST share class. It does not adjudicate legal documents: administrators verify the legal authority, source document and each canonical holder wallet off-chain. Use the SHA-256 digest of the signed source document as `referenceHash`; never put personal data or document text in calldata or proposal descriptions.

## Registered movements

`TokenManager.requestRegisteredMovement(from, to, quantity, movementType, referenceHash)` records an immutable request and emits `RegisteredMovementRequested`. The requester must be both an on-chain admin and a current multisig signer. No balance or holder slot changes at request time.

| Type | Value | from | to | Effect |
| --- | --- | --- | --- | --- |
| Issue | 0 | zero address | canonical holder | Increases OST balance and total supply |
| Cancel | 1 | canonical holder | zero address | Burns available OST and decreases total supply |
| Move | 2 | canonical source holder | different canonical recipient | Changes balances without changing total supply |

Quantity must be a positive integer. The reference must be nonzero. Recipient wallets use the existing whitelist/authorization/freeze checks. Retired wallets and the custodial OST escrow cannot be endpoints. Cancellation and movement may debit a frozen/unapproved source under the approved legal decision (e.g. succession or judicial correction); recipient eligibility is still enforced. Only available, non-escrowed balances can be debited. This route does not replace wallet recovery or migrate IQS/BSA rights.

1. Request the movement and obtain its ID and `getRegisteredMovementActionHash(id)`.
2. Encode `executeRegisteredMovement(id)` and propose that exact consumer, selector and calldata hash through `AdminMultisig.proposeAction`. The action hash also binds the movement type, source/destination, quantity, document hash, request ID, chain ID and TokenManager address.
3. Collect the configured quorum, at least two of the three signers. A configured three-signature threshold remains three.
4. Read `registeredMovementReadyAt(id)`. Execute only after 48 hours from the current quorum, before the proposal/approvals expire. Revocation, expiry or signer rotation cannot retain a stale ready time.
5. Any authorized admin may execute the approved movement; all state changes and approval consumption are atomic. The execution emits the movement ID and evidence reference, plus the normal token events.

For Abort, obtain `getAbortRegisteredMovementActionHash(id, reasonHash)`, propose exact `abortRegisteredMovement(id, reasonHash)` calldata and collect a separate quorum. Abort needs no 48-hour wait and remains available while TokenManager is paused. It permanently cancels this request ID. A retry gets a new ID and fresh approvals.

There is no zero-supply requirement or permanent lock on this recurring route. It works before or after genesis has been permanently locked, including after a full cancellation reduces supply to zero. A pending genesis request blocks movement request/execution until genesis is resolved, preserving the genesis snapshot. The cap of 149 holders at a given time is enforced for issue/move at both request and execution. Cancelling or moving out a holder's whole OST balance frees the slot when nothing else keeps it (no live BSA, no exercise in progress, no OST in escrow); a Move of a whole balance can therefore hand the slot to a new recipient even at 149. A recipient that already holds a slot does not take another one.

## Token operator changes

`setTokenOperator(operator, status, referenceHash)` retains its signature and action-hash format. It now waits 48 hours from the current quorum for both enabling and disabling an operator. Read `tokenOperatorChangeReadyAt(...)`. Existing escrow drain/rotation safeguards remain enforced at execution.

`getAbortTokenOperatorChangeActionHash(...)` / `abortTokenOperatorChange(operator, status, referenceHash, reasonHash)` provide a separate quorum Abort, with no delay. An aborted or executed action hash cannot be reused; use a fresh reference and approvals for a new attempt. Direct admin calls to TokenManager cannot bypass the configured operator controller. Deployment bootstrap is unchanged.