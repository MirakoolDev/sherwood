# Audit

| | |
|---|---|
| Auditor | [IMD](https://imd.fun): four specialist agents (math, permissions, economics, control flow) and a judge that reproduced, merged and ranked their findings |
| Job | [`1c006b6b-3525-4709-b840-10a20e1dd141`](https://explorer.imd.fun/jobs/1c006b6b-3525-4709-b840-10a20e1dd141) |
| Report | [report.md](https://api.imd.fun/jobs/1c006b6b-3525-4709-b840-10a20e1dd141/report.md) |
| Audited commit | `1266778edc5697cb4b13442901e27bbe569a1e22` |
| Findings | 1 high · 3 medium · 4 low · 1 info |
| Judged | 2026-10-08 11:09 UTC |

Every finding below was reproduced against the audited commit, fixed (or accepted, with the reason) in the commit
after it, and covered by a test in `test/Sherwood.t.sol`.

| # | Severity | Finding | Resolution | Test |
|---|---|---|---|---|
| 1 | High | Points, the pot fee and the flip stake came from `amountSpecified`, so a buy stopped early by a price limit scored 100 points for 0.005 ETH, received no $PFWA and escaped the holding rules | **Fixed.** `afterSwap` reverts a buy that spent less than it declared (`PartialFill`). Buys must fill completely, so points, the fee and `bought` always match the ETH swapped | `test_buyStoppedByPriceLimitReverts` |
| 2 | Medium | A flip revealed or expired between settlement batches changed points already ranked | **Fixed.** `settle` reverts while any flip of that day is pending (`pendingFlips`, `FlipsPending`). Every flip of a finished day can be expired before settlement opens (10 min < 15 min) | `test_settleWaitsForPendingFlips`, `test_expiredFlipsUnblockSettlement` |
| 3 | Medium | Robin Hood can pay the player making the move when they are the lowest of the last 10 | **Accepted by design.** Robbing the leader for yourself when you're the lowest is part of the game (moves can be chained). Documented in the README | `test_robinHoodCanPayTheMover` |
| 4 | Medium | The Dice fee paid from the pot had no cap | **Fixed.** `MAX_DICE_FEE` = 0.0005 ETH (20x the fee at launch). Above it, a flip scores as a plain buy | `test_diceFeeAboveCapScoresAsBuy` |
| 5 | Low | The flip win multiplier used the bonus-boosted stake instead of the buy size | **Fixed.** The win is fixed at request time from the base points (`PendingFlip.win`) | `test_flipWinScalesWithBuySizeNotBonus` |
| 6 | Low | The claim window ran from the day's end, so a day settled more than 7 days late was unclaimable | **Fixed.** `claimDeadline(day)` is 7 days from the day's end or from settlement, whichever is later | `test_lateSettlementStillGivesSevenDaysToClaim` |
| 7 | Low | The leader cache froze for the day once stale on days over `MAX_LEADER_SCAN` players | **Fixed.** `_credit` keeps comparing against the cached leader even while it is stale | none (needs 1,500+ players in one day); existing leader tests still pass |
| 8 | Low | A Dice refund triggered outside `refundDiceRequest` was dropped and stuck | **Fixed.** `receive()` credits any ETH from Dice to the buyback reserve | `test_diceRefundFromAnywhereGoesToBuybackReserve` |
| 9 | Info | The owner could point the buyback at a pool with a hook that captures the ETH | **Fixed.** `setBuybackPool` can be called once (`PoolAlreadySet`). After launch nobody can redirect the reserve | `test_buybackPoolIsSetOnce` |

The fixes are not re-audited. For the high finding, the judge's own proof test from the report
(`test_pointsFollowEthActuallySwappedNotAmountOffered`, run unchanged) fails on the audited commit with
"points scored on ETH that never entered the pool: 100 > 5" and passes on the fixed code, where the
price-limited buy reverts with `PartialFill()`.
