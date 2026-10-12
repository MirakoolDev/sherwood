# Adaptation for the $IMD launch on Robinhood Chain (4663)

The launch deploys one contract, `src/SherwoodV2Launcher.sol:SherwoodV2Launcher`, whose constructor mines
a CREATE2 salt and deploys the `SherwoodV2` hook at an address carrying the hook flags (`0x20CC`). The
hook is `launcher.hook()`. Constructor arguments, in order: poolManager, token ($IMD), host ($PFWA),
hostHolderMin, dice, diceProvider, owner (`$owner`), genesis. The launcher already met the launch rules
as it arrived (nonpayable constructor, static argument types, 8 of at most 16 arguments, an explicit
owner argument, no call to any other contract in either constructor, no proxy, no DELEGATECALL,
CALLCODE or SELFDESTRUCT, no minting, pausing or seizing). No change was needed to it, to the game
rules or to the pot split. The changes below are the fixes for the imported audits: revisions 1 to 3 for
launch 1355's audit, and revision 4 (at the end of this file) for the audit of this launch, which fixed
both burn pools in the hook at deployment and made the owner handover two-step.

## Changes

| # | File | Change | Why |
|---|---|---|---|
| 1 | `src/SherwoodV2.sol` (`_entropyCallback`, new `MAX_CALLBACK_SCAN`, `_updateReign` split into `_updateReign` + `_setReign`) | After a lost flip by the cached leader, the Dice callback no longer rescans a board of more than `MAX_CALLBACK_SCAN` (12) players. On a bigger board it closes the current reign at the reveal (holder set to nobody, time so far credited) and leaves the leader cache stale; the next play, sell or expiry rescans with its caller's gas and starts the new reign from then. Boards of up to 12 players are still rescanned inside the callback. | Audit high `490703de…` reproduced: the judge's proof test fails on the code as it arrived (callback used 207,203 gas against the 200,000 `FLIP_CALLBACK_GAS` limit with 200 players) and passes after the fix (109,369 gas). Without it the leader's lost flip was never applied and `expireFlip` refunded the stake. |
| 2 | `src/SherwoodV2.sol` (`_reflect`) | A reflected Steal or Robin Hood now charges the attacker the whole cut the move would have taken, even below zero (as a lost flip does), instead of capping it at the attacker's positive points. A move that would have taken nothing reflects nothing and leaves the shield up. | Audit low `3e2286a2…` reproduced: a fresh wallet with 1 point stripped a shield for one point, and a zero-point Steal stripped it for nothing. The README rule ("the next Steal or Robin Hood aimed at the shielded player is reflected, and the attacker pays") is kept: the shield still breaks on the first attack that it reflects, and the attacker always pays the full price. |
| 3 | `test/SherwoodV2.t.sol` | `MockDiceV2.reveal` now gives the callback exactly the gas limit the request asked for and fails if the callback fails, as Dice does; `tryReveal` reports the outcome and gas. New tests: `test_leaderLostFlipCallbackFitsDiceGasLimitOnABigBoard`, `test_leaderLostFlipRescansASmallBoardInsideTheCallback`, `test_leaderLostFlipDefersTheRescanJustPastTheBound`, `test_otherFlipOutcomesFitDiceGasLimitOnABigBoard`, `test_throwawayWalletPaysTheFullCutToBreakAShield`, `test_stealThatTakesNothingLeavesTheShieldUp`. The two tests that encoded the capped reflect (`test_reflectedStealCappedAtAttackersPoints`, `test_reflectedRobinHoodCappedAtRobbersPoints`) became `…TakesTheFullCutBelowZero` with the new expected points. | Every change is tested; every flip test now runs the callback under the real gas budget. |
| 4 | `README.md` (Sherwood v2 section) | Documents the full-price reflect and the deferred rescan after a leader's lost flip. | Keeps the requester's notes in step with the rules. |

## Audit findings

