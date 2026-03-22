# SwiftCodeEmbedded — TODO

## 1. Model selection via CLI flag

Add a `--model` flag so the user can choose which model to use at launch. Update `test.sh` to use a cheap/free model by default with an override option.

## 2. Tool argument validation

Validate tool call arguments against the tool's JSON schema before executing. Return error tool results to the model on validation failure instead of crashing or executing with bad args.

## 3. Server API

HTTP/WebSocket API exposing the two-layer event stream. Clients can start sessions, send messages, receive typed `AgentEvent`s, and steer/interrupt/stop via API calls.

## 4. Hook / extension system

Named hook points at every decision point in the agent loop. `transformContext` is the most important to add early. See [plan](plans/hook-extension-system.md).

## 5. AGENTS.md & SYSTEM_PROMPT.md support

Auto-load `AGENTS.md` from repo root and global config path into context. Support `SYSTEM_PROMPT.md` as the agent's system prompt with repo-level rules appended.

## 6. Skills support

Skill discovery, auto-loading of headers into context, full loading via slash command or agent-initiated. Skills are markdown instruction files — just context management, no special runtime.