# Sherwood

A daily leaderboard game on a Uniswap v4 hook, on Robinhood Chain (chain ID 4663). Every move is a buy of
$PFWA in one ETH/$PFWA pool; the hook keeps the score, the pot and the payouts onchain. The whole game is
one contract: [`src/Sherwood.sol`](src/Sherwood.sol).

- Site: https://sherwood.pfwa.fun
- Rules for agents: https://sherwood.pfwa.fun/llms.txt
- Part of PFWA: https://pfwa.fun

## Rules

- **Moves** travel as hook data: `abi.encode(uint256 move)` or `abi.encode(uint256 move, address referrer)`.
  0 Buy, 1 Steal, 2 Robin Hood, 3 Flip. A swap with no hook data scores as Buy.
- **Points**: 1 per 0.001 ETH of an exact-input ETH→$PFWA swap, at most 100 per buy (0.1 ETH). Buys under
  0.001 ETH don't score. Points are `int256` and can go negative. A buy must fill completely: one stopped early
  by a price limit reverts (`PartialFill`).
- **Steal**: also moves 20% → 40% of the previous player's positive points to the buyer.
- **Robin Hood**: moves 10% → 33% of the leader's positive points to the lowest of the last 10 players, which can
  be the player making the move.
- **Flip**: requests randomness from Dice Protocol (a Pyth Entropy fork). Win: 2x → 3x the buy's points.
  Lose: the points are debited from the player and credited to the previous player. If Dice refuses the request
  or can't quote a fee, or the fee is above `MAX_DICE_FEE` (0.0005 ETH), the move scores as a Buy. An unrevealed
  flip can be expired after 10 minutes. A win's multiplier is fixed from the buy size when the flip is requested.
- Steal, Robin Hood and the flip win scale linearly with the buy's base points (`scaledBps`).
- **Pot**: 5% of the ETH side of every buy and sell in the pool. Anyone can add ETH with `fundPot(day)`, and ETH
  sent to the hook from anywhere other than the PoolManager or Dice lands in today's pot.
- **Day**: `block.timestamp / 1 days`. After 00:00 UTC + 15 minutes, anyone can `settle(day, maxPlayers)` in
  batches, once none of that day's flips is pending (`pendingFlips`; expire them first). Top 3 players with positive points take 50% / 20% / 10%; 10% goes to the buyback reserve (bought and
  burned through a separate holder pool by the operator); the rest rolls into the current day's pot.
- **Holding rules**: the hook records the $PFWA each player buys per day (`bought`). A winner whose balance is
  below that day's buys at settlement keeps only `prize * balance / bought` and forfeits the rest into the next
  pot (sold 20%, lose 20%). The balance kept is recorded (`heldToClaim`), and `claim` reverts while the winner
  holds less than that. Holding all of yesterday's buys gives +25% points today (`holderBonusActive`).
- **Selling** $PFWA in this pool wipes the seller's positive points for the day.
- **Referrals**: a player's referrer is set once, on their very first play, from hook data. Not self, not
  mutual. A referred player gets +10% points on their first day. On days the referrer also played: +10% of the
  player's scored points to the referrer (minted, not taken), and 5% of the player's prize to
  `referralEarnings` (taken from the rollover, not the prize), withdrawn with `claimReferral()`.
- **Claims**: winners `claim(day)` until `claimDeadline(day)`: 7 days from the day's end or from settlement,
  whichever is later. Anyone can `sweepUnclaimed(day)` back into the pot after that.

## Roles and trust

| Role | Can | Cannot |
| --- | --- | --- |
| Owner | `setOwner`, `setOperator`; set the buyback pool (once) and create the game pool (once) | Touch the pot, points, prizes, referral earnings or rules; change the buyback pool |
| Operator (and owner) | `buybackAndBurn(amount, minPfwaOut)` from the buyback reserve; `refundDiceRequest` | Send reserve ETH anywhere but the buyback swap in the pool set at launch; $PFWA bought goes to the dead address. `minPfwaOut` is the operator's choice (the upkeep job uses a live quote) |
| Anyone | Trade, `settle`, `sweepUnclaimed`, `fundPot`, `expireFlip` (after 10 minutes), add liquidity | — |

Rules are constants; there is no upgrade path.

## External dependencies