| Finding | Status |
|---|---|
| High `490703de…` Dice callback runs out of gas when #1 loses a flip | Reproduced and fixed (change 1). The proof test `test_leaderLostFlipCallbackMustFitDiceGasLimit` fails before and passes after. Measured with cold storage under the 200k limit: leader loss on 202 players 109,458 gas (deferred), on 13 players 89,558 (deferred), on 12 players 163,526 (rescanned), non-leader loss 76,324, win taking #1 79,214. `FLIP_CALLBACK_GAS` stays at 200,000, the provider's default, so no reliance on Dice honouring larger limits. |
| Low `3e2286a2…` a shield is consumed by a reflect that pays nothing | Reproduced and fixed (change 2). |
| Info `4ccb2af0…` 444 bytes of runtime margin | Taken into account at every revision; current sizes are under "Revision 2: Bytecode" below. The launcher's CREATE2 still succeeds. |
| Info `8e069730…` a debit of the cached leader rescans up to 1,500 players inside the swap | Accepted design, unchanged up to 1,500 players. The fix for the high finding does not move this rescan into the Dice callback. For the frontend: a move that debits #1 (a Steal of #1, a Robin Hood, a reflect paid by #1, a sell by #1, an expired flip of #1) costs about 4.7k gas per player of the round with cold storage (measured), about 7.1M gas at 1,500 players. Above 1,500 see revision 2. |

## Behaviour note on the high fix

Between a Dice reveal that costs #1 the lead on a board of more than 12 players and the next play, sell or
flip expiry of that round, #1 is unknown. The old #1 is credited up to the reveal; the next transaction
rescans the board and (revision 2) credits the new #1 back to the reveal, since nothing changed in between.
Rescanning in the callback is exactly what Dice's gas limit forbids. Nothing else about reign tracking
changed for boards of up to 1,500 players.

## Checks run

- `forge build` (solc 0.8.26, via IR, cancun, `bytecode_hash = "none"`), `forge build --sizes`.
- `forge test --no-match-contract Fork`: see the counts under each revision.
- `forge test --match-contract Fork` against the public Robinhood Chain RPC: the launcher rehearsal
  `test/SherwoodV2LauncherFork.t.sol` deploys the launcher with the launch's arguments, then does the
  owner setup, a play, settlement and both burns (see the run notes at the end of this file).
- The protected harness check (`.imd/reads/protected/evm_contracts/Contracts.protected.t.sol`) wants
  the deployed runtime under 24,576 bytes with no DELEGATECALL, CALLCODE or SELFDESTRUCT: the launcher's
  runtime is 183 bytes and the hook contains none of those opcodes (its constructor only runs
  `Hooks.validateHookPermissions`, an internal library function).

## Reviewed and left as they are

The focus areas in the brief were read against the code and the tests; nothing else reproduced as a defect.

- Swap deltas: a buy takes the 5% fee in `beforeSwap` with a positive specified delta, so the swapper
  always pays exactly `amountSpecified`; `afterSwap` reverts a partial fill. A sell takes 5% of the ETH
  out through the unspecified delta. The buyback `unlockCallback` settles exactly the ETH the pool took
  (`ethPaid` can only be less than `amount`, never more, for an exact-input swap) and returns the rest
  to the right reserve; `minOut` is the operator's slippage guard.
- Pot and prize accounting: every wei received lands in exactly one of pot, buyback reserve, host
  reserve, an unclaimed prize or referral earnings; settlement awards at most 78% in prizes plus 3.9% in
  referral cuts plus 17% in burns of a pot, so the rollover never underflows and settlement cannot revert
  on arithmetic. Claims are pull-based and guarded; sweeps move unclaimed prizes into the live pot.
- Flip lifecycle: the Dice fee comes out of the pot before the request, a refused request plays as a
  buy, an unrevealed flip expires as a buy after 10 minutes, settlement waits for pending flips, and a
  reveal after settlement is dropped. With change 1 every callback path fits the gas limit.
- Charge clocks: `_charges`, `_spend` and `_nextCharge` never underflow (a clock never passes
  `block.timestamp`) and cap at the bank size.
- King of the Hill: reigns close at the round's end and are finalized once at settlement.

## Open items for the deployer

- The launcher's constructor costs about 10M gas (salt search plus the hook deployment); the gas ceiling
  of the deployment service must allow it. About 1 launch in 400 needs more than 100k tries (about 9M
  gas for the search alone), as the audit noted.
