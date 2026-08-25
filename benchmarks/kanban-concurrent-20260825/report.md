# Prewalk benchmark

Task: Implement the complete full-stack Kanban application specified in TASK.md. Satisfy every product, API, testing, documentation, and validation requirement, and leave the repository in a runnable, verified state.

Revision: `e90ffc1a7c17c21bcfbad981ce0b249adfabfd1e`

| Metric | Normal (Sol high) | Prewalk (Sol → Luna) | Change |
|---|---:|---:|---:|
| Outcome | succeeded | succeeded | — |
| Duration | 630s | 808s | +28.3% |
| Estimated Standard API cost | $0.7281 | $0.1492 | -79.5% |
| Input tokens | 39,813 | 121,431 | +205.0% |
| Cached input tokens | 297,984 | 509,440 | — |
| Output tokens | 19,007 | 16,465 | -13.4% |
| Reasoning tokens | 3,477 | 2,371 | — |
| Tool calls | 27 | 43 | — |
| Changed files | 8 | 8 | — |

Pricing uses OpenAI's short-context Standard rates per 1M tokens: Sol $4 input / $0.40 cached input / $5 cache write / $20 output; Luna $0.20 / $0.02 / $0.25 / $1.20. Reasoning tokens are priced as output. Requests above 272K input tokens automatically use OpenAI's 2x input and 1.5x output multipliers. Source: https://developers.openai.com/api/docs/pricing

## Tool sequence

- Normal: read | read | glob | shell | read | shell | shell | patch | patch | patch | patch | shell | read | patch | shell | patch | shell | shell | shell | patch | shell | shell | shell | shell | shell | glob | read
- Prewalk: read | read | glob | shell | subagent | subagent | read | shell | shell | execute | patch | patch | patch | patch | patch | grep | patch | patch | shell | shell | shell | shell | shell | patch | shell | shell | shell | patch | shell | shell | grep | patch | read | patch | shell | shell | shell | shell | shell | patch | shell | shell | shell

## Normal changes

- ` M README.md`
- `?? .gitignore`
- `?? bun.lock`
- `?? package.json`
- `?? public/`
- `?? src/`
- `?? test/`
- `?? tsconfig.json`

## Prewalk changes

- ` M README.md`
- `?? .gitignore`
- `?? bun.lock`
- `?? package.json`
- `?? public/`
- `?? src/`
- `?? tests/`
- `?? tsconfig.json`

## Final answers

### Normal

Implemented the complete Kanban application.

**Included**
- Express JSON API with strict validation and consistent errors
- SQLite persistence, starter data, deterministic ordering, and transactional moves
- Column and card CRUD
- Drag-and-drop plus accessible move/reorder controls
- Responsive vanilla HTML/CSS/JavaScript frontend
- Visible timestamps, loading, empty, and error states
- Isolated API test databases
- Complete setup, architecture, schema, and API documentation
- Bun lockfile and generated-file exclusions

**Verified**
- `bun run typecheck`: passed
- `bun test`: 7 tests, 46 assertions passed
- Runtime HTML/API smoke test: passed
- Browser JavaScript build validation: passed
- `git diff --check`: passed
- No generated databases remain in the repository

Run with `bun run dev` and open `http://localhost:3000`.

### Prewalk

The architecture exploration subagent was cancelled after implementation was complete. No action is required.
