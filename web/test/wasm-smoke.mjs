// Headless smoke tests for the WebAssembly build.
//
// Runs the real .wasm module through the real web/agent.js glue under Node
// (which ships JSPI), faking only the terminal and fetch(). Two scenarios:
//   1. streaming — prompt/input cycle, SSE parsing across awkward chunk
//      boundaries, thinking + text deltas, auth header and request body
//   2. tools — a canned tool-call turn writes a nested file to the in-memory
//      WASI filesystem and reads it back, proving mkdirRecursive/fopen work
//      against the shim and that tool results flow back to the model
//
// Usage: node web/test/wasm-smoke.mjs [path/to/EmbeddedSwiftAgent.wasm]
// Exit codes: 0 all checks pass, 1 failures, 3 environment can't run it.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SHIM_VERSION = "0.4.2";
const SHIM_FILES = [
  "index.js", "wasi.js", "wasi_defs.js", "fd.js",
  "fs_mem.js", "fs_opfs.js", "strace.js", "debug.js",
];
const CDN_DIST = `https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@${SHIM_VERSION}/dist/`;
const CDN_ESM = `https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@${SHIM_VERSION}/+esm`;

function skip(msg) {
  console.error(`SKIP: ${msg}`);
  process.exit(3);
}

if (typeof WebAssembly.Suspending !== "function") {
  skip("this Node runtime has no JSPI (WebAssembly.Suspending)");
}

const testDir = dirname(fileURLToPath(import.meta.url));
const webDir = resolve(testDir, "..");
const wasmPath = process.argv[2] ?? join(webDir, "EmbeddedSwiftAgent.wasm");
if (!existsSync(wasmPath)) {
  skip(`wasm binary not found at ${wasmPath} (build with 'make wasm')`);
}
const wasmBytes = readFileSync(wasmPath);

// The glue imports the WASI shim from a CDN, which Node can't. Cache the
// pinned dist files locally (first run downloads; later runs are offline)
// and import a copy of agent.js with the import rewritten to the cache.
const cacheDir = join(process.env.TMPDIR ?? "/tmp", `esa-wasi-shim-${SHIM_VERSION}`);
mkdirSync(join(cacheDir, "shim"), { recursive: true });
for (const f of SHIM_FILES) {
  const dest = join(cacheDir, "shim", f);
  if (existsSync(dest)) continue;
  let resp;
  try {
    resp = await fetch(CDN_DIST + f);
  } catch (e) {
    skip(`cannot download WASI shim (${e}) — network needed on first run`);
  }
  if (!resp.ok) skip(`cannot download WASI shim (HTTP ${resp.status} for ${f})`);
  writeFileSync(dest, Buffer.from(await resp.arrayBuffer()));
}

const glueSrc = readFileSync(join(webDir, "agent.js"), "utf8");
if (!glueSrc.includes(CDN_ESM)) {
  skip(`web/agent.js no longer imports the shim from ${CDN_ESM} — update this test`);
}
const gluePath = join(cacheDir, "agent.mjs");
writeFileSync(gluePath, glueSrc.replace(CDN_ESM, "./shim/index.js"));
const { bootAgent } = await import(pathToFileURL(gluePath).href);

// ---- shared helpers

const WASM_URL = "wasm-binary";

function wasmResponse() {
  return {
    ok: true,
    status: 200,
    arrayBuffer: async () =>
      wasmBytes.buffer.slice(wasmBytes.byteOffset, wasmBytes.byteOffset + wasmBytes.byteLength),
  };
}

// Delivers SSE text in deliberately awkward 17-byte chunks to exercise the
// line-splitting and carry logic on both sides of the bridge.
function sseResponse(text) {
  const bytes = new TextEncoder().encode(text);
  const chunks = [];
  for (let i = 0; i < bytes.length; i += 17) {
    chunks.push(bytes.subarray(i, Math.min(i + 17, bytes.length)));
  }
  let idx = 0;
  return {
    ok: true,
    status: 200,
    body: new ReadableStream({
      pull(c) {
        if (idx < chunks.length) c.enqueue(chunks[idx++]);
        else c.close();
      },
    }),
  };
}

function makeTerm() {
  const state = { output: "", onDataCb: null };
  return {
    state,
    term: {
      onData(cb) { state.onDataCb = cb; },
      write(s) { state.output += s; },
    },
  };
}