- After deployment the owner (`0x420944b441715e34dd672ae0eb4526a7ad7d1eef`) runs the setup in
  `script/SetupSherwoodV2.s.sol`: create the ETH/$IMD game pool and `setOperator`. Since revision 4 the
  two burn pools (the ETH/$IMD 1% pool and the $PFWA holder pool) are fixed in the hook at deployment
  and need no setup call.

## Revision 1: King of the Hill on boards above MAX_LEADER_SCAN (finding 5643a8ad, high)

Superseded by revision 2 below. It made `_currentLeader` return the marker `UNKNOWN_REIGN` (address(1))
on a stale board of more than `MAX_LEADER_SCAN` players, parked the reign on the marker and, at the end of
settlement, handed the marker's seconds to the round's final #1. The reviewer showed that this only moved
the misallocation (finding de3202be): the final #1 collected every second since the first debit of #1.

## Revision 2: the rescan resumes across transactions (finding de3202be, high)

### Change

`src/SherwoodV2.sol`, leader tracking (`_debit`, `_currentLeader`, new `_resumeScan` and `_scan`, `_setReign`,
`settle`; `_crownUnknownReign` removed; new storage `_scanCursor`; new constants `LEADER_SCAN_CHUNK` = 200 and
`LEADER_SCAN_RESERVE` = 1M gas):

- Up to `MAX_LEADER_SCAN` (1,500) players nothing changed: the move that debits #1 rescans the whole board.
- On a bigger board the move leaves #1 unknown (`UNKNOWN_REIGN`), as before, but now every following play,
  sell and flip expiry calls `_resumeScan` first, before it changes any points. It rescans from the saved
  cursor over at least `LEADER_SCAN_CHUNK` players and then as far as the transaction's gas allows while
  keeping `LEADER_SCAN_RESERVE` for the rest of the swap. If the board is done, `_leaderStale` is cleared
  and `_setReign` installs the #1 found; if not, the cursor is saved and #1 stays unknown. Comparisons run
  against the cache, which `_credit` keeps at the best seen so far; a debit of that player resets the
  cursor, so the rescan can never settle on a player who lost points mid-way.
- `_setReign`: while #1 is unknown every point change restarts the unknown spell (`since` moves to now). When
  a rescan resolves it, nothing has changed since `since`, so the #1 found has held #1 for the whole spell
  and is credited from `since`. Seconds nobody is credited for go to nobody: the marker never accumulates
  seconds, `settle` ignores it, and `kingReign` now always equals `reignOf(round, king)`.
- The Dice callback is unchanged (it never rescans more than 12 players), but the next transaction now
  credits the new #1 back to the reveal instead of starting their clock from itself.
- Robin Hood while #1 is unknown still scores as a Buy and keeps its charge, but the unknown spell now lasts
  until the next transaction with gas to spare, or a handful of plays (8 at 200 a play for 1,501 players),
  not the rest of the round.

