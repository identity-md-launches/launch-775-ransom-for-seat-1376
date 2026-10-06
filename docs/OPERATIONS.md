# Deployment and operations

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| Token / symbol / decimals | Ransom for Seat 1376 / FREE1376 / 18 |
| Initial supply | `1e27`, all to constructor caller |
| Hook constructor | The target chain's `IPoolManager`, only argument |
| Permission bits | `0x10CC`, address mask `0x3FFF` |
| Launch pair | Native ETH / newly deployed FREE1376 |
| Launch LP fee / spacing | 3000 / 60 |
| Assumed initial price | 1 FREE1376 per ETH; `sqrtPriceX96 = 79228162514264337593543950336` |
| Solidity / EVM | 0.8.26 / Cancun |
| Optimizer | Enabled, 200 runs; `via_ir = false` |
| Metadata | `bytecode_hash = "none"`, `cbor_metadata = false` |

CREATOR is the requester's wallet and disclosed seat #1376 holder. The fixed
payment to that wallet is intended, even if the NFT's owner later changes.

| Public constant | Value |
| --- | --- |
| BUY_FEE_BPS / SELL_FEE_BPS | 200 / 200 |
| CREATOR_SHARE_BPS / CREATOR_CAP | 10000 / 2.8 ETH |
| CREATOR | `0xDF90937E07c60108B505FE3C542aB782e0A19AE5` |
| IDENTITY_MD / SEAT_ID | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` / 1376 |
| DEAD / IMD_SINK | `0x000000000000000000000000000000000000dEaD` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| POOL4_HOOK | `0xc6C965Bd164c483e87d0B550671798e9A3602840` |
| MAX_BURN_BATCH / FALLBACK_BURN_BATCH | 0.05 ETH / 0.01 ETH |
| MIN_BURN / MIN_BLOCKS_BETWEEN_BURNS | 0.002 ETH / 5 |
| MAX_REF_DEVIATION / MAX_PLAIN_DEVIATION | 150 ticks / 300 ticks |
| MAX_SLIPPAGE_BPS | 400 |
| ANCHOR_STEP / FALLBACK_BAND | 200 ticks / 1000 ticks |
| FALLBACK_RECENTER_BLOCKS | 100 |
| MANIFESTO_HASH | `0x95338e67928e8de51d027502b517c31a293a053300c1c9fe56ed940f07595d4f` |

The only two burn PoolKeys are `(ETH, IMD, 10000, 60, POOL4_HOOK)` and
`(ETH, IMD, 10000, 200, address(0))`. `burnPoolKey(bool)` exposes these exact
tuples. `quoteAtTick(tick, amount)` quotes raw IMD units for raw native wei using
TickMath; `status()` displays IMD on the specified assumption of 18 decimals.

## Reviewable deployment sequence

1. Confirm the chain has Cancun transient storage, the intended v4 PoolManager,
   the three fixed external contracts, and both specified IMD pools. Confirm
   IMD decimals and ordinary transfer behavior, NFT `ownerOf`/`transferFrom`,
   POOL4 `marketOpen`/`refTick`, and the holder/payee address. These fixed addresses
   cannot be adapted to another chain after deployment.
2. Confirm the initial-price assumption and perform the independent review and
   live-chain rehearsal described in SECURITY.md. Local mocks do not verify
   these external contracts or their governance.
3. Compile with the committed settings. Use CREATE2 salt mining against
   `keccak256(ManumissionHook.creationCode ++ abi.encode(poolManager))` and the
   actual factory address. Require `uint160(predictedHook) & 0x3FFF == 0x10CC`.
   Constructor code, manager argument, and factory must match the mined inputs.
4. In the factory's atomic transaction, deploy the zero-argument token and hook,
   then initialize the native ETH / FREE1376 key at the reviewed initial price.
   A hook deployed in an earlier transaction can have its first native pool
   selected by anyone. Initialization intentionally imposes no allowlist.
5. Verify deployed code and the declared permissions, `launchPool`, balances,
   and constants. Seed liquidity according to the launcher's allocation. The
   hook can collect claims from the first buy in a token-only launch.
6. The actual NFT holder calls `approve(hook, 1376)` on IDENTITY_MD, or grants its
   standard operator approval if that contract requires it. Prefer approval
   scoped to this seat. The hook does not approve or acquire the NFT itself.

## Runtime responsibilities

Keepers watch `totalFees`, `creatorEntitlement`, `buried`, `burnable`,
`lastBurnBlock`, `pool4Seen`, `anchor`, `blockStartAnchor`, `anchorBlock`,
`lastRef`, and `lastRefBlock`. `Manumitted` means the ransom is ready. Submit
`manumit()` to effect burial and payment in one transaction. No owner is
authorized to withdraw part of the ransom, change the payee, or waive burial.

Submit `burnIMD` only when the cadence, budget, available liquidity, reference,
and output checks can pass. The effective minimum is the greater of the
caller's raw-IMD `callerMinOut` and the contract's reference minimum. Five blocks
is measured between successful burns across both routes, not per caller. The
first burn also waits five blocks from deployment. Failures preserve the
previous cadence and budget. Callers receive neither ETH nor IMD.

When POOL4 fails or closes, keepers can call `pokeAnchor()` to move the fallback
anchor. A valid open-POOL4 response re-seeds it at any time, including from the
constructor. Fallback cannot bootstrap from the plain pool alone. Its once per
block movement and 100-block re-centering are deliberate recovery behavior:
waiting does not accumulate a right to multiple steps in one block.

No keeper service is installed here. With no willing gas payer, fees remain
claims, burial remains pending, and burns/pokes do not occur. Failed payments,
external token restrictions, missing approval, missing liquidity, and guard
failures cannot be bypassed by an administrator. Direct surplus donations have
no recovery path. A sub-minimum residual burn budget waits for later fees.

`afterInitialize` is non-reverting for authorized manager calls, including
non-native or subsequent pools. Calls from any other address revert as required
by callback authorization. For receipt decoding, the burial events are
`SeatBuried(address indexed owner)`, `CreatorPaid(uint256 amount)`, and
`Manifesto(uint256 indexed seatId, bytes32 indexed manifestoHash, string manifesto)`.
