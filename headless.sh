#!/usr/bin/env bash
set -euo pipefail

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

for cmd in node opencode2; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

[ "$#" -gt 0 ] || fail "Usage: headless.sh <task>"

task="$*"
task_directory="$PWD"
server_args=()

if [ -n "${OPENCODE_SERVER_URL:-}" ]; then
  server_args=(--server "$OPENCODE_SERVER_URL")
else
  opencode2 service start >/dev/null
fi

api() {
  opencode2 api "${server_args[@]}" "$@"
}

create_payload="$(PREWALK_DIRECTORY="$task_directory" node -p '
  JSON.stringify({
    title: "Prewalk: headless run",
    location: { directory: process.env.PREWALK_DIRECTORY },
  })
')"
session_response="$(api --data "$create_payload" POST /api/session)"
session_id="$(printf '%s' "$session_response" | node -e '
  let input = ""
  process.stdin.on("data", (chunk) => input += chunk)
  process.stdin.on("end", () => {
    const id = JSON.parse(input)?.data?.id
    if (!id) process.exit(1)
    process.stdout.write(id)
  })
')" || fail "OpenCode did not return a session ID"

command_payload="$(PREWALK_TASK="$task" node -p '
  JSON.stringify({
    command: "prewalk",
    text: process.env.PREWALK_TASK,
    files: [],
    agents: [],
    skills: [],
    delivery: "steer",
  })
')"

api --data "$command_payload" POST "/api/session/$session_id/command" >/dev/null
api --data '{}' POST "/api/session/$session_id/wait" >/dev/null

api GET "/api/session/$session_id/context" | node -e '
  let input = ""
  process.stdin.on("data", (chunk) => input += chunk)
  process.stdin.on("end", () => {
    const messages = JSON.parse(input)?.data ?? []
    const assistants = messages.filter((message) => message.type === "assistant")
    const text = assistants.flatMap((message) => message.content ?? [])
      .filter((part) => part.type === "text")
      .at(-1)?.text
    if (!text) {
      console.error("Prewalk finished without an assistant response.")
      process.exit(1)
    }
    process.stdout.write(`${text}\n`)
  })
'