Why: the proof `Proof_de3202be6be8.t.sol` fails on the previous code (dave, #1 for the last hour, was crowned
with 19 hours; bob, #1 for 18 hours, got nothing) and passes now (bob is King with exactly 18 hours).

### Bytecode

The change needed about 550 B. Nineteen public constants that nothing outside the contract reads (`FEE_BPS`,
`MIN_BUY`, `POINT_UNIT`, `MAX_POINTS_PER_BUY`, `HOLDER_BONUS_BPS`, `REFERRAL_POINTS_BPS`, `WELCOME_BONUS_BPS`,
`RECENT`, `CLAIM_WINDOW`, `FLIP_TIMEOUT`, `MAX_DICE_FEE`, `SHIELD_CHARGE_ETH`, `SHIELD_DURATION`, the six
`*_RECHARGE` / `*_MAX_CHARGES`) became `internal`, as the reviewer suggested; their values are in the README.
Every constant a test, script or proof reads stays public. `forge build --sizes`: `SherwoodV2` runtime
24,549 B, 27 B under EIP-170; launcher init code 26,324 B plus 256 B of arguments, under the harness's 49,152.

### Advisory findings fixed with the freed room

| Finding | Change | Test |
|---|---|---|
| Low `7e27cd8e` dirty referrer word reverts the first swap | `_play` decodes the second word as `uint256` and takes it as the referrer only if it fits an address; otherwise no referrer. | `test_dirtyReferrerWordIsIgnoredNotAReasonToRevert` |
| Low `a5625232` a flip's Dice fee bounded only by `MAX_DICE_FEE` | `_requestFlip` also requires `diceFee <= ethIn * FEE_BPS / 10_000`, else the move scores as a Buy (no charge spent). No effect at today's fee: 0.000025 ETH is under the 0.00005 ETH a minimum buy pays in. | `test_flipScoresAsBuyWhenDiceFeeExceedsTheBuysPotShare` |
| Low `af004953` `settle(round, type(uint256).max)` overflows | The batch end is clamped before the addition. | `test_settleAllRemainingWithMax` |
| Low `404b46d7` `fundPot` for an unreachable round strands ETH | `fundPot` rejects rounds more than `MAX_SEED_AHEAD` (365) ahead with `RoundPassed`. | `test_fundPotRejectsRoundsTooFarAhead` |

Left as they are: the set-once buyback pools without an initialisation check (owner trust; the setup script
uses the known keys; the check needs `StateLibrary`, more than the remaining 27 B), the buyback events
emitting the requested amount, the documented trust assumptions, and the charge spent on a zero-point
target, which the README now documents.

### Tests

- `test/SherwoodV2UnknownReignKing.t.sol`: the reviewer's proof, with assertions that the King's reign
  equals `reignOf`, dave got his hour and alice hers.
- `test/SherwoodV2LargeBoardKing.t.sol`: the previous proof plus four tests on a 1,501-player board: the
  rescan resumes in chunks under a 1.5M gas budget and completes on the eighth play, crediting the new #1
  from the last point change; a play with gas to spare finishes it in one go (7.48M gas, cold) and credits
  back to the debit; Robin Hood keeps its charge while #1 is unknown and works again after; a debit of the
  best player found so far restarts the rescan.
- `test/SherwoodV2.t.sol`: `test_leaderLostFlipCallbackFitsDiceGasLimitOnABigBoard` now expects the new #1
  credited back to the reveal (70 s, not 10); the four low-finding tests above.

### Gas, for the frontend

A plain buy costs about 340k. The move that debits #1 on a board of up to 1,500 players pays the rescan,
about 4.7k gas per player (7.1M at 1,500). On a bigger board the move pays nothing extra; each following
play pays about 950k for its 200-player chunk until the board is done, and a wallet that lets the swap
have more gas resolves it faster (a single 30M-gas play clears 1,501 players).

### Checks run

- `forge build --sizes` (27 B margin, see above); `forge test`: 228 tests pass, 215 of the project, 3 from
  the two proofs copied to `test/scratch` (not submitted) and 10 in the fork suites against the public
  Robinhood Chain RPC (`SherwoodV2LauncherFork`, `SherwoodV2Fork`, `SherwoodFork`).

## Revision 3 (requester, after launch 1355 was parked): the final unknown spell (judge finding, high)

### Change

`settle`, on its last batch: if #1 is still unknown when the round ends (the last point change was a
debit of #1 that no later play, sell or expiry rescanned, e.g. #1's lost flip on a board of more than 12
players with no play after it), the round's final #1 (`top[0]` from the ranking settlement has just done)
is credited the spell, from its start to the round's end. Nothing changed since the spell began, so the
final #1 held #1 for all of it, which is what a finished rescan credits (revision 2). The King is then
re-decided with that player's new total, and the reign is closed on them, so `kingReign` still equals
`reignOf(round, king)`. With nobody above zero the spell goes to nobody.

### Bytecode

Nine more constants that no contract reads became `internal` (`STEAL_BPS_MIN/MAX`, `ROBIN_BPS_MIN/MAX`,
`FLIP_WIN_BPS_MIN/MAX`, `HOST_BONUS_BPS`, `REFERRAL_PRIZE_BPS`, `FLIP_CALLBACK_GAS`); the pot split
constants stay public because the site reads them. `SherwoodV2` runtime: 24,480 B (96 B under EIP-170).

### Test

`test/SherwoodV2.t.sol` `test_settleCreditsTheFinalUnknownSpellToTheFinalLeader`: alice holds #1 for an
hour, then loses a flip on a 13-player board; nobody plays again. Before the change alice is crowned
with her hour and carol, #1 for the other 19 hours, gets nothing (the test fails); after it carol is King
with exactly the spell, equal to `reignOf`, and alice keeps her hour. Full suite: 253 pass (2 skipped),
including the fork suites against the Robinhood Chain RPC.

