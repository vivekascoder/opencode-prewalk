#!/usr/bin/env bash
set -euo pipefail

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '• %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: benchmark.sh [options] <task>

Run the same task from the same Git revision twice:
  1. normally with GPT-5.6 Sol (high)
  2. with /prewalk (GPT-5.6 Sol high -> GPT-5.6 Luna medium)

Options:
  --output DIR       Report directory (default: .opencode-prewalk/benchmarks/<timestamp>)
  --revision REV     Git revision used for both worktrees (default: HEAD)
  --server URL       Connect to an existing OpenCode server
  --concurrent       Start the normal and Prewalk runs at the same time
  --keep-worktrees   Keep both temporary worktrees for inspection
  -h, --help         Show this help

Environment:
  PREWALK_BENCHMARK_MODEL          Baseline provider/model (default: openai/gpt-5.6-sol)
  PREWALK_BENCHMARK_VARIANT        Baseline variant (default: high)
  OPENCODE_SERVER_URL              Same as --server
EOF
}

for command_name in git node opencode2; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
done

output_arg=""
revision="HEAD"
server_url="${OPENCODE_SERVER_URL:-}"
keep_worktrees=false
concurrent=false
task_parts=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || fail "--output requires a directory"
      output_arg="$2"
      shift 2
      ;;
    --revision)
      [ "$#" -ge 2 ] || fail "--revision requires a Git revision"
      revision="$2"
      shift 2
      ;;
    --server)
      [ "$#" -ge 2 ] || fail "--server requires a URL"
      server_url="$2"
      shift 2
      ;;
    --keep-worktrees)
      keep_worktrees=true
      shift
      ;;
    --concurrent)
      concurrent=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      task_parts+=("$@")
      break
      ;;
    -*) fail "Unknown option: $1" ;;
    *) task_parts+=("$1"); shift ;;
  esac
done

[ "${#task_parts[@]}" -gt 0 ] || fail "A benchmark task is required. Run with --help for usage."
task="${task_parts[*]}"
source_directory="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Run this command inside the Git repository to benchmark"
git -C "$source_directory" rev-parse --verify "${revision}^{commit}" >/dev/null 2>&1 || fail "Unknown revision: $revision"
commit="$(git -C "$source_directory" rev-parse "${revision}^{commit}")"

if [ -n "$(git -C "$source_directory" status --porcelain)" ]; then
  note "The source checkout has uncommitted changes; both runs will use committed revision ${commit:0:12}."
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -z "$output_arg" ]; then
  output_arg="$source_directory/.opencode-prewalk/benchmarks/$timestamp"
