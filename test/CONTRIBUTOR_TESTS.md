These additions extend the existing tests without changing the implementation or configuration.

| File | Additional guarantees checked |
| --- | --- |
| `TokenStateMachine.t.sol` | Four actors transfer, approve, revoke, burn and spend delegated balances in arbitrary order. Independent balances, allowance entries and cumulative burns must match the token. Expected failures must preserve every modeled entry. Zero, one, entire balance, balance plus one and maximum uint inputs are generated explicitly. |
| `CoreLedgerInvariant.t.sol` | Real PoolManager swaps and settlement, claim donations, normal/fallback burns, failed slippage, missing NFT approval, repeated burial attempts and block advancement. Fees are derived from core swap events; payments and burn expenditure have separate counters. Claims cover all obligations, every unlock settles, the creator is paid once and callers receive no burn proceeds. |
| `AnchorTransitions.t.sol` | Arbitrary valid oracle ticks, normal/fallback transitions, multiple callers in one block and long idle periods. The anchor stays in its band, moves at most 200 ticks per block, preserves the block-start reference and recenters at the 100-block boundary. |
| `HookAdversarial.t.sol` | Fee arithmetic and dust in all four modes, pool-key isolation, integer endpoints, one-wei fill mismatches, malformed oracle/NFT returns, arbitrary burial failure payloads, payment-time reentrancy, unavailable pools, failed burn rollback and quote rounding. |

The new invariant campaigns each use 256 runs at depth 96 with unexpected handler reverts treated as failures. The adversarial property tests use 1,000 fuzz runs. Deterministic sequences separately ensure that successful burns, burial, allowance revocation and full-supply destruction are reachable.

All dependencies are already vendored. Run `forge build --offline` and `forge test --offline` from the repository root. No fork, RPC, FFI or shared environment mutation is needed. To keep generated artifacts inside the assignment's scratch area, use:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR=test/scratch/invariant FOUNDRY_FUZZ_FAILURE_PERSIST_DIR=test/scratch/fuzz forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The real-manager campaign uses local doubles for the fixed-address NFT, IMD and POOL4 dependency. It verifies local settlement and the specified dependency interfaces; it does not establish the deployed contracts' behavior on a live chain. The mock-manager tests deliberately inject invalid responses to cover rejection paths that a conforming manager cannot produce. No test depends on the removable `.imd/reads` inputs or on scratch files.
