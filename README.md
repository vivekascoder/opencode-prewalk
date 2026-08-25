# opencode-prewalk

Prewalk for OpenCode 2: let a frontier model explore, plan, create a todo list, and make the first implementation edit, then continue the **same session** with a faster model.

The initial defaults are:

```text
planner:          openai/gpt-5.6-sol
planner variant:  high
executor:         openai/gpt-5.6-luna
executor variant: medium
```

## How it works

1. `/prewalk <task>` switches the current session to GPT-5.6 Sol.
2. A hidden context instruction asks Sol to explore deeply, create a compact todo list, and begin the implementation.
3. Sol records the plan through the plugin's `prewalk_todo` tool. The plugin then waits for a successful edit/write tool. Shell calls, the todo call itself, and failed edits do not trigger the handoff.
4. The current session switches to GPT-5.6 Luna. The planning instruction is no longer inserted, while a one-shot executor nudge tells Luna to finish the existing todo list and validation.

This transfers the grounded trajectory—not a prose summary or a fresh thread—to the executor.

## Quick install

Requirements:

- Node.js 20+
- Git and npm
- A current `opencode2` installation
- Authentication for the planner and executor models

Install or update automatically:

```sh
curl -fsSL https://raw.githubusercontent.com/vivekascoder/opencode-prewalk/main/install.sh | bash
```

The installer:

- clones or updates the repository at `~/.local/share/opencode-prewalk`
- installs the plugin's runtime dependencies
- links its entrypoint at `~/.config/opencode/plugins/opencode-prewalk.ts`, where OpenCode discovers global plugins automatically
- preserves a single checkout, so rerunning the same command updates the installation
- refuses to overwrite an existing non-symlink plugin directory

Restart OpenCode after installing or updating.

Installer paths can be overridden:

```sh
export OPENCODE_PREWALK_DIR="$HOME/.local/share/opencode-prewalk"
export OPENCODE_PREWALK_PLUGIN_FILE="$HOME/.config/opencode/plugins/opencode-prewalk.ts"
```

## Manual install

Clone the repository and install its runtime dependencies:

```sh
git clone https://github.com/vivekascoder/opencode-prewalk.git ~/.local/share/opencode-prewalk
npm --prefix ~/.local/share/opencode-prewalk install --omit=dev
```

Add the plugin entry to `~/.config/opencode/opencode.jsonc`. Replace the example with the absolute path to your checkout:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["/absolute/path/to/opencode-prewalk/src/index.ts"]
}
```

If the file already contains settings or plugins, merge this entry into the existing `plugins` array. Restart OpenCode afterward.

To update a manual installation:

```sh
git -C ~/.local/share/opencode-prewalk pull --ff-only
npm --prefix ~/.local/share/opencode-prewalk install --omit=dev
```

When the package is published to npm, the equivalent configuration will be:

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

### Headless mode

Pass the task as an argument to the bundled headless wrapper:

```sh
~/.local/share/opencode-prewalk/headless.sh \
  "fix the failing auth refresh tests"
```

This invokes the registered `/prewalk` command through OpenCode's API, waits for the session to finish, and prints the final answer. It uses the current directory as the task directory and connects to the normal OpenCode background service. `opencode2 run "/prewalk ..."` is not equivalent: the `run` subcommand sends slash-prefixed text as an ordinary prompt instead of dispatching a registered command.

## Configuration

Plugin options accept full `provider/model` identifiers and OpenCode model variants:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    {
      "package": "./src/index.ts",
      "options": {
        "planner": "openai/gpt-5.6-sol",
        "plannerVariant": "high",
        "executor": "openai/gpt-5.6-luna",
        "executorVariant": "medium"
      }
    }
  ]
}
```

For installations whose built-in tools use different names, `todoTools` and `editTools` can be overridden with arrays of tool names. The defaults cover `prewalk_todo`, common built-in todo names, and the `edit`, `write`, `patch`, `apply_patch`, and `multiedit` edit names, including namespaced forms.

## Development

```sh
npm run verify
```

The verification suite typechecks against `@opencode-ai/plugin@beta` and exercises the full arm → planning context → todo gate → successful edit → model switch → instruction scrub lifecycle with a mock OpenCode context.

## Background and license

Based on [Stencil's Prewalk](https://stencil.so/blog/prewalk), [pi-prewalk](https://pi.dev/packages/pi-prewalk), and [codex-prewalk](https://github.com/vivekascoder/codex-prewalk). OpenCode's plugin API is documented in [Build Plugins](https://opencode.ai/v2/docs/build/plugins).

Licensed under Apache License 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
