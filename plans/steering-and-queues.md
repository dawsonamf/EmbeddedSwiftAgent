# Steering & Follow-Up Queues

Implement two message queues that the agent loop checks at natural breakpoints.

## Steering queue

- Checked **between tool executions** within a turn.
- When a steering message is found: skip remaining tool calls (with synthetic results), inject the steering message, and start a new turn.
- This is how the user redirects the agent mid-work.
- Requires an async stdin reader or input thread that can accept input while the agent loop is running.

## Follow-up queue

- Checked **after the agent loop would normally stop** (model returned text with no tool calls).
- When a follow-up message is found: start a new outer loop iteration with the follow-up as the next user message.
- This is how the user queues up messages while the agent is still responding.

## Hard stop (abort)

- An `AbortSignal`-style mechanism. The agent loop, `OpenRouterClient`, and tool execution all receive a signal.
- On abort: cancel the HTTP stream, stop tool execution, emit `agentEnd`, return to prompt.
- Separate from steering — steering redirects, abort cancels entirely.

## Input architecture

The CLI needs to accept input while the agent is working. Options:

- **Async stdin reader** — a background task that reads stdin and pushes to the steering/follow-up queues
- **Signal-based** — Ctrl+C triggers abort, typed text during agent run goes to steering queue
- Research how Claude Code handles this (likely a separate input thread with raw terminal mode)