elif [[ "$output_arg" != /* ]]; then
  output_arg="$PWD/$output_arg"
fi
mkdir -p "$output_arg"
output_directory="$(cd "$output_arg" && pwd -P)"

worktree_parent="$source_directory/.opencode-prewalk/worktrees"
mkdir -p "$worktree_parent"
temporary_root="$(mktemp -d "$worktree_parent/run.XXXXXX")"
normal_worktree="$temporary_root/normal"
prewalk_worktree="$temporary_root/prewalk"

cleanup() {
  if [ "$keep_worktrees" = true ]; then
    note "Kept normal worktree: $normal_worktree"
    note "Kept Prewalk worktree: $prewalk_worktree"
    return
  fi
  git -C "$source_directory" worktree remove --force "$normal_worktree" >/dev/null 2>&1 || true
  git -C "$source_directory" worktree remove --force "$prewalk_worktree" >/dev/null 2>&1 || true
  rmdir "$temporary_root" >/dev/null 2>&1 || true
  rmdir "$worktree_parent" >/dev/null 2>&1 || true
  rmdir "$source_directory/.opencode-prewalk" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

note "Creating identical worktrees at ${commit:0:12}"
git -C "$source_directory" worktree add --detach --quiet "$normal_worktree" "$commit"
git -C "$source_directory" worktree add --detach --quiet "$prewalk_worktree" "$commit"

if [ -n "$server_url" ]; then
  :
else
  opencode2 service start >/dev/null
fi

api() {
  if [ -n "$server_url" ]; then
    opencode2 api --server "$server_url" "$@"
  else
    opencode2 api "$@"
  fi
}

json_field() {
  local field="$1"
  node -e '
    const field = process.argv[1]
    let input = ""
    process.stdin.on("data", chunk => input += chunk)
    process.stdin.on("end", () => {
      const value = JSON.parse(input)?.data?.[field]
      if (value === undefined || value === null) process.exit(1)
      process.stdout.write(String(value))
    })
  ' "$field"
}

write_changes() {
  local worktree="$1"
  local run_directory="$2"
  git -C "$worktree" status --porcelain=v1 > "$run_directory/changes.txt"
  git -C "$worktree" diff --binary HEAD > "$run_directory/changes.patch"
  while IFS= read -r -d '' untracked_file; do
    git -C "$worktree" diff --binary --no-index -- /dev/null "$untracked_file" >> "$run_directory/changes.patch" || [ "$?" -eq 1 ]
  done < <(git -C "$worktree" ls-files --others --exclude-standard -z)
}

wait_for_session() {
  local session_id="$1"
  local mode="$2"
  local active_response

  while ! api --data '{}' POST "/api/session/$session_id/wait" >/dev/null; do
    active_response="$(api GET /api/session/active 2>/dev/null || true)"
    if ACTIVE_SESSION_ID="$session_id" ACTIVE_RESPONSE="$active_response" node -e '
      try {
        const response = JSON.parse(process.env.ACTIVE_RESPONSE || "{}")
        process.exit(response?.data?.[process.env.ACTIVE_SESSION_ID] ? 0 : 1)
      } catch { process.exit(1) }
    '; then
      note "$mode wait connection ended while the session is active; reconnecting"
      sleep 2
    else
      note "$mode wait connection ended after the session stopped; capturing its result"
      return
    fi
  done
}

run_case() {
  local mode="$1"
  local worktree="$2"
  local run_directory="$output_directory/$mode"
  local model_value="${PREWALK_BENCHMARK_MODEL:-openai/gpt-5.6-sol}"
  local variant_value="${PREWALK_BENCHMARK_VARIANT:-high}"
  local provider_id="${model_value%%/*}"
  local model_id="${model_value#*/}"

  [ "$provider_id" != "$model_id" ] || fail "PREWALK_BENCHMARK_MODEL must use provider/model form"
  mkdir -p "$run_directory"

  local create_payload
  create_payload="$(BENCH_DIRECTORY="$worktree" BENCH_MODE="$mode" BENCH_PROVIDER="$provider_id" BENCH_MODEL="$model_id" BENCH_VARIANT="$variant_value" node -e '
    process.stdout.write(JSON.stringify({
      title: `Prewalk benchmark: ${process.env.BENCH_MODE}`,
      location: { directory: process.env.BENCH_DIRECTORY },
      model: {
        providerID: process.env.BENCH_PROVIDER,
        id: process.env.BENCH_MODEL,
        variant: process.env.BENCH_VARIANT,
      },
    }))
  ')"

  local session_response session_id request_payload start_seconds end_seconds
  session_response="$(api --data "$create_payload" POST /api/session)"
  session_id="$(printf '%s' "$session_response" | json_field id)" || fail "OpenCode did not return a session ID for the $mode run"

  start_seconds="$(date +%s)"
  if [ "$mode" = "prewalk" ]; then
    request_payload="$(BENCH_TASK="$task" node -e '
      process.stdout.write(JSON.stringify({
        command: "prewalk",
        text: process.env.BENCH_TASK,
        files: [], agents: [], skills: [], delivery: "steer",
      }))
    ')"
    note "Running Prewalk (${session_id})"
    api --data "$request_payload" POST "/api/session/$session_id/command" >/dev/null
  else
    request_payload="$(BENCH_TASK="$task" node -e '
      process.stdout.write(JSON.stringify({
        text: `This is the normal, no-Prewalk baseline run. Do not load, invoke, or follow any skill or plugin named prewalk. Complete the following task directly with the current model.\n\n${process.env.BENCH_TASK}`,
        files: [], agents: [], skills: [], delivery: "steer",
      }))
    ')"
    note "Running normal Sol baseline (${session_id})"
    api --data "$request_payload" POST "/api/session/$session_id/prompt" >/dev/null
  fi

  wait_for_session "$session_id" "$mode"
  end_seconds="$(date +%s)"
  api GET "/api/session/$session_id" > "$run_directory/session.json"
  api GET "/api/session/$session_id/context" > "$run_directory/context.json"
  BENCH_MODE="$mode" BENCH_SESSION="$session_id" BENCH_START="$start_seconds" BENCH_END="$end_seconds" BENCH_WORKTREE="$worktree" node -e '
    const fs = require("node:fs")
    fs.writeFileSync(process.argv[1], JSON.stringify({
      mode: process.env.BENCH_MODE,
      sessionID: process.env.BENCH_SESSION,
      durationSeconds: Number(process.env.BENCH_END) - Number(process.env.BENCH_START),
      worktree: process.env.BENCH_WORKTREE,
    }, null, 2) + "\n")
  ' "$run_directory/run.json"
  write_changes "$worktree" "$run_directory"
}

