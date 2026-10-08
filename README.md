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
  0.001 ETH don't score. Points are `int256` and can go negative.
- **Steal**: also moves 20% → 40% of the previous player's positive points to the buyer.
- **Robin Hood**: moves 10% → 33% of the leader's positive points to the lowest of the last 10 players.
- **Flip**: requests randomness from Dice Protocol (a Pyth Entropy fork). Win: 2x → 3x the buy's points.
  Lose: the points are debited from the player and credited to the previous player. If Dice refuses the request
  or can't quote a fee, the move scores as a Buy. An unrevealed flip can be expired after 10 minutes.
- Steal, Robin Hood and the flip win scale linearly with the buy's base points (`scaledBps`).
- **Pot**: 5% of the ETH side of every buy and sell in the pool. Anyone can add ETH with `fundPot(day)`, and ETH
  sent to the hook from anywhere other than the PoolManager or Dice lands in today's pot.
- **Day**: `block.timestamp / 1 days`. After 00:00 UTC + 15 minutes, anyone can `settle(day, maxPlayers)` in
  batches. Top 3 players with positive points take 50% / 20% / 10%; 10% goes to the buyback reserve (bought and
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
- **Claims**: winners `claim(day)` within 7 days; anyone can `sweepUnclaimed(day)` back into the pot after that.

## Roles and trust

| Role | Can | Cannot |
| --- | --- | --- |
| Owner | `setOwner`, `setOperator`, `setBuybackPool`; create the game pool (once) | Touch the pot, points, prizes, referral earnings or rules |
| Operator (and owner) | `buybackAndBurn(amount, minPfwaOut)` from the buyback reserve; `refundDiceRequest` | Send reserve ETH anywhere but the buyback swap; $PFWA bought goes to the dead address |
| Anyone | Trade, `settle`, `sweepUnclaimed`, `fundPot`, `expireFlip` (after 10 minutes), add liquidity | — |

Rules are constants; there is no upgrade path.

## External dependencies

- Uniswap v4 PoolManager on Robinhood Chain `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- Dice Protocol entropy `0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c`, provider `0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6`.
- $PFWA `0xa934bA4F59070149d37A93F8A002Af79BAe35563` (standard ERC-20).
- The buyback pool: an existing ETH/$PFWA pool with another hook, set by the owner.

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
- The leader is tracked incrementally and rescanned at most `MAX_LEADER_SCAN` players inside a swap.
- Liquidity is one-sided $PFWA, so the pool price can't fall below its starting price.

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
forge test --no-match-contract Fork              # 58 unit tests
forge test --match-contract Fork                 # 3 tests against live Robinhood Chain state (needs the public RPC)
```

## License

MIT
