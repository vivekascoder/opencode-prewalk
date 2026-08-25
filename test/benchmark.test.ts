import assert from "node:assert/strict"
import { chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import test from "node:test"

const benchmark = fileURLToPath(new URL("../benchmark.sh", import.meta.url))

function run(command: string, args: string[], options: { cwd?: string; env?: NodeJS.ProcessEnv } = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: "utf8",
  })
  assert.equal(result.status, 0, `${command} failed:\n${result.stdout}\n${result.stderr}`)
  return result
}

test("benchmarks isolated normal and prewalk runs and generates comparison reports", () => {
  const root = mkdtempSync(join(tmpdir(), "opencode-prewalk-test-"))
  const repository = join(root, "repository")
  const bin = join(root, "bin")
  const output = join(root, "report")
  const stateFile = join(root, "mock-state.json")
  mkdirSync(repository)
  mkdirSync(bin)
  writeFileSync(join(repository, "fixture.txt"), "before\n")
  run("git", ["init", "--quiet"], { cwd: repository })
  run("git", ["add", "fixture.txt"], { cwd: repository })
  run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "fixture"], { cwd: repository })

  const mock = join(bin, "opencode2")
  writeFileSync(mock, `#!/usr/bin/env node
const fs = require("node:fs")
const args = process.argv.slice(2)
if (args[0] === "service" && args[1] === "start") process.exit(0)
if (args[0] !== "api") process.exit(2)
const dataIndex = args.indexOf("--data")
const payload = dataIndex >= 0 ? JSON.parse(args[dataIndex + 1]) : {}
const methodIndex = args.findIndex(value => value === "GET" || value === "POST")
const method = args[methodIndex]
const route = args[methodIndex + 1]
const statePath = process.env.MOCK_STATE
const send = data => process.stdout.write(JSON.stringify({ data }))
if (method === "POST" && route === "/api/session") {
  const id = payload.title.endsWith("prewalk") ? "session-prewalk" : "session-normal"
  fs.writeFileSync(statePath + "." + id, JSON.stringify({ id, mode: "normal", location: payload.location.directory }))
  send({ id }); process.exit(0)
}
const match = route.match(/^\\/api\\/session\\/([^/]+)(?:\\/(.*))?$/)
if (!match) process.exit(3)
const sessionPath = statePath + "." + match[1]
if (!fs.existsSync(sessionPath)) process.exit(3)
const session = JSON.parse(fs.readFileSync(sessionPath, "utf8"))
const save = () => fs.writeFileSync(sessionPath, JSON.stringify(session))
const suffix = match[2] || ""
if (method === "POST" && suffix === "command") session.mode = "prewalk"
if (method === "POST" && (suffix === "command" || suffix === "prompt")) {
  fs.writeFileSync(session.location + "/fixture.txt", session.mode + " result\\n")
  fs.writeFileSync(session.location + "/created.txt", session.mode + " created\\n")
  save(); send({}); process.exit(0)
}
if (method === "POST" && suffix === "wait") { send({}); process.exit(0) }
const isPrewalk = session.mode === "prewalk"
if (method === "GET" && suffix === "") {
  send({ id: session.id, outcome: "succeeded", cost: isPrewalk ? 0.3 : 0.5,
    tokens: { input: isPrewalk ? 800 : 1000, output: isPrewalk ? 150 : 200, reasoning: 50, cache: { read: 0, write: 0 } } })
  process.exit(0)
}
if (method === "GET" && suffix === "context") {
  const model = isPrewalk
    ? { providerID: "openai", id: "gpt-5.6-luna", variant: "medium" }
    : { providerID: "openai", id: "gpt-5.6-sol", variant: "high" }
  send([{ id: "assistant", type: "assistant", model, finish: "stop", cost: isPrewalk ? 0.3 : 0.5,
    tokens: { input: isPrewalk ? 800 : 1000, output: isPrewalk ? 150 : 200, reasoning: 50, cache: { read: 0, write: 0 } },
    content: [
      { type: "tool", name: isPrewalk ? "patch" : "write", state: { status: "completed" }, time: { created: 1, completed: 3 } },
      { type: "text", text: session.mode + " complete" }
    ] }])
  process.exit(0)
}
process.exit(4)
`)
  chmodSync(mock, 0o755)

  const result = run(benchmark, ["--concurrent", "--output", output, "change the fixture"], {
    cwd: repository,
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, MOCK_STATE: stateFile },
  })
  assert.match(result.stdout, /Benchmark complete/)
  for (const file of ["report.json", "report.md", "report.html", "normal/changes.patch", "prewalk/changes.patch"]) {
    assert.equal(existsSync(join(output, file)), true, `missing ${file}`)
  }
  const report = JSON.parse(readFileSync(join(output, "report.json"), "utf8"))
  assert.equal(report.normal.tokens.input, 1000)
  assert.equal(report.prewalk.tokens.input, 800)
  assert.deepEqual(report.normal.toolCalls, ["write"])
  assert.deepEqual(report.prewalk.toolCalls, ["patch"])
  assert.equal(report.comparison.inputTokensPercent, -20)
  assert.ok(Math.abs(report.normal.cost - 0.009) < 1e-9)
  assert.ok(Math.abs(report.prewalk.cost - 0.0004) < 1e-9)
  assert.equal(report.normal.changedFiles.length, 2)
  assert.equal(report.normal.changedFiles.some((line: string) => line.endsWith("fixture.txt")), true)
  assert.equal(readFileSync(join(repository, "fixture.txt"), "utf8"), "before\n")
  assert.match(readFileSync(join(output, "normal/changes.patch"), "utf8"), /normal created/)
  assert.match(readFileSync(join(output, "report.html"), "utf8"), /Cumulative input tokens over tool calls/)
})
