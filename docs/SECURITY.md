# Local security review

The implementation follows the requested immutable economics. CREATOR is the
requester and disclosed holder; the fixed payment is intentional. This is a
local implementation review, not an independent audit or a live deployment.

| Area | Design and evidence |
| --- | --- |
| Authority | All three enabled callbacks and the unlock callback require the immutable PoolManager. Tests reject other callers. |
| Permissions | Constructor validation; exactly five flags, `0x10CC`, with no beforeInitialize or dynamic fee override. |
| Specified deltas | Positive ETH fee only, 2% of specified amount; raw ETH delta must match specified amount plus fee. Actual core tests verify both modes and reject partial fills. |
| Unspecified deltas | Positive ETH fee only, 2% of raw pool ETH delta; actual core Swap events are compared with returned trader deltas and claim changes. |
| NoOp exposure | No full-input diversion. The fixed fee cannot substitute for the entire input. Before-swap modes verify pool execution. There are no LP-liquidity restrictions. |
| Accounting | Swaps only accrue `totalFees`; claims donations do not accrue entitlement. Random sequences interleave all fee modes, donations, burns and burial while asserting claims coverage. |
| Settlement | Fees mint native claims. Redemption uses an owned unlock, burns exactly the claims owed, and takes exactly the recipient amount. Real manager tests finish with zero unsettled deltas. |
| Reentrancy | Literal transient slot 1 guards manumit, burns and pokes, clearing on return. Slot 2 permits one callback for the hook's own unlock; nested entry and unauthorized callbacks fail. NFT callbacks attempting all three entry points are tested. |
| Burial | Owner read via staticcall; no-code, malformed, zero/noncanonical owner, and revert are unavailable. Transfer revert bytes are preserved in BurialRefused. A successful no-op or failed owner re-read still refuses payment. |
| Atomicity | Reverted NFT transfer or payment restores ownership, claims, creatorPaid and buried. Reverted burns restore budget, cadence and anchor. |
| Routes / recipient | Two constants-only PoolKeys. No path, recipient, caller-selected size, output token, fee override, or tip input. |
| POOL4 decoding | Low-level staticcalls require exactly 32 bytes, canonical true for marketOpen, and a signed TickMath-range reference. No reference freshness rule is added. |
| Price checks | One-sided tick guard and 96% reference output floor, with no LP fee deduction. Caller may only increase minOut. Positive output and exactly full ETH spend are mandatory. |
| Fallback | Start-of-block reference persists after pokes; at most 200 ticks per block; fixed band around lastRef, re-centered after 100 blocks. Both band directions, long idle periods and same-block manipulation are tested. |
| Bytecode | Tests walk runtime bytes, skipping PUSH payloads, and reject F2, F4, FF. Runtime must fit EIP-170. Metadata is omitted. |
| Token | Zero-argument fixed issuance; no minting after construction, taxation, owner, pause, proxy, or arbitrary external calls. Transfers and delegated/self burns conserve the documented balances. |

The supplied Ethereum and Uniswap security references were reviewed as
background. Where their general recommendations differ, the assignment wins:
the addresses are fixed; there is no administrator, router allowlist, staleness
rule, or pause. `sender` and hookData never authorize a recipient or action.

## Assumptions and limitations

The canonical PoolManager and fixed external contracts are trusted to implement
their stated interfaces. NFT approval remains controlled by its actual holder.
Successful `ownerOf` verification proves what that external contract reports;
it does not prove anything about proxy governance or future NFT-contract
behavior. CREATOR's receipt of exactly 2.8 ETH is independent of subsequent
ownership changes. DEAD transfers and permanence rely on those external token
contracts' semantics.

The open POOL4 reference is accepted without an age rule, as specified. Fallback
uses plain spot subject to bounded movement, a band, and periodic re-centering;
it is not an independent price oracle and can drift under sustained
manipulation. The one-sided check, batch cap, cadence, and 4% output floor limit
execution but do not eliminate MEV. Output also must fit v4's signed int128
delta; extreme prices can make a burn impossible. Quotes floor integer amounts.

IMD is assumed to be a conventional 18-decimal ERC-20 at the fixed address.
Fee-on-transfer, blocked DEAD transfers, rebasing, and restrictive external
governance are not supported adaptations. The token launched here is FREE1376,
not IMD. The plain and POOL4 liquidity and external hook behavior remain external
operational dependencies.

## Validation boundary

Local validation covers compiler configuration, manifest fields and ABIs,
runtime opcode checks, unit failures and successes, fuzzing, stateful invariants,
and real-manager lifecycle settlement. Tests are offline and use `vm.etch` at
fixed external addresses. No test reads or writes environment variables, uses
FFI, or needs filesystem access permissions.

No live-chain fork rehearsal, transaction, deployment, Slither/Mythril run,
formal verification, or independent contributor audit is claimed. Before a
funded launch, an independent contributor must review the actual deployment
artifacts and fixed external contracts, and the deployer must rehearse the
full lifecycle against the target chain. The committed code has no mechanism
to repair a deployed instance.
