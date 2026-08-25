# opencode-prewalk

Prewalk for OpenCode 2: let a frontier model explore, plan, create a todo list, and make the first implementation edit, then continue the **same session** with a faster model.

The initial defaults are:

```text
planner:          opencode/gpt-5.6-sol
planner variant:  high
executor:         opencode/gpt-5.6-luna
executor variant: medium
```

## How it works

1. `/prewalk <task>` switches the current session to GPT-5.6 Sol.
2. A hidden context instruction asks Sol to explore deeply, create a compact todo list, and begin the implementation.
3. The plugin waits until a todo tool succeeds and then an edit/write tool succeeds. Shell calls, the todo call itself, and failed edits do not trigger the handoff.
4. The current session switches to GPT-5.6 Luna. The planning instruction is no longer inserted, while a one-shot executor nudge tells Luna to finish the existing todo list and validation.

This transfers the grounded trajectory—not a prose summary or a fresh thread—to the executor.

## Install from this checkout

Requires Node.js 20+ and an OpenCode 2 build supporting the beta plugin API.

```sh
npm install
```

Add the plugin to `opencode.jsonc` using a path that is correct relative to that config file:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["./src/index.ts"]
}
```

When this package is published, the equivalent package configuration will be:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["opencode-prewalk"]
}
```

## Usage

```text
/prewalk fix the failing auth refresh tests
/prewalk status
/prewalk off
```

Running `/prewalk` without a task arms the current session; send the task in the next message.

## Configuration

Plugin options accept full `provider/model` identifiers and OpenCode model variants:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    {
      "package": "./src/index.ts",
      "options": {
        "planner": "opencode/gpt-5.6-sol",
        "plannerVariant": "high",
        "executor": "opencode/gpt-5.6-luna",
        "executorVariant": "medium"
      }
    }
  ]
}
```

For installations whose built-in tools use different names, `todoTools` and `editTools` can be overridden with arrays of tool names. The defaults cover `todo`, `todowrite`, `todo_write`, `update_todo`, `update_plan`, `edit`, `write`, `apply_patch`, and `multiedit`, including namespaced forms.

## Development

```sh
npm run verify
```

The verification suite typechecks against `@opencode-ai/plugin@beta` and exercises the full arm → planning context → todo gate → successful edit → model switch → instruction scrub lifecycle with a mock OpenCode context.

## Background and license

Based on [Stencil's Prewalk](https://stencil.so/blog/prewalk), [pi-prewalk](https://pi.dev/packages/pi-prewalk), and [codex-prewalk](https://github.com/vivekascoder/codex-prewalk). OpenCode's plugin API is documented in [Build Plugins](https://opencode.ai/v2/docs/build/plugins).

Licensed under Apache License 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
