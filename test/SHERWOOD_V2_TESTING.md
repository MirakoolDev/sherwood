# Sherwood v2 independent tests

Run `forge build` and `forge test`. No new dependencies or configuration changes are needed.

The existing fork suites now skip unless `SHERWOOD_FORK_RPC_URL` is explicitly supplied. To rehearse
against Robinhood Chain, run `SHERWOOD_FORK_RPC_URL='<RPC URL>' forge test --match-contract Fork`.
No live fork was run for this contribution. The actual PFWA holder hook, Dice provider, deployed
pool liquidity, and the launcher's gas at the eventual factory address still need that rehearsal.

## Added coverage

- `SherwoodV2Accounting.t.sol`: actual ETH and token balances across real v4 swaps; one-wei and fee
  rounding boundaries; total rollback of a partially filled game buy, including Dice state and
  charges; partial fills of both buybacks; missing liquidity; slippage rollback; batched settlement
  equivalence with partial holdings and referrals; claim/sweep deadline exclusivity; access control.
- `SherwoodV2BuybackHook.t.sol`: both burns through a local dynamic-fee v4 pool whose hook takes
  specified ETH and unspecified token deltas. Minimum output is checked against net tokens actually
  burned, and failed slippage rolls back external hook fees. This is an adversarial integration
  stand-in, not a replica or verification of the live PFWA holder hook.
- `SherwoodV2Lifecycle.t.sol`: Dice fee-lookup/request failure, fee-cap and insufficient-pot cases,
  concurrent flips resolved out of order, duplicate/unknown/late callbacks, exact expiry recovery,
  refund accounting, settlement recovery, exact charge boundaries and fractional recharge,
  referral transfer failure and reentry into all three guarded withdrawal functions.
- `SherwoodV2Launcher.t.sol`: onchain salt mining and real CREATE2 deployment from a local factory
  with the brief's fixed dependency addresses and an explicit test owner, on an empty chain with
  chain ID 4663. Checks the published salt/address, permissions, constructor wiring, runtime/init
  code sizes, and separation between factory and owner. It does not assume deployment fits a
  universal 10M gas ceiling: salt-search cost depends on the factory address and init code.

Each stateless fuzz property runs 1,000 examples using inline Foundry configuration, except the
big-board rescan property, which builds 1,501 players per example and runs 6.

## Stateful properties

`SherwoodV2Invariant.t.sol` uses six actors, the real v4 PoolManager, ordinary local ERC20s, and a
controlled Dice transport. The handler randomly buys with all five moves, sells, transfers game or
host holdings, funds current/future pots, advances time, changes Dice availability/fees, reveals or
expires requests, settles in batches, claims prizes/referrals, sweeps, refunds, and executes both burns.
The suite runs 256 sequences of depth 96, with unexpected reverts treated as failures.

The following properties are checked after every handler call:

1. ETH equals all unsettled pots, unpaid prizes, referral balances, and both burn reserves. Settled
   pot mappings are historical totals and are not counted a second time.
2. An independent ledger of seed deposits, swap fees, Dice payments/refunds, payouts and burns
   reconciles to ETH held; total outflows never exceed inflows.
3. Settled rankings, scores, prize amounts, holding requirements, and deadlines never change.
4. Final rankings match positive scores, the King maximizes recorded reign time with the score
   tiebreak, and reign seconds do not overlap.
5. Pending-flip counters equal the actual live requests, each still unresolved at Dice.
6. Charge counts and next-recharge times agree with their caps and intervals; on the small board,
   no player outranks the active reign holder.

The handler never funds the hook, manager, or Dice with `deal`, never changes production storage,
and never swallows unexpected failures. A deterministic handler exercise checks that claims,
referrals, both burn paths, expiry, reveal, refund, selling and sweeping are reachable. Normal funding
is modeled; forced ETH transfers are outside this exact-liability equality. Refund eligibility is
controlled by the local Dice transport, not a claim about the live provider's refund delay.

## Revision 2: the resumable rescan (finding de3202be)

The implementation's revision 2 replaced the marker-at-settlement rule with a rescan that resumes
across transactions: once #1 is unknown (a debit of the cached #1 on a board above 1,500 players, or a
lost flip by #1 on a board above 12), every play, sell and flip expiry first rescans at least 200
players, as many more as its gas allows, and credits the #1 it finds back to the start of the open
spell, which every point change restarts. Nineteen constants became `internal` to fit the change
under EIP-170; the fixture and handler pin their README values as literals, so a silent change fails
the suite. `SherwoodV2UnknownReign.t.sol` was rewritten for this design and covers what the
implementation's own tests (`SherwoodV2LargeBoardKing.t.sol`, play-driven chunks) do not:

- a debit of #1 on a 1,501-player board leaves #1 unknown, the debited player keeps exactly the
  seconds held, the marker never banks seconds and never wins a slot, and the next play with gas to
  spare credits the new #1 back to the debit with no overlap and no gap;
- the two other resume entry points: a sell by a scored player rescans before its own wipe (and a
  tight-budget sell only covers one chunk), a flip expiry rescans before it credits the stake, and a
  sell by a player with no points neither resumes nor restarts the spell;
- a Dice loss by the running best mid-rescan (through the 200k callback, cold storage) resets the
  cursor: the board needs eight more chunks, and the new #1 is credited from the last point change;
