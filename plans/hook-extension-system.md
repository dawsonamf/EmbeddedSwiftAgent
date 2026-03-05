# Hook / Extension System

Design an extension system with named hook points at every decision point in the agent loop. Based on pi-mono's architecture.

## Hook points

| Hook | When | Purpose |
|------|------|---------|
| `beforeAgentStart` | Before the agent loop begins | Add custom messages, replace system prompt for this run |
| `afterAgentEnd` | After the agent loop finishes | Cleanup, logging, persistence |
| `beforeTurnStart` | Before each LLM call | Modify context, inject messages |
| `afterTurnEnd` | After each turn completes | Logging, analytics |
| `transformContext` | Before every LLM call | Modify the message array (compaction, pruning, injection) |
| `toolCall` | Before tool execution | Block or allow tool execution (permission system) |
| `toolResult` | After tool execution | Modify tool results before feeding back to model |
| `input` | When user input is received | Transform or intercept user input |

## Extension registration

Extensions should be able to:

- `registerTool()` — add custom tools to the agent
- `registerCommand()` — add slash commands
- `registerHook()` — subscribe to hook points

## Implementation notes

- Extensions are loaded from a standard directory (e.g. `~/.config/swiftcode/extensions/`)
- The `transformContext` hook is the most important one to add early — it's the clean place for context compaction, token budgeting, and message filtering without touching the core loop
- Start with just `transformContext` as an internal hook, expand to the full system later
