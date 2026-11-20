# IQOSYS Smart Contracts

Solidity contracts for BSA subscription warrants, IQS subscription rights and the OST ordinary-share ledger.

IQOSYS manages the lifecycle from warrant registration and rights allocation to share issuance and controlled transfers. The system combines a custom ledger, administrative multisig approvals, escrow settlement and on-chain evidence registries.

**Solidity 0.8.20 · Foundry · OpenZeppelin Contracts 5.1.0 · Polygon PoS**

[Overview](#overview) · [Getting started](#getting-started) · [Architecture](#architecture) · [Workflows](#workflows) · [Security model](#security-model) · [Deployments](#deployments)

## Overview

| Instrument | Purpose |
| --- | --- |
| **BSA** | Subscription warrant recording the holder, contractual terms, strike price, maximum allocation and expiry. |
| **IQS** | Whole, non-transferable subscription rights awarded under a BSA. Exercise burns IQS and issues an equal quantity of OST. |
| **OST** | On-chain representation of ordinary shares, held in a controlled ledger and transferred through the settlement module. |

The custom ledger does not implement the general-purpose ERC-20 interface. OST supply starts at zero. Existing shares can be registered once through the approved genesis import; subsequent changes follow the approved exercise process or quorum-controlled registered issue, cancellation and movement. See [registered movements and token operator governance](docs/registered-movements.md).

The contracts record authorized actions and evidence references. Eligibility checks, signed agreements, bank payments and company-law formalities take place off-chain. Their completion cannot be inferred from an on-chain record alone.

## Getting started

Install [Foundry](https://getfoundry.sh/) and use a local checkout with the repository's recorded dependencies, including `forge-std` and OpenZeppelin Contracts.

If the checkout uses Git submodules, initialize them first:

```sh
git submodule update --init --recursive
```

Build and run the test suite from the repository root:

```sh
forge build
forge test
forge build --sizes
```

Compiler settings are defined in [foundry.toml](foundry.toml):

| Setting | Value |
| --- | --- |
| Solidity | `0.8.20` |
| EVM target | `shanghai` |
| Optimizer | Enabled, `200` runs |
| Via IR | Enabled |

Keep dependency versions and compiler settings consistent when verifying deployed bytecode.

## Architecture

The system uses dedicated contracts for authorization, accounting, settlement and evidence. [IQOS](src/IQOS.sol) holds references to the module set; each module executes its own business logic.

| Contract | Responsibility |
| --- | --- |
| [AccessControl](src/AccessControl.sol) | Ownership, administrators, scoped roles, whitelist and freeze controls. |
| [AdminMultisig](src/AdminMultisig.sol) | Proposals, signer approvals, execution authorization and proposal recovery. |
| [TokenManager](src/TokenManager.sol) | IQS/OST balances, supply and operator bindings. |
| [HolderRegistry](src/HolderRegistry.sol) | Number of holders at a given time (maximum 149), with slots that free themselves at BSA expiry. |
| [BSARegistry](src/BSARegistry.sol) | Warrant terms, rights allocation, awards, expiry and exercise accounting. |
| [ConversionModule](src/ConversionModule.sol) | IQS exercise, capital confirmation and OST issuance. |
| [OSTTransferModule](src/OSTTransferModule.sol) | Transfer requests, escrow, payment evidence, settlement and dispute handling. |
| [HashRegistry](src/HashRegistry.sol) | Module-scoped evidence hashes and document supersession. |
| [GovernanceRegistry](src/GovernanceRegistry.sol) | Official voting outcomes and ballot roots. |
| [ValuationAnchor](src/ValuationAnchor.sol) | Valuation publications and linked corrections. |
| [EmergencyController](src/EmergencyController.sol) | Scoped pause and approved resume operations. |
| [HolderMigrationController](src/HolderMigrationController.sol) | Delayed holder-wallet recovery and migration cancellation. |
| [TokenOperatorController](src/TokenOperatorController.sol) | Approved changes to token operators. |

### Repository layout

| Path | Contents |
| --- | --- |
| [src/](src/) | Solidity contracts and supporting interfaces. |
| [test/](test/) | Foundry tests and regression cases. |
| [script/](script/) | Deployment scripts. |
| [foundry.toml](foundry.toml) | Build, compiler and network configuration. |

## Workflows

### BSA registration and IQS awards

Approved registration records the warrant's terms and maximum allocation. Subsequent approved awards credit IQS to the holder and reduce the unawarded allocation. Registration does not mint the full allocation; expiry and cancellation update the remaining rights.

### Existing-share registration

Before any OST is issued, administrators can register all existing shares and their current holders in a single transaction. The approval binds the complete address/quantity list, declared total and SHA-256 of the signed off-chain register extract. Registration requires the configured quorum (at least two of three signers), a 48-hour delay, and compliance with the shared permanent 149-holder cap. A separate quorum can abort before execution. Successful registration permanently locks this import path.

See [Initial share registration](docs/initial-share-registration.md) for the approval workflow, canonical-address checks and platform alert integration.

### IQS exercise and OST issuance

A holder requests exercise against an eligible BSA and available IQS. After approval and capital confirmation, finalization burns the exercised IQS, updates the BSA record and issues the same number of OST in one transaction.

### OST transfer and settlement

1. A transfer request identifies the participants, quantity, price and agreement evidence.
2. Acceptance locks the seller's OST in escrow.
3. Buyer payment evidence is recorded.
4. A quorum-approved settlement confirms the seller's receipt of payment and releases the OST to the buyer atomically.

The combined `adminConfirmSellerPaymentAndRelease` action binds the transfer and both receipt hashes. If release fails, payment confirmation and approval consumption revert with it. Dispute, resolution and timeout-reclaim paths depend on the transfer state and deadlines.

Escrow holds already-issued OST. Token release and reclaim do not execute or reverse bank payments.

## Security model

IQOSYS uses permissioned administration. Ownership, multisig signer membership, scoped roles and token operators are separate authorities.

| Control | Behavior |
| --- | --- |
| **Administrative quorum** | The deployment script configures three signers with two required approvals. Operations use the applicable live threshold. |
| **Bound approvals** | A proposal binds its consumer, function selector, calldata hash and deadline. Proposal creation does not count as an approval. |
| **Single consumption** | Only the bound consumer can consume an approved action, once. Approvals also depend on signer epoch and proposal lifecycle. |
| **Emergency controls** | An administrator can pause an allowed scope immediately. Resuming requires the corresponding quorum-approved controller action. |
| **Existing shares** | Genesis-only registration binds the complete register, verifies its declared total and executes atomically after quorum plus 48 hours. A separate quorum can abort, including while paused. |
| **Wallet recovery** | Migration requires at least two approvals, honors a higher configured threshold and enforces a 48-hour delay from effective quorum. Open transfers block migration. |
| **Evidence integrity** | Terminal exercise and transfer receipt hashes are write-once. Document corrections preserve prior evidence through linked supersession where applicable. |

IQS and OST share a **149-holder limit counted at a given time**, kept by `HolderRegistry` and readable through `holderCount()`. A wallet holds a slot while it has a BSA that is not expired, cancelled or fully exercised, IQS in an exercise in progress, OST in the wallet, or OST of its own in the P2P escrow. The slot is taken when the BSA is recorded (`recordBSA` is refused at 149) and by Issue, Move and genesis recipients. It is freed when nothing in that list remains: by Cancel, Move, a sale, BSA cancellation, or at the BSA expiry date with no transaction. Authorized wallet migration carries the slot to the new wallet. This is a wallet-level restriction, not a count of verified individuals or a regulatory exemption.

At BSA expiry, unexercised IQS lapse and stop counting immediately. They are burned at the next action on that BSA, except IQS already in an exercise in progress, which keep the slot until that exercise ends.

The owner Safe and `AdminMultisig` have independently configured thresholds. Contracts are deployed directly without upgrade proxies. Module replacement requires redeployment and a reviewed migration plan; several bindings are one-time setters.

## Accounting

IQS and OST quantities are whole units. Contractual monetary values use integer EUR cents.

| Field | Unit | Example |
| --- | --- | --- |
| `strikePrice` | EUR cents per OST | `185` = EUR 1.85 |
| `pricePerOST` | EUR cents per OST | `200` = EUR 2.00 |
| `premiumPaid` | Total EUR cents for the BSA | `15000` = EUR 150.00 |
| `capitalDue` | Total EUR cents | `10 × 185 = 1850` = EUR 18.50 |

The valuation denominator combines issued OST, minted unexercised IQS and unawarded allocation from active, unexpired BSAs:

```solidity
TokenManager.totalSupplyOSTf()
    + TokenManager.totalSupplyIQS()
    + BSARegistry.totalIQSInEscrow()
```

OST in transfer escrow remains part of issued supply. Read all quantities at the same block and use a consistent currency scale with the approved off-chain valuation. The contracts do not appraise the company.

## Testing

The [Foundry suite](test/) covers authorization, multisig lifecycle, warrant accounting, exercise, transfer settlement, expiry and wallet recovery. Regression suites include [AtomicOSTSettlement.t.sol](test/AtomicOSTSettlement.t.sol) and [Reaudit20261016.t.sol](test/Reaudit20261016.t.sol).

The [initial registration regression suite](test/InitialShareRegistration.t.sol) covers complete imports, declared totals, eligibility, the holder cap, delay, Abort and approval invalidation.

Run tests against the exact revision being reviewed.

## Deployments

### Polygon mainnet

**Chain ID:** `137`

| Contract | Address |
| --- | --- |
| HashRegistry (IQOSYS Vault proofs) | [`0xeda7f04d01734658b054a5cb6a6af8caa5e904db`](https://polygonscan.com/address/0xeda7f04d01734658b054a5cb6a6af8caa5e904db) |

Anyone can check an IQOSYS Vault proof against this contract with the open-source [IQOSYS Vault verifier](https://github.com/IQOSYS/vault-verifier) ([online](https://iqosys.github.io/vault-verifier/)).

### Polygon Amoy (test network)

**Chain ID:** `80002` · **Deployment block:** `50548536`

Recorded testnet module addresses:

| Contract | Address |
| --- | --- |
| IQOS | [`0x93c4481d0D4eebD1af3bac2844104182C4963d0F`](https://amoy.polygonscan.com/address/0x93c4481d0D4eebD1af3bac2844104182C4963d0F) |
| AccessControl | [`0x5f9E7F733818C1770b08f017cdea65849B22317f`](https://amoy.polygonscan.com/address/0x5f9E7F733818C1770b08f017cdea65849B22317f) |
| AdminMultisig | [`0xb5eaEf87EeEeaa570216AC997CC25c236af09Ec0`](https://amoy.polygonscan.com/address/0xb5eaEf87EeEeaa570216AC997CC25c236af09Ec0) |
| TokenManager | [`0x88C022Cf06C6802E216bedA01DEecbFfc4588b32`](https://amoy.polygonscan.com/address/0x88C022Cf06C6802E216bedA01DEecbFfc4588b32) |
| BSARegistry | [`0x6708856ec9fd648698253bD2d96A6109068D5214`](https://amoy.polygonscan.com/address/0x6708856ec9fd648698253bD2d96A6109068D5214) |
| ConversionModule | [`0xD5bF7cEd7a99861C2a13D428fA6C63c2aC7E0F3f`](https://amoy.polygonscan.com/address/0xD5bF7cEd7a99861C2a13D428fA6C63c2aC7E0F3f) |
| OSTTransferModule | [`0x24C7ea1fEcFe745e520bceE269e8aB81Bec0C515`](https://amoy.polygonscan.com/address/0x24C7ea1fEcFe745e520bceE269e8aB81Bec0C515) |
| HolderRegistry | [`0x1b29e99CAfb588Ce1a97e40084457DC0222bD095`](https://amoy.polygonscan.com/address/0x1b29e99CAfb588Ce1a97e40084457DC0222bD095) |
| HashRegistry | [`0x57d9f03da08DE4448053a695031D50E6FC821Dde`](https://amoy.polygonscan.com/address/0x57d9f03da08DE4448053a695031D50E6FC821Dde) |
| GovernanceRegistry | [`0xf2d26A23179a46DA8fA20394e0fa900A52874dE7`](https://amoy.polygonscan.com/address/0xf2d26A23179a46DA8fA20394e0fa900A52874dE7) |
| ValuationAnchor | [`0xa3CbFa92BF582f9EeAAc056Acd0a5567dE9A64F0`](https://amoy.polygonscan.com/address/0xa3CbFa92BF582f9EeAAc056Acd0a5567dE9A64F0) |
| EmergencyController | [`0x3e4A56AA6E4d92E7e07C452e8aeCeeC276E171e6`](https://amoy.polygonscan.com/address/0x3e4A56AA6E4d92E7e07C452e8aeCeeC276E171e6) |
| HolderMigrationController | [`0x128899CE809eEE478Bf1EBB791a488eDFcD01320`](https://amoy.polygonscan.com/address/0x128899CE809eEE478Bf1EBB791a488eDFcD01320) |
| TokenOperatorController | [`0x96ba32259F68571482fC4ba0fEC4589DB962c0E4`](https://amoy.polygonscan.com/address/0x96ba32259F68571482fC4ba0fEC4589DB962c0E4) |

### Deploying the contracts

The entry point is [DeployIQOS](script/Deploy.s.sol). It deploys the modules, configures permissions and initiates ownership transfer.

Configure deployment values locally:

| Variable | Purpose |
| --- | --- |
| `PRIVATE_KEY` | Deployment signer. |
| `OWNER_SAFE` | Intended AccessControl owner. |
| `ADMIN_SIGNER_1`, `ADMIN_SIGNER_2`, `ADMIN_SIGNER_3` | Distinct initial signers, each different from the deployer. |
| `POLYGON_AMOY_RPC_URL` | RPC endpoint for the `amoy` alias. |
| `POLYGON_MAINNET_RPC_URL` | RPC endpoint for the `polygon` alias, if used. |
| `POLYGONSCAN_API_KEY` | Explorer verification credential, if used. |

Keep private keys and credential-bearing RPC URLs out of version control.

Simulate deployment:

```sh
forge script script/Deploy.s.sol:DeployIQOS --rpc-url amoy -vv
```

After reviewing the simulation and target configuration, broadcast:

```sh
forge script script/Deploy.s.sol:DeployIQOS --rpc-url amoy --broadcast -vv
```

Deployment spans multiple transactions. Inspect every receipt and resolve failed steps. Verify bytecode, module bindings, permissions and bootstrap locks against the reviewed revision.

The designated Safe must execute `acceptOwnership()` on AccessControl. Confirm the final owner, cleared pending owner and removal of the deployer's operational privileges.

## Integration notes

Use module-specific interfaces and the live configuration. Preserve integer precision and distinguish currency units from gas fees. If application synchronization fails after a successful transaction, reconcile its original receipt before considering another transaction.

## Contributing

Describe the effect of changes on contract state and permissions. Include tests for successful execution and relevant failure paths, then run `forge build` and `forge test` before submitting a pull request.


## License

Licensed under the MIT License. Third-party dependencies are subject to their respective licenses.
