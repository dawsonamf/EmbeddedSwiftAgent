// Browser host for the EmbeddedSwiftAgent wasm build.
//
// Three responsibilities:
//   1. WASI syscalls (stdio + in-memory filesystem) via @bjorn3/browser_wasi_shim
//   2. The "agent" import module: an HTTP bridge over fetch() plus an input
//      queue. The async imports are wrapped in WebAssembly.Suspending (JSPI),
//      so the fully synchronous Swift agent loop can "block" in the browser —
//      the wasm stack suspends while the browser awaits network or keystrokes.
//   3. xterm.js wiring: line editing at the prompt, Ctrl+C abort while running.

import {
  WASI,
  WASIProcExit,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/+esm";

export function jspiSupported() {
  return (
    typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function"
  );
}

// env: object of WASI environment variables (OPENROUTER_API_KEY, MODEL, ...).
export async function bootAgent({ term, wasmUrl, env }) {
  const textEncoder = new TextEncoder();

  let instance = null;

  // ---- wasm memory helpers (always read the live buffer: it moves on grow)

  function memBytes(ptr, len) {
    return new Uint8Array(instance.exports.memory.buffer, ptr, len);
  }

  function readString(ptr, len) {
    return new TextDecoder().decode(memBytes(ptr, len).slice());
  }

  function writeBytes(ptr, cap, bytes) {
    const n = Math.min(cap, bytes.length);
    memBytes(ptr, n).set(bytes.subarray(0, n));
    return n;
  }

  // ---- input queue (prompt <-> Swift handoff)

  // agentRunning is derived from the Swift loop itself: false while it is
  // suspended in input_wait (parked at the prompt), true otherwise.
  let agentRunning = true;
  let abortRequested = false;

  const inputQueue = [];
  let inputWaiter = null; // resolve fn of a pending input_wait promise
  let pendingInput = null; // Uint8Array staged for input_read

  async function inputWait() {
    agentRunning = false;
    abortRequested = false;
    let line;
    if (inputQueue.length > 0) {
      line = inputQueue.shift();
    } else {
      line = await new Promise((resolve) => {
        inputWaiter = resolve;
      });
    }
    pendingInput = textEncoder.encode(line);
    agentRunning = true;
    return pendingInput.length;
  }

  function inputRead(bufPtr, bufCap) {
    if (!pendingInput) return 0;
    const n = writeBytes(bufPtr, bufCap, pendingInput);
    pendingInput = null;
    return n;
  }

  function submitLine(line) {
    if (inputWaiter) {
      const w = inputWaiter;
      inputWaiter = null;
      w(line);
    } else {
      inputQueue.push(line);
    }
  }

  // ---- HTTP bridge (fetch-backed; mirrors the libcurl seam)

  let nextHandle = 1;
  const httpHandles = new Map();

  async function httpBegin(urlPtr, urlLen, hdrPtr, hdrLen, bodyPtr, bodyLen) {
    // Copy the request out of wasm memory before the first await.
    const url = readString(urlPtr, urlLen);
    const headerBlob = readString(hdrPtr, hdrLen);
    const body = memBytes(bodyPtr, bodyLen).slice();

    const handle = nextHandle++;
    const state = {
      reader: null,
      carry: null,
      status: -1,
      error: null,
      controller: new AbortController(),
      done: false,
    };
    httpHandles.set(handle, state);

    if (abortRequested) {
      state.error = "aborted";
      return handle;
    }

    const headers = {};
    for (const line of headerBlob.split("\n")) {
      const idx = line.indexOf(": ");
      if (idx > 0) headers[line.slice(0, idx)] = line.slice(idx + 2);
    }

    try {
      const resp = await fetch(url, {
        method: "POST",
        headers,
        body,
        signal: state.controller.signal,
      });
      state.status = resp.status;
      state.reader = resp.body ? resp.body.getReader() : null;
    } catch (e) {
      state.error = e && e.name === "AbortError" ? "aborted" : String(e);
    }
    return handle;
  }

  function httpStatus(handle) {
    const state = httpHandles.get(handle);
    return state ? state.status : -1;
  }

  async function httpNextChunk(handle, bufPtr, bufCap) {
    const state = httpHandles.get(handle);
    if (!state) return -1;

    // Drain any bytes left over from a chunk larger than the Swift buffer.
    if (state.carry && state.carry.length > 0) {
      const n = writeBytes(bufPtr, bufCap, state.carry);
      state.carry = state.carry.length > n ? state.carry.subarray(n) : null;
      return n;
    }

    if (state.done || !state.reader) {
      if (state.error) return state.error === "aborted" ? -2 : -1;
      return 0; // end of stream (or empty body)
    }

    try {
      const { done, value } = await state.reader.read();
      if (done) {
        state.done = true;
        return 0;
      }
      const n = writeBytes(bufPtr, bufCap, value);
      if (value.length > n) state.carry = value.subarray(n);
      return n;
    } catch (e) {
      state.done = true;
      if ((e && e.name === "AbortError") || abortRequested) return -2;
      state.error = String(e);
      return -1;
    }
  }

  function httpErrorMsg(handle, bufPtr, bufCap) {
    const state = httpHandles.get(handle);
    if (!state || !state.error) return 0;
    return writeBytes(bufPtr, bufCap, textEncoder.encode(state.error));
  }

  function httpClose(handle) {
    const state = httpHandles.get(handle);
    if (!state) return;
    if (state.reader) {
      state.reader.cancel().catch(() => {});
    }
    httpHandles.delete(handle);
  }

  // ---- terminal wiring

  let lineBuf = "";

  term.onData((data) => {
    // Swallow escape sequences (arrow keys etc.) — no line-history support.
    if (data.startsWith("\x1b")) return;

    for (const ch of data) {
      const code = ch.codePointAt(0);

      if (code === 0x03) {
        // Ctrl+C
        if (agentRunning) {
          abortRequested = true;
          // agent_abort only writes a C global, so it's safe to call while
          // the main wasm stack is suspended via JSPI.
          try {
            instance.exports.agent_abort();
          } catch (_) {}
          for (const st of httpHandles.values()) {
            try {
              st.controller.abort();
            } catch (_) {}
          }
        } else {
          lineBuf = "";
          term.write("^C\r\n\x1b[1m> \x1b[0m");
        }
        continue;
      }

      if (agentRunning) continue; // typing during a turn isn't wired up

      if (ch === "\r" || ch === "\n") {
        term.write("\r\n");
        const line = lineBuf;
        lineBuf = "";
        submitLine(line);
      } else if (code === 0x7f || code === 0x08) {
        if (lineBuf.length > 0) {
          lineBuf = lineBuf.slice(0, -1);
          term.write("\b \b");
        }
      } else if (code >= 0x20) {
        lineBuf += ch;
        term.write(ch);
      }
    }
  });

  // ---- WASI setup

  function makeConsoleFd() {
    const decoder = new TextDecoder("utf-8", { fatal: false });
    return new ConsoleStdout((buf) => {
      // term.write handles LF -> CRLF via convertEol.
      term.write(decoder.decode(buf, { stream: true }));
    });
  }

  // In-memory filesystem, preopened as both "/" and "." so absolute and
  // relative paths from the file tools resolve to the same tree.
  const fsContents = new Map([
    [
      "hello.txt",
      new File(
        textEncoder.encode(
          "This file lives in an in-memory filesystem inside your browser tab.\n" +
            "Ask the agent to read it, edit it, or write new files.\n"
        )
      ),
    ],
  ]);

  const envStrings = Object.entries(env)
    .filter(([, v]) => v)
    .map(([k, v]) => `${k}=${v}`);

  // Note: the shim treats an undefined debug option as ON — pass false.
  const wasi = new WASI(
    ["EmbeddedSwiftAgent"],
    envStrings,
    [
      new OpenFile(new File([])), // stdin (unused — input comes via the bridge)
      makeConsoleFd(), // stdout
      makeConsoleFd(), // stderr
      new PreopenDirectory("/", fsContents),
      new PreopenDirectory(".", fsContents),
    ],
    { debug: false }
  );

  // ---- instantiate & run

  const suspending = (fn) => new WebAssembly.Suspending(fn);

  const imports = {
    wasi_snapshot_preview1: wasi.wasiImport,
    agent: {
      http_begin: suspending(httpBegin),
      http_status: httpStatus,
      http_next_chunk: suspending(httpNextChunk),
      http_error_msg: httpErrorMsg,
      http_close: httpClose,
      input_wait: suspending(inputWait),
      input_read: inputRead,
    },
  };

  const resp = await fetch(wasmUrl);
  if (!resp.ok) {
    throw new Error(`failed to fetch ${wasmUrl}: HTTP ${resp.status}`);
  }
  const bytes = await resp.arrayBuffer();
  ({ instance } = await WebAssembly.instantiate(bytes, imports));

  // wasi.start() would call _start synchronously; we need the JSPI-wrapped
  // version instead, so replicate its one line of setup and call it ourselves.
  wasi.inst = instance;
  const start = WebAssembly.promising(instance.exports._start);

  try {
    await start();
    term.write("\r\n\x1b[2m[agent exited]\x1b[0m\r\n");
  } catch (e) {
    if (e instanceof WASIProcExit) {
      term.write(`\r\n\x1b[2m[agent exited with code ${e.code}]\x1b[0m\r\n`);
    } else {
      term.write(`\r\n\x1b[31m[agent crashed: ${e}]\x1b[0m\r\n`);
      throw e;
    }
  }
}