- Uniswap v4 PoolManager on Robinhood Chain `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- Dice Protocol entropy `0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c`, provider `0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6`.
- $PFWA `0xa934bA4F59070149d37A93F8A002Af79BAe35563` (standard ERC-20).
- The buyback pool: the $PFWA holder pool, an existing ETH/$PFWA pool with another hook, set once at launch. If it
  ever stops working, the buyback reserve stays in the contract.

## Deployment

The hook is deployed with CREATE2 to an address carrying its permission bits (beforeInitialize, beforeSwap,
afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta). Planned through Programmable's atomic executor: the
constructor owner is the executor, which sets the buyback pool and operator, creates the pool and hands
ownership to the admin wallet in one transaction. $PFWA liquidity is then added one-sided by the admin wallet.

## Known design choices (accepted)

- The player is `tx.origin`. Smart-account bundles credit the bundler.
- Holding checks read `balanceOf`, so moving tokens between wallets can dodge them; they raise the cost of
  dumping, they don't make it impossible.
- Referral by a second wallet you control is possible; it only earns the 10% bonus points on days you play and
  5% of a prize from the rollover.
- The leader is tracked incrementally. A rescan of up to `MAX_LEADER_SCAN` players runs inside the swap that debited #1; a bigger board is rescanned in resumable chunks by the swaps that follow (see King of the Hill under Sherwood v2).
- Robin Hood can pay the player making the move when they're the lowest of the last 10: robbing the leader for
  yourself is allowed, so moves can be chained.
- Liquidity is one-sided $PFWA, so the pool price can't fall below its starting price.

## Audit

Audited by IMD at `1266778`: 1 high, 3 medium, 4 low and 1 info. All fixed except one accepted design choice.
See [AUDIT.md](AUDIT.md).

## Where we'd like the most scrutiny

1. Delta accounting in `beforeSwap` / `afterSwap` (fee take, return deltas, exact-input only) and the
   `unlockCallback` buyback path.
2. Pot and prize accounting across `settle`, `claim`, `sweepUnclaimed`, partial forfeits, referral shares and
   `claimReferral`: total ETH paid out can never exceed ETH received.
3. Flip lifecycle: request, callback, expiry, refunds, and the Dice fee taken from the pot.
4. Points bookkeeping with negative scores, leader tracking, the last-10 list and settlement batching.
5. Anything a player, a griefer or the operator could use to block swaps, settlement or claims.

## Build and test

Foundry with solc 0.8.26 (via IR, cancun). Dependencies are vendored in `lib/`.

```
forge build
forge test --no-match-contract Fork              # 67 unit tests
forge test --match-contract Fork                 # 3 tests against live Robinhood Chain state (needs the public RPC)
```

## License

MIT

## Sherwood v2

[`src/SherwoodV2.sol`](src/SherwoodV2.sol) is the next version of the game, and it works with any token. Its first deployment is for $IMD, with $PFWA as the host token. The v1 game above keeps running unchanged.

### What changed from v1

- **Rounds:** rolling 20-hour rounds from `GENESIS` replace fixed UTC days, so the end of each round falls at a different hour every day.
- **Moves:** 0 Buy, 1 Steal, 2 Robin Hood, 3 Flip, 4 Shield. Steal, Robin Hood and Flip use charges that stack:

  | Move | Earn rate | Most you can bank |
  |---|---|---|
  | Steal | 1 every 10 minutes | 18 |
  | Robin Hood | 1 every hour | 3 |
  | Flip | 1 every 6h40m (3 a round) | 6 |

  Banks are kept per wallet and carry across rounds. A new wallet starts with a full bank. A move with no charge left plays as a Buy.
- **Shield:** every 0.025 ETH played in a round earns one charge, and a player holds at most one. Playing Shield raises a 30-minute shield. The next Steal or Robin Hood aimed at the shielded player is reflected, and the attacker pays the whole cut the move would have taken, below zero if need be (like a lost flip). A move that would have taken nothing reflects nothing and leaves the shield up.
- **King of the Hill:** the player who held #1 for the longest in a round wins 8%. When #1 loses points the board is rescanned for the new #1:
  - Up to `MAX_LEADER_SCAN` (1,500) players, the move that debited #1 rescans the whole board at once (about 4.7k gas per player with cold storage: up to about 7.1M).
  - On a bigger board, or when #1 loses a flip (Dice's reveal only has `FLIP_CALLBACK_GAS`, 200k, enough to rescan 12 players), #1 is unknown until the next play, sell or flip expiry rescans the board. Such a transaction rescans at least `LEADER_SCAN_CHUNK` (200) players, about 950k gas, and as many more as its gas allows while keeping `LEADER_SCAN_RESERVE` (1M) for the rest of the swap, so a caller who gives the swap gas to spare finishes a big board in one go; otherwise the following transactions carry on from where it stopped.
  - While #1 is unknown nobody's clock runs and Robin Hood scores as a Buy and keeps its charge. Every point change restarts the unknown spell, so when the rescan completes the #1 it finds has held #1 for the whole spell and is credited back to its start. Seconds nobody is credited for go to nobody; the King is decided only by seconds actually observed at #1.
- **Steal and Robin Hood with nothing to take:** a Steal with no previous player, or a Robin Hood with no leader or no other recent player, plays as a Buy and keeps its charge. A Steal or Robin Hood whose target exists but has no points above zero spends its charge and moves nothing: the move was made, there was just nothing to take.
- **Split:**

  | Share | Goes to |
  |---|---|
  | 40% / 20% / 10% | Top 3 |
  | 8% | King of the Hill |
  | 10% | Game token burn, through `buybackPool` |
  | 7% | Host token burn, through `hostBuybackPool` |
  | 5% | Rollover |

  Empty prize slots roll over. Referral cuts come out of the rollover: at most 5% × 78% = 3.9% < 5%.
- **Host token:** a game for another token buys and burns the host token ($PFWA) with its 7%. Holding at least `hostHolderMin` of the host token gives +10% points. When the host token is the game token, both features are off and the 7% joins the game token burn.
- **Claims:** prizes are claimed within 7 days. `sweepUnclaimed` moves anything left into the pot of the live round.
- **Hook data:** `abi.encode(uint256 move)` or `abi.encode(uint256 move, address referrer)`. A move above 4 plays as a Buy; a referrer word that isn't a clean address is ignored. A swap never reverts over its hook data.
- **Flips and the Dice fee:** the fee comes out of the pot. A flip only goes to Dice when the fee is at most `MAX_DICE_FEE` and at most the 5% its own buy paid in (so a flip never costs the pot more than the buy brought); otherwise the move scores as a Buy and keeps its charge.
- **Seeding:** `fundPot(round)` takes the current round and up to 365 rounds ahead, so every seed can be settled out.

### Deploying without a salt

A v4 hook needs its permission flags (`0x20CC`) in the low bits of its address. [`src/SherwoodV2Launcher.sol`](src/SherwoodV2Launcher.sol) is for factories that can't pass a CREATE2 salt. In its constructor it searches salts onchain and deploys the hook with CREATE2. That takes about 16k tries on average, and the whole deploy costs about 10M gas. Read the result from `launcher.hook()`.

[`test/SherwoodV2LauncherFork.t.sol`](test/SherwoodV2LauncherFork.t.sol) rehearses the whole $IMD launch on a Robinhood Chain fork: deploy, owner setup, a play, settlement and both burns.

The changes made for the $IMD launch, and the audit findings behind them, are listed in [ADAPTATION.md](ADAPTATION.md).

### Owner setup after deploy

[`script/SetupSherwoodV2.s.sol`](script/SetupSherwoodV2.s.sol) runs these steps as the owner:

1. Create the ETH/$IMD game pool: fee 9000, tick spacing 180, hooks set to the hook, at the 1% pool's price.
2. `setOperator(bot)`.
3. `setBuybackPool(ETH/$IMD 1%)`.
4. `setHostBuybackPool(ETH/$PFWA holder pool)`.

### Where we would like the most scrutiny (v2)

- **The two buyback swaps:** they share one `unlockCallback`, with a flag saying which burn it is. Slippage protection relies only on the operator's `minOut`.
- **Pot accounting:** settlement must never revert, and ETH out can never exceed ETH in, across prizes, referral cuts, claims and sweeps.
- **Charge clocks:** `_charges`, `_spend` and `_nextCharge`.
- **King of the Hill reign tracking:** `_updateReign` and the bounded leader rescan.
- **Host bonus:** it reads the balance at play time, so a player could borrow 100k $PFWA for one transaction. The edge is 10% of points, and the swap fees for borrowing it by buying and selling cost more.