if [ "$concurrent" = true ]; then
  note "Starting both benchmark runs concurrently"
  run_case normal "$normal_worktree" &
  normal_pid=$!
  run_case prewalk "$prewalk_worktree" &
  prewalk_pid=$!

  normal_status=0
  prewalk_status=0
  wait "$normal_pid" || normal_status=$?
  wait "$prewalk_pid" || prewalk_status=$?
  [ "$normal_status" -eq 0 ] || fail "Normal benchmark run failed with status $normal_status"
  [ "$prewalk_status" -eq 0 ] || fail "Prewalk benchmark run failed with status $prewalk_status"
else
  run_case normal "$normal_worktree"
  run_case prewalk "$prewalk_worktree"
fi

BENCH_OUTPUT="$output_directory" BENCH_TASK="$task" BENCH_COMMIT="$commit" node <<'NODE'
const fs = require("node:fs")
const path = require("node:path")

const output = process.env.BENCH_OUTPUT
const unwrap = value => value && Object.hasOwn(value, "data") ? value.data : value
const readJSON = file => unwrap(JSON.parse(fs.readFileSync(file, "utf8")))
const sumToken = (values, key) => values.reduce((sum, value) => sum + Number(value?.[key] ?? 0), 0)
const pricing = {
  source: "https://developers.openai.com/api/docs/pricing",
  checkedAt: "2026-08-25",
  tier: "standard",
  currency: "USD",
  unit: "per 1M tokens",
  longContextThreshold: 272_000,
  models: {
    "gpt-5.6-sol": { input: 4, cachedInput: 0.4, cacheWrite: 5, output: 20 },
    "gpt-5.6-luna": { input: 0.2, cachedInput: 0.02, cacheWrite: 0.25, output: 1.2 },
  },
}

function priceStep(modelID, tokens) {
  const rates = pricing.models[modelID]
  if (!rates) return null
  const longContext = Number(tokens.input ?? 0) + Number(tokens.cache?.read ?? 0) + Number(tokens.cache?.write ?? 0) > pricing.longContextThreshold
  const inputMultiplier = longContext ? 2 : 1
  const outputMultiplier = longContext ? 1.5 : 1
  return (
    Number(tokens.input ?? 0) * rates.input * inputMultiplier
    + Number(tokens.cache?.read ?? 0) * rates.cachedInput * inputMultiplier
    + Number(tokens.cache?.write ?? 0) * rates.cacheWrite * inputMultiplier
    + (Number(tokens.output ?? 0) + Number(tokens.reasoning ?? 0)) * rates.output * outputMultiplier
  ) / 1_000_000
}

const readCommands = new Set([
  "awk", "cat", "cd", "comm", "cut", "diff", "egrep", "fgrep", "file", "find", "grep", "head", "jq",
  "less", "ls", "more", "pwd", "readlink", "realpath", "rg", "rgrep", "ripgrep", "sed", "sort", "stat",
  "tail", "test", "tree", "uniq", "wc", "which", "yq",
])
const readGitCommands = new Set(["describe", "diff", "grep", "log", "ls-files", "rev-parse", "show", "status"])

function shellCommand(input) {
  if (typeof input?.command === "string") return input.command
  if (Array.isArray(input?.command)) return input.command.join(" ")
  return ""
}

function isReadOnlyShell(command) {
  if (!command.trim()) return false
  if (/(^|[^<])>{1,2}|\b(tee|rm|mv|cp|install|mkdir|touch|chmod|chown|truncate|dd)\b|\bsed\s+[^\n;&|]*-[^-\s]*i\b|\bfind\s+[^\n;&|]*(-delete|-exec|-execdir)\b/.test(command)) return false

  const segments = command.replace(/\\\r?\n/g, " ").split(/(?:&&|\|\||[;|\n])/).map(value => value.trim()).filter(Boolean)
  return segments.length > 0 && segments.every(segment => {
    const words = segment.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s+)*/, "").match(/(?:"[^"]*"|'[^']*'|\S+)/g) ?? []
    if (!words.length) return false
    let commandIndex = words[0] === "command" || words[0] === "env" ? 1 : 0
    while (words[commandIndex]?.includes("=")) commandIndex += 1
    const executable = (words[commandIndex] ?? "").replace(/^.*\//, "")
    if (executable === "git") {
      let index = commandIndex + 1
      while (words[index]?.startsWith("-")) index += ["-C", "-c", "--git-dir", "--work-tree"].includes(words[index]) ? 2 : 1
      return readGitCommands.has(words[index])
    }
    return readCommands.has(executable)
  })
}