## Revision 4 (this launch's audit of the imported code): burn pools fixed at deployment, two-step owner

The launch rules want every contract fully configured in its constructor, with the factory making no
setup calls, and the brief fixes the launcher's eight constructor arguments (so does the `launch.json`
in the tree). Both findings below are fixed inside the hook without a new argument: the burn pool keys
are fixed values of the existing pools, derived from the `token` and `host` arguments, as the launch
reference asks ("make values that never change constants, and derive what follows from other
arguments"). The launcher, the game rules and the split are unchanged.

### Changes

| # | File | Change | Why |
|---|---|---|---|
| 1 | `src/SherwoodV2.sol` (storage `buybackPool` / `hostBuybackPool`, `setBuybackPool`, `setHostBuybackPool`, `_checkBuybackPool`, `BadBuybackPool`, the two `*PoolChanged` events removed; new constants `BURN_POOL_FEE` 10000, `BURN_POOL_TICK_SPACING` 100, `HOST_POOL_FEE` 0x800000, `HOST_POOL_TICK_SPACING` 200, `HOST_POOL_HOOK` 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC; new views `buybackPool()` and `hostBuybackPool()`; `unlockCallback` reads them) | The game token's burn pool is the existing ETH/token 1% pool with no hook; the host burn pool is the ETH/$PFWA holder pool (dynamic fee, Hookr's holder hook). Both keys are built from the constructor's `token` and `host` and these constants: nobody, the owner included, can point a reserve at another pool. In the host token's own game (`host == token`) the one burn goes through the holder pool, which is what the $PFWA fork test did by hand before. The constructor still calls no contract (the empty-chain rehearsal passes), and the pools are only touched on first burn: a wrong or missing pool reverts that burn and the reserve stays. | Medium `6e8f43a0…` reproduced on the code as it arrived: the owner could set a pool whose hook takes the ETH (the audit's CaptureHook) and the burn reserve left through it. The brief names the two pools; the launch rules forbid post-deployment configuration. |
| 2 | `src/SherwoodV2.sol` (`setOwner` now records `pendingOwner` and emits `OwnerProposed`; new `acceptOwner`, new `pendingOwner` view) | A handover is two-step: `setOwner(next)` names the next owner and changes nothing; `next` takes over with `acceptOwner()`. `setOwner(0)` (or any address nobody controls) is harmless and cancels a pending handover. | Low `cf003baf…` reproduced: `setOwner(address(0))` on a fresh hook left it with no owner, so no game pool could ever be created and both reserves were dead. |
| 3 | `script/SetupSherwoodV2.s.sol` | Steps 3 and 4 (the two setters) removed; the script now checks that both fixed pools exist on the chain before creating the game pool and naming the operator. | Follows change 1. |
| 4 | `test/helpers/MockHolderHook.sol` (new), `test/helpers/SherwoodV2Fixture.sol`, `test/SherwoodV2.t.sol` setUp | The unit tests take both burn keys from the hook and etch a permissive stand-in for the holder hook at its fixed address (its address flags, 0x28CC, require `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap` and `afterSwap` to answer). `_configureBurns` is gone (nothing to configure); `_reshapeBurnLiquidity` replaces a fixed pool's liquidity with a narrow or empty position for the partial-fill and empty-pool tests that used to create their own pools. | Tests must run on the fixed keys. |
| 5 | `test/SherwoodV2LaunchConfig.t.sol` (new) | `test_burnPoolsAreTheBriefsPoolsDerivedFromTheConstructor`; `test_ownerCannotRedirectTheBurnToACapturePool` (the audit's reproduction: the capture pool exists, no setter accepts it, the burn goes through the 1% pool and the thief gets nothing); `test_ownerHandoverIsTwoStep`; `test_ownerHandoverToAWrongAddressIsHarmlessAndCancellable` (the audit's reproduction on a fresh hook: after `setOwner(0)` and a cancelled typo, the owner still creates the game pool and names the operator). | Every change is tested. |
| 6 | `test/SherwoodV2.t.sol` | `test_buybackPoolCannotBeTheGamePool`, `test_buybackPoolIsSetOnce` and `test_hostBuybackPoolIsSetOnceAndValidated` (they encoded the setters) became `test_buybackPoolIsFixedToTheOnePercentPoolWithNoSetter` and `test_hostBuybackPoolIsFixedToTheHolderPoolWithNoSetter`; the two burn tests no longer call a setter; the own-game test checks that its one burn pool is the holder pool. | Behaviour the audit changed. |
| 7 | `test/SherwoodV2BuybackHook.t.sol` | The hook-fee fuzz now etches the adversarial fee hook over the holder hook's fixed address and runs the host burn only: the game-token burn pool has no hook, so there is no outside hook there to account for. Same assertions (net deltas, atomic slippage revert, exact boundary). | Follows change 1. |
| 8 | `test/SherwoodV2Accounting.t.sol`, `test/SherwoodV2Invariant.t.sol`, `test/SherwoodV2Fork.t.sol`, `test/SherwoodV2LauncherFork.t.sol` | Setter calls removed; the fork tests assert that the fixed keys are the live 1% pool and the live holder pool and that both exist; the owner-powers test checks `acceptOwner` is refused to anyone not named. | Follows changes 1 and 2. |
| 9 | `README.md` | Roles table, external dependencies and the owner setup describe the fixed burn pools and the two-step handover. | Keeps the requester's notes in step. |

### Audit findings

| Finding | Status |
|---|---|
| Medium `6e8f43a0…` burn pools chosen by the owner after deployment | Reproduced on the code as it arrived by reading it: `_checkBuybackPool` accepted any fee, tick spacing and hook other than this one, and `unlockCallback` settled whatever `delta.amount0` the pool took, so a capture hook's pool was a valid burn pool and nothing tied the keys to the brief's pools. Fixed (change 1); tested by `test_ownerCannotRedirectTheBurnToACapturePool` (the audit's scenario on the fixed code) and the fixed-key tests. The fork rehearsal `test_forkLauncher_imdLaunchEndToEnd` burns through both live pools without any setup call. |
| Low `cf003baf…` single-step `setOwner` with no zero check | Reproduced by reading: `setOwner` wrote any address in one step, and `beforeInitialize` and both setters required the owner. Fixed (change 2); tested by `test_ownerHandoverIsTwoStep` and `test_ownerHandoverToAWrongAddressIsHarmlessAndCancellable`. |
| Info `5c06bb12…` open-ended salt mining | Not a defect in the code: the launcher is unchanged. The deployer sizes the gas ceiling for the tail, as the finding says: about 18M covers all but one draw in 500; the scratch factory rehearsal (salt 7 from a test probe) cost 6.9M. Kept under "Open items for the deployer". |

### Bytecode

Removing the two stored keys, the setters and their check freed more than the two-step owner and the two
key views cost: `SherwoodV2` runtime 23,654 B (922 B under EIP-170, from 24,480). Launcher runtime 183 B,
init code 25,436 B plus 256 B of arguments.

### Checks run

- `forge build --sizes`.
- `forge test --no-match-contract Fork`: 253 tests pass in 11 suites (the invariant suite included).
- `SHERWOOD_FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork`: 10
  pass, including the launcher rehearsal (deploy, pool creation, operator, a play, settlement, both burns
  through the live ETH/$IMD 1% pool and the live holder pool).
- A scratch copy of the protected harness (`test/scratch`, not submitted): the launcher's init code deployed
  from a factory on an empty chain with chain id 4663, the hook's address carries 0x20CC, and neither runtime
  has DELEGATECALL, CALLCODE or SELFDESTRUCT or exceeds 24,576 bytes.

### Reviewed again and left as they are

The focus areas were read once more against the changed code. The buyback `unlockCallback` is unchanged
apart from where the key comes from: it settles exactly the ETH the pool took, burns exactly the net
tokens, returns a partial fill to its own reserve and reverts whole on slippage (the fee-hook fuzz and the
accounting tests still pass on the fixed keys). Settlement, claims, sweeps, referral cuts, the flip
lifecycle, the charge clocks and the reign tracking were not touched. `setOperator` stays single-step: a
wrong operator can only run burns with their own `minOut`, and the owner names another.
