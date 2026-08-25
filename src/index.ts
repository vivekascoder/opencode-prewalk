import { Plugin } from "@opencode-ai/plugin"

type Context = Plugin.Context

export interface PrewalkOptions {
  planner?: string
  executor?: string
  plannerVariant?: string
  executorVariant?: string
  todoTools?: string[]
  editTools?: string[]
}

interface ModelRef {
  providerID: string
  id: string
  variant?: string
}

interface SessionState {
  phase: "planning" | "switching" | "executing"
  hasTodo: boolean
  executorNudgePending: boolean
}

const DEFAULTS = {
  planner: "opencode/gpt-5.6-sol",
  executor: "opencode/gpt-5.6-luna",
  plannerVariant: "high",
  executorVariant: "medium",
  todoTools: ["todo", "todowrite", "todo_write", "update_todo", "update_plan"],
  editTools: ["edit", "write", "apply_patch", "multiedit"],
} as const

export const PLANNING_NUDGE = `You are in the planning phase of a Prewalk run.
Explore the repository deeply enough to understand the task and its constraints. Before editing, create a compact todo list with at most 8 items. Include validation in the relevant items. Then begin implementing the first item yourself. Do not stop after merely describing a plan.`

export const EXECUTOR_NUDGE = `Continue the implementation already in progress. Follow and maintain the existing todo list, complete every remaining item, and run the planned validation before declaring the task finished.`

function normalizeToolName(name: string): string {
  const unqualified = name.toLowerCase().split(/[.:/]/).at(-1) ?? name
  return unqualified.replaceAll("-", "_")
}

function toolSet(values: readonly string[]): Set<string> {
  return new Set(values.map(normalizeToolName))
}

export function parseModel(value: string, variant?: string): ModelRef {
  const slash = value.indexOf("/")
  if (slash <= 0 || slash === value.length - 1) {
    throw new Error(`Expected a model in provider/model form, received ${JSON.stringify(value)}`)
  }
  return {
    providerID: value.slice(0, slash),
    id: value.slice(slash + 1),
    ...(variant ? { variant } : {}),
  }
}

function optionString(options: Context["options"], key: keyof PrewalkOptions, fallback: string): string {
  const value = options[key]
  return typeof value === "string" && value.trim() ? value.trim() : fallback
}

function optionStrings(
  options: Context["options"],
  key: keyof PrewalkOptions,
  fallback: readonly string[],
): readonly string[] {
  const value = options[key]
  return Array.isArray(value) && value.every((item) => typeof item === "string") ? value : fallback
}

async function notify(ctx: Context, sessionID: string, text: string): Promise<void> {
  await ctx.session.synthetic({
    sessionID,
    text,
    description: "Prewalk",
    metadata: { plugin: "opencode-prewalk" },
  })
}

export function createPrewalkPlugin() {
  return Plugin.define({
    id: "prewalk",
    async setup(ctx) {
      const planner = parseModel(
        optionString(ctx.options, "planner", DEFAULTS.planner),
        optionString(ctx.options, "plannerVariant", DEFAULTS.plannerVariant),
      )
      const executor = parseModel(
        optionString(ctx.options, "executor", DEFAULTS.executor),
        optionString(ctx.options, "executorVariant", DEFAULTS.executorVariant),
      )
      const todoTools = toolSet(optionStrings(ctx.options, "todoTools", DEFAULTS.todoTools))
      const editTools = toolSet(optionStrings(ctx.options, "editTools", DEFAULTS.editTools))
      const sessions = new Map<string, SessionState>()

      const contextRegistration = await ctx.session.hook("context", (event) => {
        const state = sessions.get(event.sessionID)
        if (state?.phase === "planning") event.system.push({ type: "text", text: PLANNING_NUDGE })
        if (state?.phase === "executing" && state.executorNudgePending) {
          event.system.push({ type: "text", text: EXECUTOR_NUDGE })
          state.executorNudgePending = false
        }
      })

      const toolRegistration = await ctx.tool.hook("execute.after", async (event) => {
        if (event.status !== "completed") return
        const state = sessions.get(event.sessionID)
        if (!state || state.phase !== "planning") return

        const name = normalizeToolName(event.tool)
        if (todoTools.has(name)) {
          state.hasTodo = true
          return
        }
        if (!state.hasTodo || !editTools.has(name)) return

        state.phase = "switching"
        try {
          await ctx.session.switchModel({ sessionID: event.sessionID, model: executor })
          state.phase = "executing"
          state.executorNudgePending = true
          await notify(ctx, event.sessionID, `Prewalk handoff: ${executor.providerID}/${executor.id} will continue this session.`)
        } catch (error) {
          state.phase = "planning"
          throw error
        }
      })

      const commandRegistration = await ctx.command.transform((draft) => {
        draft.add({
          name: "prewalk",
          description: "Plan with GPT-5.6 Sol, then switch to GPT-5.6 Luna after the first todo-gated edit",
          execute: async ({ sessionID, prompt, delivery }) => {
            const input = prompt.text.trim()
            if (input === "status") {
              const state = sessions.get(sessionID)
              const status = state ? state.phase : "off"
              await notify(ctx, sessionID, `Prewalk is ${status}.`)
              return
            }
            if (input === "off") {
              sessions.delete(sessionID)
              await notify(ctx, sessionID, "Prewalk is off.")
              return
            }

            sessions.set(sessionID, {
              phase: "planning",
              hasTodo: false,
              executorNudgePending: false,
            })
            await ctx.session.switchModel({ sessionID, model: planner })

            if (!input) {
              await notify(ctx, sessionID, `Prewalk armed with ${planner.providerID}/${planner.id}. Send the task when ready.`)
              return
            }

            await ctx.session.prompt({
              ...prompt,
              sessionID,
              text: input,
              delivery,
            })
          },
        })
      })

      return async () => {
        sessions.clear()
        await Promise.all([
          contextRegistration.dispose(),
          toolRegistration.dispose(),
          commandRegistration.dispose(),
        ])
      }
    },
  })
}

export default createPrewalkPlugin()
