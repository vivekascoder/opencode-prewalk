# Full-stack Kanban implementation task

Build a complete, runnable Kanban board in this repository.

## Stack

- Bun runtime and package manager
- TypeScript with strict type checking
- Express HTTP server
- SQLite persistence using Bun's built-in `bun:sqlite`
- Vanilla HTML, CSS, and browser TypeScript/JavaScript; do not use React, Vue, Svelte, or another frontend framework

## Product requirements

- Show a board with columns and cards, seeded with useful starter data on first launch.
- Create, rename, and delete columns.
- Create, edit, and delete cards. Cards need a title, optional description, and visible creation/update timestamps.
- Move cards between columns and reorder cards within a column. The UI should support drag and drop and also remain usable without drag and drop.
- Persist all mutations in SQLite and preserve deterministic column/card ordering across restarts.
- Provide responsive styling, clear empty states, inline forms, loading feedback, and visible error feedback.

## API and engineering requirements

- Implement documented JSON REST endpoints for listing the board and all required column/card mutations.
- Validate request bodies and identifiers. Return consistent JSON errors and appropriate HTTP status codes for invalid input and missing records.
- Make multi-row reorder/move operations transactional.
- Serve the frontend from the Express application.
- Provide `bun run dev`, `bun run start`, `bun run typecheck`, and `bun test` scripts.
- Add automated API tests covering the initial board, representative CRUD operations, moving/reordering a card, validation failures, and missing records. Tests must use an isolated temporary database.
- Add a concise README with setup, scripts, architecture, schema, and API documentation.
- Keep generated databases and dependencies out of Git.

Install dependencies, run type checking and the automated tests, and fix any failures before finishing.
