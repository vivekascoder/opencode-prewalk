import assert from "node:assert/strict"
import test from "node:test"

import prewalk, { EXECUTOR_NUDGE, PLANNING_NUDGE } from "../src/index.js"

interface Harness {
  command: (input: {
    sessionID: string
    prompt: { text: string }
    delivery: "steer" | "queue"
  }) => Promise<void>
  context: (event: {
    sessionID: string
    system: Array<{ type: "text"; text: string }>
    messages: Array<{
      role: "user" | "assistant"
      content: Array<{ type: "text"; text: string }>
    }>
  }) => void
  after: (event: {
    sessionID: string
    tool: string
    status: "completed" | "error"
    error?: { message: string }
  }) => Promise<void>
  switched: Array<{ sessionID: string; model: { providerID: string; id: string; variant?: string } }>
  prompted: Array<Record<string, unknown>>
  notices: string[]
  todoTool?: { execute: (input: { items: string[] }) => Promise<{ content: string }> }
  cleanup: () => Promise<void>
  disposed: { count: number }
}

async function harness(options: Record<string, unknown> = {}): Promise<Harness> {
  let command: Harness["command"] | undefined
  let context: Harness["context"] | undefined
  let after: Harness["after"] | undefined
  let todoTool: Harness["todoTool"]
  const switched: Harness["switched"] = []
  const prompted: Harness["prompted"] = []
  const notices: string[] = []
  const disposed = { count: 0 }
  const registration = () => ({ dispose: async () => void (disposed.count += 1) })

  const ctx = {
    options,
    session: {
      hook: async (name: string, callback: unknown) => {
        assert.equal(name, "context")
        context = callback as Harness["context"]
        return registration()
      },
      switchModel: async (input: Harness["switched"][number]) => void switched.push(input),
      prompt: async (input: Record<string, unknown>) => {
        prompted.push(input)
        return {}
      },
      synthetic: async (input: { text: string }) => void notices.push(input.text),
    },
    tool: {
      transform: async (callback: (draft: { add: (tool: Harness["todoTool"]) => void }) => void) => {
        callback({ add: (tool) => void (todoTool = tool) })
        return registration()
      },
      hook: async (name: string, callback: unknown) => {
        assert.equal(name, "execute.after")
        after = callback as Harness["after"]
        return registration()
      },
    },
    command: {
      transform: async (callback: (draft: { add: (definition: { execute: Harness["command"] }) => void }) => void) => {
        callback({ add: (definition) => void (command = definition.execute) })
        return registration()
      },
    },
  }

  const cleanup = await prewalk.setup(ctx as never)
  assert.ok(command && context && after && cleanup)
  return {
    command,
    context,
    after,
    switched,
    prompted,
    notices,
    todoTool,
    cleanup: async () => void (await cleanup()),
    disposed,
  }
}

test("uses Sol for planning and switches to Luna only after todo plus a successful edit", async () => {
  const h = await harness()
  await h.command({ sessionID: "s1", prompt: { text: "fix the tests" }, delivery: "steer" })

  assert.deepEqual(h.switched[0], {
    sessionID: "s1",
    model: { providerID: "openai", id: "gpt-5.6-sol", variant: "high" },
  })
  assert.equal(h.prompted[0]?.text, "fix the tests")
  assert.deepEqual(h.prompted[0]?.files, [])
  assert.deepEqual(h.prompted[0]?.agents, [])
  assert.deepEqual(h.prompted[0]?.skills, [])

  const planningContext = {
    sessionID: "s1",
    system: [] as Array<{ type: "text"; text: string }>,
    messages: [],
  }
  h.context(planningContext)
  assert.equal(planningContext.system[0]?.text, PLANNING_NUDGE)

  await h.after({ sessionID: "s1", tool: "bash", status: "completed" })
  await h.after({ sessionID: "s1", tool: "apply_patch", status: "completed" })
  assert.equal(h.switched.length, 1)

  const todo = await h.todoTool?.execute({ items: ["Edit", "Validate"] })
  assert.equal(todo?.content, "1. Edit\n2. Validate")
  await h.after({ sessionID: "s1", tool: "prewalk_todo", status: "completed" })
  await h.after({ sessionID: "s1", tool: "apply_patch", status: "error", error: { message: "nope" } })
  assert.equal(h.switched.length, 1)

  await h.after({ sessionID: "s1", tool: "functions.apply-patch", status: "completed" })
  assert.deepEqual(h.switched[1], {
    sessionID: "s1",
    model: { providerID: "openai", id: "gpt-5.6-luna", variant: "medium" },
  })

  const executorContext = {
    sessionID: "s1",
    system: [] as Array<{ type: "text"; text: string }>,
    messages: [],
  }
  h.context(executorContext)
  assert.equal(executorContext.system[0]?.text, EXECUTOR_NUDGE)
  assert.ok(!executorContext.system.some((part) => part.text === PLANNING_NUDGE))

  const laterContext = {
    sessionID: "s1",
    system: [] as Array<{ type: "text"; text: string }>,
    messages: [],
  }
  h.context(laterContext)
  assert.deepEqual(laterContext.system, [])
  await h.cleanup()
  assert.equal(h.disposed.count, 4)
})

test("supports overrides, status, and disarming", async () => {
  const h = await harness({
    planner: "openai/planner",
    executor: "openai/executor",
    plannerVariant: "max",
    executorVariant: "low",
  })

  await h.command({ sessionID: "s2", prompt: { text: "" }, delivery: "queue" })
  assert.equal(h.switched[0]?.model.id, "planner")
  assert.match(h.notices.at(-1) ?? "", /armed/)

  await h.command({ sessionID: "s2", prompt: { text: "status" }, delivery: "queue" })
  assert.equal(h.notices.at(-1), "Prewalk is planning.")
  await h.command({ sessionID: "s2", prompt: { text: "off" }, delivery: "queue" })

  const context = {
    sessionID: "s2",
    system: [] as Array<{ type: "text"; text: string }>,
    messages: [],
  }
  h.context(context)
  assert.deepEqual(context.system, [])
})