- across repeated unknown spells every second of the round is credited exactly once and the King is
  the longest observed at #1, with `kingReign == reignOf(king)`;
- a fuzzed property (six 1,501-player boards with contenders at random sizes and random gas budgets
  between one chunk and the whole board) checks that the completed rescan always lands on the player
  with the most points;
- the deferred Dice rescan on 13 players resolved by a sell, credited back to the reveal; an expired
  flip of #1 leaves no marker; an open spell does not leak into the next round; a 1,500-player board
  is still rescanned inside the debiting swap.

Times in that file are derived from `GENESIS`, never from a cached `block.timestamp`: under via-IR
the compiler re-reads the opcode at each use, so a cached value moves with every `vm.warp`.
`SherwoodV2Lifecycle.t.sol`'s Dice-fee test now drives the new per-buy fee bound at its boundary
(fee equal to the buy's 5% flips, one wei more scores as a buy); the pot-short branch it used to
reach is unreachable since that bound.

## Revision 5 (this launch): edges and a second invariant trajectory

`SherwoodV2Edges.t.sol` (21 tests, real PoolManager through the shared fixture) pins what the suite
above did not: the zero and the empty, the same call twice, odd hook data and the last second of a round.

- Settlement: a zero batch makes no progress and never reverts; an empty round settles (even with a
  zero batch) into the two burns and an 83% rollover with nothing to claim or sweep; the rollover lands
  in the round live at settlement, not the next one; settling the live round, one second early, or an
  impossible round number reverts; claims, sweeps and referral claims for rounds that never settled
  revert; a second claim reverts and a sweep after a full claim moves nothing.
- Burns: the reserve clamps the amount (a request of ten times the reserve spends exactly the
  reserve and leaves the other reserve alone) and an empty reserve cannot burn.
- Hook data: 33, 63 and 20 bytes decode the move word and ignore the rest; 64 bytes with an unknown
  move keep the referrer (and the welcome bonus) and play as a Buy.
- Moves: Robin Hood by the leader plays as a Buy and keeps its charge; a Steal from a previous player
  wiped to zero spends its charge and moves nothing; a shield raised ten minutes before the round's
  end still reflects a Steal five minutes into the next round, with the holder bonus on the defender.
- Flips at the boundary: a flip in the last second of a round expires exactly at
  `requestedAt + 10 min`, before settlement opens, scores as a buy in its own round, starts no reign
  (no King), and a second expiry, an unknown sequence or a late reveal change nothing.
- `kingOfTheHill` as an oracle: the open-round view, the closing-time view and the settled King agree.
- Fuzzed properties (200 to 300 runs each, inline config): every wei of a settled pot lands in exactly
  one of prizes, the referral cut, the two reserves and the rollover, with fuzzed partial sales by all
  three winners and a referred #1 who is also King, through claims, a referral claim and the sweep;
  buy points, fee and `bought` follow the ETH in from one wei up; Steal charges never exceed 18, a landed
  Steal spends exactly one and a Steal with none plays as a Buy, with `nextCharges` in step; Robin Hood
  charges land on the hour from the spend up to three; a shield charge appears exactly when the round's
  cumulative play crosses a 0.025 ETH mark and a SHIELD spends it; Steals, Robin Hoods and reflects
  are zero-sum over any sequence of plays; `fundPot` takes exactly the current round through 365 ahead.

`SherwoodV2FreshBoardInvariant.t.sol` runs the existing six-actor handler from a different start (no
settled round, the Dice fee at its cap, a reflected Robin Hood that left a player below zero and a
flip pending) for 128 sequences of depth 64 with reverts failing the run, and checks after every call
that ETH held equals every obligation and never exceeds what came in, that the reign holder of the live
round is the cached #1 with the most points (and #1 is never unknown on a six-player board), and that
settled rounds keep seven days to claim, hold no pending flips and award no prize above its share or to
a player at or below zero.

Harness notes: under via-IR a `block.timestamp` cached before `vm.warp` moves with the warp, so the
new tests read `vm.getBlockTimestamp()` or derive times from `GENESIS`; and a `vm.expectRevert` must
not be followed by a view call used as an argument (the view is the "next call").

No defect was found in this revision: every property above holds on the code as it is, and the three
failures seen while writing them were harness mistakes (a cached timestamp, an argument view call under
`expectRevert`, and a sanity check that forgot the rollover). No fork run was made in this revision;
the live rehearsal in `SherwoodV2LauncherFork.t.sol` is still owed before deployment.

## Reported, not asserted

When a round ends while #1 is unknown, `settle` drops the whole final spell: it does not credit the
`top[0]` it has just computed, although no points changed after the spell began. On a 13-player board
where #1's lost flip is the last point change, the player who held #1 for the remaining 19 hours gets
no reign and the previous #1 is crowned King for one hour. The proof (fails now, passes with a
one-block fix in `settle` that was verified locally and reverted) is in `.imd-findings.json`, with
three smaller notes: every restart on a big board costs the eventual #1 the seconds since the previous
restart (documented design), `reignOf(round, address(1))` shows the open spell, and the
`pot < diceFee` branch is now dead. The six-actor invariant campaign never reaches the big-board or
the 13-player-callback branch. Production code was not modified.
