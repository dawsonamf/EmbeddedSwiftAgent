#ifndef CSTDIO_H
#define CSTDIO_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/stat.h>

#ifndef __wasi__
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pthread.h>
#include <termios.h>
#endif

char **get_environ(void);

void flush_stdout(void);
void write_stderr(const char *msg);

/// Reads a line from stdin into a malloc'd buffer (caller must free).
/// Returns NULL on EOF. Strips the trailing newline.
char *read_line_stdin(void);

/// Wrapper around rand() — Darwin marks it __swift_unavailable.
int c_rand(void);

/// mkdir wrapper: creates `path` with mode 0755.
/// Returns 0 on success or if the path already exists, -1 otherwise.
int sc_mkdir(const char *path);

typedef void *(*sc_thread_callback_t)(void *);

void *sc_thread_create(sc_thread_callback_t callback, void *context);
void sc_thread_join(void *thread_handle);

void *sc_mutex_create(void);
void sc_mutex_lock(void *mutex_handle);
void sc_mutex_unlock(void *mutex_handle);
void sc_mutex_destroy(void *mutex_handle);

void *sc_cond_create(void);
void sc_cond_signal(void *cond_handle);
void sc_cond_timedwait(void *cond_handle, void *mutex_handle, int timeout_ms);
void sc_cond_destroy(void *cond_handle);

void *sc_atomic_flag_create(void);
void sc_atomic_flag_set(void *flag_handle);
int sc_atomic_flag_read(void *flag_handle);
void sc_atomic_flag_reset(void *flag_handle);
void sc_atomic_flag_destroy(void *flag_handle);

void sc_install_sigint_handler(void *flag_handle);

int sc_get_argc(void);
const char *sc_get_argv(int index);

/// Switches stdin to raw mode (no echo, no canonical buffering).
/// Saves the original termios so sc_disable_raw_mode() can restore it.
void sc_enable_raw_mode(void);

/// Restores the original termios saved by sc_enable_raw_mode().
void sc_disable_raw_mode(void);

/// Reads a single byte from stdin. Returns the byte (0–255) or -1 on EOF/error.
int sc_read_byte_stdin(void);

#ifdef __wasi__

// MARK: - Browser host bridge (wasm build only)
//
// Imports provided by the JS host (web/agent.js) under module "agent".
// The async ones (http_begin, http_next_chunk, input_wait) are wrapped in
// WebAssembly.Suspending on the JS side, so calling them suspends the wasm
// stack via JSPI while the browser awaits fetch/user input — the Swift code
// stays fully synchronous.

/// Starts an HTTP POST via fetch(). `headers` is "Key: Value\n" lines.
/// Suspends until response headers arrive (or the request fails).
/// Always returns a handle; check agent_http_status for the outcome.
__attribute__((import_module("agent"), import_name("http_begin")))
extern int32_t agent_http_begin(const uint8_t *url, int32_t url_len,
                                const uint8_t *headers, int32_t headers_len,
                                const uint8_t *body, int32_t body_len);

/// HTTP status of the response, or -1 if the request failed before headers.
__attribute__((import_module("agent"), import_name("http_status")))
extern int32_t agent_http_status(int32_t handle);

/// Copies up to `cap` response-body bytes into `buf`. Returns the byte count,
/// 0 at end of stream, -1 on network error, -2 if aborted by the user.
__attribute__((import_module("agent"), import_name("http_next_chunk")))
extern int32_t agent_http_next_chunk(int32_t handle, uint8_t *buf, int32_t cap);

/// Copies the error message for `handle` into `buf`; returns its byte length.
__attribute__((import_module("agent"), import_name("http_error_msg")))
extern int32_t agent_http_error_msg(int32_t handle, uint8_t *buf, int32_t cap);

__attribute__((import_module("agent"), import_name("http_close")))
extern void agent_http_close(int32_t handle);

/// Suspends until the user submits a line in the browser terminal.
/// Returns the line's UTF-8 byte length; agent_input_read collects the bytes.
__attribute__((import_module("agent"), import_name("input_wait")))
extern int32_t agent_input_wait(void);

__attribute__((import_module("agent"), import_name("input_read")))
extern int32_t agent_input_read(uint8_t *buf, int32_t cap);

/// Exported to JS as "agent_abort": the browser calls it on Ctrl+C.
void agent_abort(void);

/// Whether the browser requested an abort since the last clear.
int sc_wasm_abort_pending(void);
void sc_wasm_abort_clear(void);

#endif // __wasi__

#endif
