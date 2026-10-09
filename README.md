# Briefs (BRIEFS)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Property | Value |
| --- | --- |
| Solidity contract | `BriefsToken` (`src/BriefsToken.sol`) |
| Token name | Briefs |
| Token symbol | BRIEFS |
| Decimals | 18 |
| Total supply | 1,000,000,000 BRIEFS = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, the whole supply to `msg.sender` |
| Constructor arguments | None |
| Admin powers | None (no owner, minter, pauser, blocklist, fee, or burn) |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## What the contract does

`BriefsToken` inherits OpenZeppelin 5.4.0 `ERC20` unchanged and adds only a constructor that mints
`TOTAL_SUPPLY` to the deployer. There is no other state-changing function beyond the standard
`transfer`, `approve` and `transferFrom`. After deployment:

- The supply can never grow. No mint entry point exists, and the ERC20 `_mint` is internal and
  reached only from the constructor.
- The supply can never shrink. No `burn` or `burnFrom` exists.
- No privileged account exists. Nothing can pause transfers, block an address, or move a balance
  without the holder's own transfer or allowance.
- Transfers move exactly the amount requested, so the launch flows (factory to distributor,
  distributor to claimants, pool seeding, and swaps through the Uniswap v4 PoolManager) arrive
  whole. No exemption lists are needed because nothing is taxed.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and the contract has no
  payable function, so it cannot hold or receive ETH.

## Assumptions

- The brief asks for a plain fixed-supply token. No tax, reflection, vesting, governance or burn
  behaviour was requested, so none is implemented.
- "Minted once to the deployer" means `msg.sender` of the constructor. In the IdentityMD launch the
  deployer is the ProjectFactory, which then distributes the whole supply according to the launch
  economics. In a manual deployment the broadcasting account receives everything.
- The contract takes no constructor arguments and makes no external calls, so it deploys on an
  empty chain and the launch manifest's `constructorArgs` is an empty list.
- The Solidity identifier `BriefsToken` (11 characters) is the launch's contract name. `name()`
  and `symbol()` return the token's own name and symbol.

## Launch parameters (decided by the launch, recorded here for reference)

These values belong to the manifest step, which writes `launch.json` after this work is accepted.
Do not add a `launch.json` to this repository.

- Chain: Ethereum mainnet, chain id 1.
- Paired currency: IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals).
- Pool fee 12500 (1.25%), tick spacing 60, initial sqrtPriceX96 `79228162514264337593543950336`.
- Economics: `poolBps` 7700, `initialMarketCapWei` `2500000000000000000000` (2,500 IMD for the
  whole supply), `remainderTo` `0x6bf192ebef135e0f645e99d59d9bf44e7711606c`.
- Supply split performed by the factory: 10% to the launch's MerkleDistributor, 77% seeds the pool,
  13% to `remainderTo`. The token itself allocates nothing; the factory holds 100% after
  construction and pays all of it out.
- `token.totalSupply` in the manifest: `1000000000000000000000000000`.

## Deployment

The launch deploys the token from the built bytecode. For a local or independent deployment, the
script in `script/DeployBriefsToken.s.sol` wraps `new BriefsToken()` in a broadcast. It reads no
environment variables; the sender comes from the forge command line:

```bash
forge script script/DeployBriefsToken.s.sol:DeployBriefsToken \
  --rpc-url <RPC_URL> --account <KEYSTORE_ACCOUNT> --broadcast
```

Reproducible build settings live in `foundry.toml` and must not change for the deployed bytes to
match: solc 0.8.26, `evm_version = "cancun"`, optimizer on with 200 runs, `via_ir = false`,
`bytecode_hash = "none"`, `cbor_metadata = false`.

## Operational responsibilities

There is nothing to operate after launch: no owner, no settings, no upgrade path, no keys to
rotate. The remaining responsibilities sit with the launch and the requester:

- **Verification.** Verify the deployed source on Etherscan with `forge verify-contract` using the
  settings above, so holders can read the code. This belongs to the network's deployer after the
  launch transaction.
- **Custody of distributed tokens.** The 13% remainder goes to `remainderTo`; that wallet's security
  is the requester's responsibility. The token has no recovery mechanism for lost keys or tokens
  sent to the wrong address.
- **Immutability.** Because there is no admin, no bug can be patched in place. Any change requires
  a new token and a migration the requester would have to organise off-chain.

## Security notes

Reviewed against the pinned eth-security checklist:

- Access control: no privileged functions exist, so there is nothing to restrict.
- Reentrancy: no external calls are made by the token.
- Decimals and math: the supply is a compile-time constant (`1_000_000_000 * 10 ** 18`); no runtime
  arithmetic beyond OpenZeppelin's checked balance updates.
- Input validation: OpenZeppelin reverts on zero-address receivers, spenders and approvers with
  ERC-6093 custom errors; tests cover each.
- Events: every balance and allowance change emits the standard `Transfer` or `Approval`.
- Infinite approvals: `transferFrom` with `type(uint256).max` allowance does not decrement, matching
  standard ERC-20 expectations. Holders should approve only what they need.
- Tools run: `forge build`, `forge test` (25 tests including a 256-run fuzz), `forge fmt --check`,
  all offline. Slither and Mythril were not available in this environment and did not run.

Tests passing are not an audit. The launch's independent review is the adversarial step before
release.

## Dependencies

Vendored as ordinary files under `lib/` (no submodules), so the project builds with no network:

- `lib/forge-std` — forge-std 1.9.7 (MIT), tests and CI removed.
- `lib/openzeppelin-contracts/contracts` — OpenZeppelin Contracts 5.4.0 (MIT), contracts only.

## Running the checks

```bash
forge build
forge test
forge fmt --check
```

## Tests

`test/BriefsToken.t.sol` covers:

- metadata, decimals and the exact supply constants from the brief;
- the constructor minting the whole supply to `msg.sender`, including through a CREATE2 factory
  stub and through the deploy script's `deploy()` function;
- transfers and `transferFrom` succeeding with exact amounts and conserving supply (fuzzed);
- failure paths: insufficient balance, insufficient or missing allowance, zero-address receiver and
  spender;
- absence of mint, burn, ownership, upgrade, pause, blocklist, freeze and seize entry points, tried
  from both a stranger and the deployer;
- runtime bytecode free of `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`, under the EIP-170 limit;
- the token rejecting ETH.
