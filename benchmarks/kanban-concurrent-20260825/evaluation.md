# Kanban benchmark evaluation

Both OpenCode sessions started concurrently from fixture commit `e90ffc1a7c17c21bcfbad981ce0b249adfabfd1e` and received the same task from `TASK.md`.

## Measured result

| Metric | Normal: Sol high | Prewalk: Sol high → Luna medium |
|---|---:|---:|
| Outcome | Succeeded | Succeeded |
| Time until the full session became idle | 630 seconds | 808 seconds |
| Estimated Standard API cost | $0.7281 | $0.1492 |
| Input tokens | 39,813 | 121,431 |
| Output tokens | 19,007 | 16,465 |
| Reasoning tokens | 3,477 | 2,371 |
| Tool calls in the parent trace | 27 | 43 |
| Changed paths | 8 | 8 |
| Source/frontend lines | 1,130 | 325 |

Estimated pricing uses OpenAI's Standard short-context rates, including uncached input, cached input, cache writes, output, and reasoning tokens. Prewalk was approximately 79.5% cheaper in this run because most of its work ran on Luna. Both concurrent sessions encountered provider `ECONNRESET` retries. Prewalk also spawned an exploration child that remained active after the implementation had apparently completed; interrupting that stale child allowed the parent session to reach its final idle state and accounts for much of its final wall time and aggregate input-token increase.

## Independent verification

| Check | Normal | Prewalk |
|---|---|---|
| Strict TypeScript check | Pass | Pass |
| API tests | 7 pass, 46 assertions | 6 pass, 19 assertions |
| Browser bundle build | Prebuilt vanilla JS | Pass, rebuilt from browser TypeScript |
| Server startup | Pass on port 43101 | Pass on port 43102 |
| Seeded API response | 3 columns, 3 cards | 3 columns, 4 cards |
| HTML served by Express | Pass | Pass |
| CRUD and transactional move APIs | Pass | Pass |
| Drag-and-drop movement | Implemented | Implemented |
| Non-drag reorder within a column | Implemented | Implemented |
| Non-drag movement between columns | Implemented with a target-column selector | Missing from the rendered UI |
| Column deletion in the UI | Implemented | Handler exists, but no delete-column control is rendered |
| Responsive/loading/empty/error states | Implemented | Implemented |
| README architecture/schema/API docs | Implemented | Implemented |

## Verdict

The normal Sol implementation is the stronger result for this run. It satisfies the full interaction brief, has broader tests, clearer separation and formatting, and independently runs correctly.

Prewalk produced a much smaller implementation, used 13.4% fewer output tokens, and was approximately 79.5% cheaper at Standard API rates. It nevertheless missed two UI requirements, and the concurrent run was 28.3% slower to final idle while using 205% more input tokens. The transport retries and stale exploration child make this a noisy concurrency benchmark, but they are real behavior of this run rather than excluded data.
