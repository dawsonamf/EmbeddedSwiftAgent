# EmbeddedSwiftAgent — TODO

## 1. Tool argument validation

Validate tool call arguments against the tool's JSON schema before executing. Return error tool results to the model on validation failure instead of crashing or executing with bad args.

## 2. Server API

HTTP/WebSocket API exposing the two-layer event stream. Clients can start sessions, send messages, receive typed `AgentEvent`s, and steer/interrupt/stop via API calls.

## 3. Hook / extension system

Named hook points at every decision point in the agent loop. `transformContext` is the most important to add early. See [plan](plans/hook-extension-system.md).

## 4. AGENTS.md & SYSTEM_PROMPT.md support

Auto-load `AGENTS.md` from repo root and global config path into context. Support `SYSTEM_PROMPT.md` as the agent's system prompt with repo-level rules appended.

## 5. Skills support

Skill discovery, auto-loading of headers into context, full loading via slash command or agent-initiated. Skills are markdown instruction files — just context management, no special runtime.

## 6. Message-level rollback

Implement the ability to roll back the entire codebase/file environment to the state it was in at a given message. Each message (or tool execution) should snapshot the file-system changes it introduced, allowing the user to revert all changes back to any prior message boundary. This enables undo-style workflows where the user can say "roll back to message N" and have every file restored to its state at that point.