// Boots the agent, waits for the prompt, types `prompt`, and returns once
// `doneMarker` shows up in the terminal (or the deadline passes).
async function drive({ term, state, env, prompt, doneMarker }) {
  bootAgent({ term, wasmUrl: WASM_URL, env }).catch((e) => {
    state.output += `\n[boot error: ${e}]\n`;
  });

  const deadline = Date.now() + 15000;
  let typed = false;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 50));
    if (!typed && state.output.includes("> ")) {
      typed = true;
      state.onDataCb(prompt);
      state.onDataCb("\r");
    }
    if (typed && state.output.includes(doneMarker)) {
      await new Promise((r) => setTimeout(r, 200)); // let the turn finish
      break;
    }
  }
  return state.output;
}

// ---- scenario 1: streaming turn

async function scenarioStreaming() {
  const SSE = [
    'data: {"choices":[{"delta":{"reasoning":"thinking about it"}}]}',
    "",
    'data: {"choices":[{"delta":{"content":"Hello from the canned stub!"}}]}',
    "",
    'data: {"choices":[{"delta":{"content":" Second chunk."}}]}',
    "",
    "data: [DONE]",
    "",
  ].join("\n");

  let sawAuthHeader = false;
  let requestBodyOk = false;

  globalThis.fetch = async (url, opts) => {
    if (url === WASM_URL) return wasmResponse();
    sawAuthHeader = opts.headers["Authorization"] === "Bearer test-key-123";
    const reqBody = new TextDecoder().decode(opts.body);
    requestBodyOk = reqBody.includes('"model":"test/model"') && reqBody.includes("say hello");
    return sseResponse(SSE);
  };

  const { term, state } = makeTerm();
  const output = await drive({
    term,
    state,
    env: { OPENROUTER_API_KEY: "test-key-123", MODEL: "test/model", REASONING_EFFORT: "low" },
    prompt: "say hello",
    doneMarker: "Second chunk.",
  });

  return {
    name: "streaming",
    output,
    checks: [
      ["prompt printed", output.includes("> ")],
      ["echoed input", output.includes("say hello")],
      ["thinking streamed", output.includes("thinking about it")],
      ["text streamed", output.includes("Hello from the canned stub! Second chunk.")],
      ["prompt re-printed after turn", output.lastIndexOf("> ") > output.indexOf("Second chunk.")],
      ["auth header forwarded", sawAuthHeader],
      ["request body had model + prompt", requestBodyOk],
    ],
  };
}

// ---- scenario 2: tool round trip on the in-memory filesystem

async function scenarioTools() {
  const TOOLCALL_SSE = [
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_w","function":{"name":"write_file","arguments":""}}]}}]}',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"/notes/deep/hi.txt\\",\\"content\\":\\"stored in browser\\"}"}}]}}]}',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_r","function":{"name":"read_file","arguments":"{\\"path\\":\\"/notes/deep/hi.txt\\"}"}}]}}]}',
    "data: [DONE]",
    "",
  ].join("\n");

  const FINAL_SSE = [
    'data: {"choices":[{"delta":{"content":"done writing"}}]}',
    "data: [DONE]",
    "",
  ].join("\n");

  let requestNum = 0;
  let secondRequestBody = "";

  globalThis.fetch = async (url, opts) => {
    if (url === WASM_URL) return wasmResponse();
    requestNum++;
    if (requestNum === 1) return sseResponse(TOOLCALL_SSE);
    secondRequestBody = new TextDecoder().decode(opts.body);
    return sseResponse(FINAL_SSE);
  };

  const { term, state } = makeTerm();
  const output = await drive({
    term,
    state,
    env: { OPENROUTER_API_KEY: "k", MODEL: "test/model", REASONING_EFFORT: "low" },
    prompt: "write then read",
    doneMarker: "done writing",
  });

  return {
    name: "tools",
    output,
    checks: [
      ["write_file rendered", output.includes("[writing: /notes/deep/hi.txt]")],
      ["write_file succeeded", output.includes("wrote 17 bytes to /notes/deep/hi.txt")],
      ["read_file rendered", output.includes("[reading: /notes/deep/hi.txt]")],
      ["read_file returned content", output.includes("1|stored in browser")],
      ["final text streamed", output.includes("done writing")],
      [
        "tool results sent back to model",
        secondRequestBody.includes("stored in browser") &&
          secondRequestBody.includes("call_w") &&
          secondRequestBody.includes("call_r"),
      ],
    ],
  };
}

// ---- run

let failed = false;
for (const result of [await scenarioStreaming(), await scenarioTools()]) {
  let scenarioFailed = false;
  for (const [label, ok] of result.checks) {
    console.log(`${ok ? "PASS" : "FAIL"}: ${result.name} — ${label}`);
    if (!ok) scenarioFailed = true;
  }
  if (scenarioFailed) {
    failed = true;
    console.log(`---- ${result.name} terminal output ----`);
    console.log(JSON.stringify(result.output));
  }
}

process.exit(failed ? 1 : 0);