function classifyTool(rawName, input) {
  const normalized = String(rawName).toLowerCase().split(/[.:/]/).at(-1)
  if (["bash", "shell"].includes(normalized) && isReadOnlyShell(shellCommand(input))) return "read"
  return rawName
}

function summarize(mode) {
  const directory = path.join(output, mode)
  const info = readJSON(path.join(directory, "session.json"))
  const messages = readJSON(path.join(directory, "context.json"))
  const run = JSON.parse(fs.readFileSync(path.join(directory, "run.json"), "utf8"))
  const changes = fs.readFileSync(path.join(directory, "changes.txt"), "utf8").split(/\r?\n/).filter(Boolean)
  const assistants = messages.filter(message => message.type === "assistant")
  const steps = assistants.map((message, index) => {
    const tools = (message.content ?? []).filter(part => part.type === "tool").map(part => {
      const input = part.state?.input ?? {}
      return {
        name: classifyTool(part.name, input),
        rawName: part.name,
        command: shellCommand(input) || null,
        status: part.state?.status ?? part.state?.type ?? "unknown",
        createdAt: Number(part.time?.created ?? 0),
        durationMs: part.time?.completed && (part.time?.ran ?? part.time?.created)
          ? part.time.completed - (part.time.ran ?? part.time.created)
          : null,
      }
    })
    return {
      index: index + 1,
      modelID: message.model?.id ?? "unknown",
      model: `${message.model?.providerID ?? "?"}/${message.model?.id ?? "?"}${message.model?.variant ? `#${message.model.variant}` : ""}`,
      createdAt: Number(message.time?.created ?? 0),
      completedAt: Number(message.time?.completed ?? 0),
      finish: message.finish ?? null,
      cost: Number(message.cost ?? 0),
      tokens: message.tokens ?? { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      tools,
    }
  })
  for (const step of steps) step.estimatedCost = priceStep(step.modelID, step.tokens)
  const tokenSource = info.tokens ?? {
    input: sumToken(steps.map(step => step.tokens), "input"),
    output: sumToken(steps.map(step => step.tokens), "output"),
    reasoning: sumToken(steps.map(step => step.tokens), "reasoning"),
    cache: {
      read: sumToken(steps.map(step => step.tokens.cache), "read"),
      write: sumToken(steps.map(step => step.tokens.cache), "write"),
    },
  }
  const finalAnswer = assistants.flatMap(message => message.content ?? [])
    .filter(part => part.type === "text" && part.text?.trim()).at(-1)?.text ?? ""
  const pricedSteps = steps.filter(step => step.estimatedCost !== null)
  const estimatedCost = pricedSteps.length === steps.length
    ? pricedSteps.reduce((sum, step) => sum + step.estimatedCost, 0)
    : null
  const pricingBreakdown = Object.values(steps.reduce((models, step) => {
    const current = models[step.modelID] ??= {
      modelID: step.modelID,
      steps: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      estimatedCost: 0,
    }
    current.steps += 1
    current.tokens.input += Number(step.tokens.input ?? 0)
    current.tokens.output += Number(step.tokens.output ?? 0)
    current.tokens.reasoning += Number(step.tokens.reasoning ?? 0)
    current.tokens.cache.read += Number(step.tokens.cache?.read ?? 0)
    current.tokens.cache.write += Number(step.tokens.cache?.write ?? 0)
    current.estimatedCost += Number(step.estimatedCost ?? 0)
    return models
  }, {}))
  return {
    mode,
    sessionID: run.sessionID,
    outcome: info.outcome ?? "unknown",
    durationSeconds: run.durationSeconds,
    cost: estimatedCost,
    reportedCost: Number(info.cost ?? sumToken(steps, "cost")),
    pricingBreakdown,
    tokens: tokenSource,
    models: [...new Set(steps.map(step => step.model))],
    toolCalls: steps.flatMap(step => step.tools.map(tool => tool.name)),
    rawToolCalls: steps.flatMap(step => step.tools.map(tool => tool.rawName)),
    changedFiles: changes,
    finalAnswer,
    steps,
  }
}

const normal = summarize("normal")
const prewalk = summarize("prewalk")
const percent = (before, after) => before ? ((after - before) / before) * 100 : null
const pathOf = line => line.slice(3).replace(/^"|"$/g, "")
const normalPaths = new Set(normal.changedFiles.map(pathOf))
const prewalkPaths = new Set(prewalk.changedFiles.map(pathOf))
const comparison = {
  durationPercent: percent(normal.durationSeconds, prewalk.durationSeconds),
  costPercent: percent(normal.cost, prewalk.cost),
  inputTokensPercent: percent(normal.tokens.input, prewalk.tokens.input),
  outputTokensPercent: percent(normal.tokens.output, prewalk.tokens.output),
  commonChangedPaths: [...normalPaths].filter(value => prewalkPaths.has(value)),
  normalOnlyChangedPaths: [...normalPaths].filter(value => !prewalkPaths.has(value)),
  prewalkOnlyChangedPaths: [...prewalkPaths].filter(value => !normalPaths.has(value)),
}
const report = {
  task: process.env.BENCH_TASK,
  commit: process.env.BENCH_COMMIT,
  generatedAt: new Date().toISOString(),
  pricing,
  normal,
  prewalk,
  comparison,
}
fs.writeFileSync(path.join(output, "report.json"), JSON.stringify(report, null, 2) + "\n")

const fmtNumber = value => Number(value ?? 0).toLocaleString("en-US")
const fmtCost = value => value === null ? "n/a" : `$${Number(value ?? 0).toFixed(4)}`
const fmtPercent = value => value === null ? "n/a" : `${value >= 0 ? "+" : ""}${value.toFixed(1)}%`
const toolSequence = run => run.toolCalls.length ? run.toolCalls.join(" | ") : "(no tools)"
const changed = run => run.changedFiles.length ? run.changedFiles.map(line => `- \`${line}\``).join("\n") : "- (none)"
const markdown = `# Prewalk benchmark

Task: ${report.task}

Revision: \`${report.commit}\`

| Metric | Normal (Sol high) | Prewalk (Sol → Luna) | Change |
|---|---:|---:|---:|
| Outcome | ${normal.outcome} | ${prewalk.outcome} | — |
| Duration | ${normal.durationSeconds}s | ${prewalk.durationSeconds}s | ${fmtPercent(comparison.durationPercent)} |
| Estimated Standard API cost | ${fmtCost(normal.cost)} | ${fmtCost(prewalk.cost)} | ${fmtPercent(comparison.costPercent)} |
| Input tokens | ${fmtNumber(normal.tokens.input)} | ${fmtNumber(prewalk.tokens.input)} | ${fmtPercent(comparison.inputTokensPercent)} |
| Cached input tokens | ${fmtNumber(normal.tokens.cache.read)} | ${fmtNumber(prewalk.tokens.cache.read)} | — |
| Output tokens | ${fmtNumber(normal.tokens.output)} | ${fmtNumber(prewalk.tokens.output)} | ${fmtPercent(comparison.outputTokensPercent)} |
| Reasoning tokens | ${fmtNumber(normal.tokens.reasoning)} | ${fmtNumber(prewalk.tokens.reasoning)} | — |
| Tool calls | ${normal.toolCalls.length} | ${prewalk.toolCalls.length} | — |
| Changed files | ${normal.changedFiles.length} | ${prewalk.changedFiles.length} | — |

Pricing uses OpenAI's short-context Standard rates per 1M tokens: Sol $4 input / $0.40 cached input / $5 cache write / $20 output; Luna $0.20 / $0.02 / $0.25 / $1.20. Reasoning tokens are priced as output. Requests above 272K input tokens automatically use OpenAI's 2x input and 1.5x output multipliers. Source: ${pricing.source}

## Tool sequence

- Normal: ${toolSequence(normal)}
- Prewalk: ${toolSequence(prewalk)}

## Normal changes

${changed(normal)}

## Prewalk changes

${changed(prewalk)}

## Final answers

### Normal

${normal.finalAnswer || "(no final answer)"}

### Prewalk

${prewalk.finalAnswer || "(no final answer)"}
`
fs.writeFileSync(path.join(output, "report.md"), markdown)

const esc = value => String(value).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char])
function chart(run) {
  let cumulativeInput = 0
  const events = run.steps.flatMap(step => {
    cumulativeInput += Number(step.tokens?.input ?? 0) + Number(step.tokens?.cache?.read ?? 0) + Number(step.tokens?.cache?.write ?? 0)
    const markers = step.tools.length ? step.tools : [{ name: step.finish === "stop" ? "response" : step.finish ?? "step" }]
    return markers.map((tool, index) => ({
      label: tool.name,
      detail: tool.command ? `${tool.rawName}: ${tool.command}` : tool.rawName && tool.rawName !== tool.name ? `raw tool: ${tool.rawName}` : "",
      cumulativeInput,
      model: step.model,
      time: step.tools[index]?.createdAt || step.completedAt || step.createdAt || step.index,
    }))
  })
  if (!events.length) return "<p>No model steps recorded.</p>"
  const width = 760, height = 260, left = 58, right = 18, top = 20, bottom = 82
  const maximum = Math.max(...events.map(event => event.cumulativeInput), 1)
  const startedAt = Math.min(...events.map(event => event.time))
  const elapsed = events.map(event => Math.max(0, event.time - startedAt))
  const maximumElapsed = Math.max(...elapsed, 1)
  const x = index => left + elapsed[index] * (width - left - right) / maximumElapsed
  const y = value => top + (maximum - value) * (height - top - bottom) / maximum
  const points = events.map((event, index) => `${x(index)},${y(event.cumulativeInput)}`).join(" ")
  const dots = events.map((event, index) => `<circle cx="${x(index)}" cy="${y(event.cumulativeInput)}" r="4"><title>${esc(event.label)}: ${event.cumulativeInput.toLocaleString()} cumulative input tokens (including cached)\n${esc(event.model)}${event.detail ? `\n${esc(event.detail)}` : ""}</title></circle>`).join("")
  const labels = events.map((event, index) => `<text x="${x(index)}" y="${height - bottom + 17}" transform="rotate(45 ${x(index)} ${height - bottom + 17})">${esc(event.label)}</text>`).join("")
  return `<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Cumulative input tokens over elapsed time with tool-call markers">
    <line class="axis" x1="${left}" y1="${height-bottom}" x2="${width-right}" y2="${height-bottom}"/>
    <line class="axis" x1="${left}" y1="${top}" x2="${left}" y2="${height-bottom}"/>
    <text class="tick" x="4" y="${top+4}">${maximum.toLocaleString()}</text><text class="tick" x="34" y="${height-bottom+4}">0</text>
    <text class="tick" x="${left}" y="${height-5}">0s</text><text class="tick" x="${width-right-42}" y="${height-5}">${Math.round(maximumElapsed / 1000)}s</text>
    <polyline points="${points}"/>${dots}${labels}</svg>`
}
function card(run, title) {
  return `<section><h2>${title}</h2><div class="metrics">
    <span><b>${esc(run.outcome)}</b> outcome</span><span><b>${run.durationSeconds}s</b> duration</span>
    <span><b>${fmtCost(run.cost)}</b> estimated cost</span><span><b>${fmtNumber(run.tokens.input)}</b> input tokens</span>
    <span><b>${run.toolCalls.length}</b> tool calls</span><span><b>${run.changedFiles.length}</b> changed files</span>
    </div>${chart(run)}<details><summary>Tool sequence</summary><code>${esc(toolSequence(run))}</code></details>
    <details><summary>Changed files</summary><pre>${esc(run.changedFiles.join("\n") || "(none)")}</pre></details>
    <details><summary>Final answer</summary><pre>${esc(run.finalAnswer || "(none)")}</pre></details></section>`
}
function costBreakdown(run) {
  return run.pricingBreakdown.map(item => `<li><b>${esc(item.modelID)}</b>: ${fmtCost(item.estimatedCost)} <small>(${item.steps} steps)</small></li>`).join("")
}
function pricingPanel() {
  const sol = pricing.models["gpt-5.6-sol"]
  const luna = pricing.models["gpt-5.6-luna"]
  return `<section class="pricing"><h2>Estimated Standard API pricing</h2>
    <div class="price-summary"><div><strong>${fmtCost(normal.cost)}</strong><span>Normal total</span><ul>${costBreakdown(normal)}</ul></div>
    <div><strong>${fmtCost(prewalk.cost)}</strong><span>Prewalk total</span><ul>${costBreakdown(prewalk)}</ul></div>
    <div><strong>${fmtPercent(comparison.costPercent)}</strong><span>Prewalk cost change</span></div></div>
    <table><thead><tr><th>Model</th><th>Input</th><th>Cached input</th><th>Cache write</th><th>Output</th></tr></thead><tbody>
    <tr><td>GPT-5.6 Sol</td><td>$${sol.input.toFixed(2)}</td><td>$${sol.cachedInput.toFixed(2)}</td><td>$${sol.cacheWrite.toFixed(2)}</td><td>$${sol.output.toFixed(2)}</td></tr>
    <tr><td>GPT-5.6 Luna</td><td>$${luna.input.toFixed(2)}</td><td>$${luna.cachedInput.toFixed(2)}</td><td>$${luna.cacheWrite.toFixed(2)}</td><td>$${luna.output.toFixed(2)}</td></tr>
    </tbody></table><p class="note">USD per 1M tokens · Standard · short context · checked ${pricing.checkedAt}. Reasoning is priced as output. <a href="${pricing.source}">OpenAI pricing source</a></p></section>`
}
const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Prewalk benchmark</title><style>
:root{color-scheme:dark;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:#0b1020;color:#e7ecf7}body{max-width:1600px;margin:auto;padding:32px}h1{margin-bottom:6px}.sub{color:#9ba8c7;margin-bottom:28px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(520px,1fr));gap:20px}section{background:#121a30;border:1px solid #263251;border-radius:14px;padding:20px;min-width:0}.metrics{display:flex;flex-wrap:wrap;gap:9px;margin-bottom:12px}.metrics span{background:#1a2542;padding:8px 10px;border-radius:8px;color:#aebbd7}.metrics b{color:#fff}svg{width:100%;height:auto;overflow:visible}polyline{fill:none;stroke:#7dd3fc;stroke-width:3}circle{fill:#fbbf24;stroke:#121a30;stroke-width:2}.axis{stroke:#52617f}.tick,svg text{fill:#9ba8c7;font-size:10px}details{margin-top:12px}summary{cursor:pointer;color:#a5b4fc}pre,code{white-space:pre-wrap;overflow-wrap:anywhere}.delta{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}.delta span{padding:8px 12px;background:#18223c;border-radius:8px}.note{color:#9ba8c7;font-size:13px}.pricing{margin:20px 0}.price-summary{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:16px 0}.price-summary>div{background:#1a2542;border-radius:10px;padding:14px}.price-summary strong{display:block;color:#86efac;font-size:22px}.price-summary span,.price-summary small{color:#9ba8c7}.price-summary ul{padding-left:18px;margin-bottom:0;font-size:12px}table{width:100%;border-collapse:collapse;margin-top:14px}th,td{text-align:right;padding:9px;border-bottom:1px solid #263251}th:first-child,td:first-child{text-align:left}a{color:#7dd3fc}@media(max-width:700px){body{padding:18px}.grid{grid-template-columns:1fr}.price-summary{grid-template-columns:1fr}}
</style></head><body><h1>Prewalk benchmark</h1><div class="sub">${esc(report.task)}<br><small>${esc(report.commit)}</small></div>
<div class="delta"><span>Duration ${fmtPercent(comparison.durationPercent)}</span><span>Cost ${fmtPercent(comparison.costPercent)}</span><span>Input tokens ${fmtPercent(comparison.inputTokensPercent)}</span></div>
${pricingPanel()}
<div class="grid">${card(normal, "Normal · Sol high")}${card(prewalk, "Prewalk · Sol → Luna")}</div>
<p class="note">The x-axis is elapsed wall time and tool names are event markers. The line adds each model step's uncached input, cached input, and cache writes to all previous steps, showing cumulative input/context consumption over time. Batched tool calls share a cumulative point. Costs use OpenAI Standard short-context pricing and include cached input, cache writes, output, and reasoning tokens.</p></body></html>`
fs.writeFileSync(path.join(output, "report.html"), html)
NODE

printf '\nBenchmark complete.\n'
printf '  Markdown: %s\n' "$output_directory/report.md"
printf '  Chart:    %s\n' "$output_directory/report.html"
printf '  Data:     %s\n' "$output_directory/report.json"
printf '\n'
sed -n '1,16p' "$output_directory/report.md"
