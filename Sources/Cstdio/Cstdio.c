#include "include/Cstdio.h"
#include <errno.h>
#include <time.h>

#ifndef __wasi__
#include <termios.h>
#endif

#ifdef __APPLE__
#include <crt_externs.h>
#endif

// MARK: - Common (all platforms)

void flush_stdout(void) {
    fflush(stdout);
}

void write_stderr(const char *msg) {
    fputs(msg, stderr);
}

extern char **environ;
char **get_environ(void) {
    return environ;
}

int c_rand(void) {
    return rand();
}

char *read_line_stdin(void) {
    char *line = NULL;
    size_t cap = 0;
    ssize_t len = getline(&line, &cap, stdin);
    if (len < 0) {
        free(line);
        return NULL;
    }
    if (len > 0 && line[len - 1] == '\n') {
        line[len - 1] = '\0';
    }
    return line;
}

int sc_mkdir(const char *path) {
    if (mkdir(path, 0755) == 0 || errno == EEXIST) {
        return 0;
    }
    return -1;
}

int sc_read_byte_stdin(void) {
    unsigned char c;
    ssize_t n = read(STDIN_FILENO, &c, 1);
    if (n <= 0) return -1;
    return (int)c;
}

// MARK: - Atomic flag (all platforms)
//
// sig_atomic_t so it's safe to set from a SIGINT handler on native. WASI has
// no signals (and no signal.h without emulation shims), so a plain int —
// the module is single-threaded there anyway.

#ifdef __wasi__
typedef volatile int sc_flag_t;
#else
typedef volatile sig_atomic_t sc_flag_t;
#endif

void *sc_atomic_flag_create(void) {
    sc_flag_t *flag = (sc_flag_t *)malloc(sizeof(sc_flag_t));
    if (flag == NULL) {
        return NULL;
    }
    *flag = 0;
    return (void *)flag;
}

void sc_atomic_flag_set(void *flag_handle) {
    if (flag_handle == NULL) {
        return;
    }
    sc_flag_t *flag = (sc_flag_t *)flag_handle;
    *flag = 1;
}

int sc_atomic_flag_read(void *flag_handle) {
    if (flag_handle == NULL) {
        return 0;
    }
    sc_flag_t *flag = (sc_flag_t *)flag_handle;
    return *flag;
}

void sc_atomic_flag_reset(void *flag_handle) {
    if (flag_handle == NULL) {
        return;
    }
    sc_flag_t *flag = (sc_flag_t *)flag_handle;
    *flag = 0;
}

void sc_atomic_flag_destroy(void *flag_handle) {
    if (flag_handle == NULL) {
        return;
    }
    free(flag_handle);
}

#ifdef __wasi__

// MARK: - WASI stubs
//
// The wasm module is single-threaded: sc_thread_create reports failure, which
// makes callers (parallel tools, input reader) fall back to inline execution
// with zero Swift changes. Mutex/cond handles become inert allocations so the
// shared Swift code runs unchanged.

void *sc_thread_create(sc_thread_callback_t callback, void *context) {
    (void)callback;
    (void)context;
    return NULL;
}

void sc_thread_join(void *thread_handle) {
    (void)thread_handle;
}

void *sc_mutex_create(void) {
    return malloc(1);
}

void sc_mutex_lock(void *mutex_handle) {
    (void)mutex_handle;
}

void sc_mutex_unlock(void *mutex_handle) {
    (void)mutex_handle;
}

void sc_mutex_destroy(void *mutex_handle) {
    free(mutex_handle);
}

void *sc_cond_create(void) {
    return malloc(1);
}

void sc_cond_signal(void *cond_handle) {
    (void)cond_handle;
}

void sc_cond_timedwait(void *cond_handle, void *mutex_handle, int timeout_ms) {
    (void)cond_handle;
    (void)mutex_handle;
    (void)timeout_ms;
}

void sc_cond_destroy(void *cond_handle) {
    free(cond_handle);
}

// No signals on WASI — abort arrives through the agent_abort export instead.
void sc_install_sigint_handler(void *flag_handle) {
    (void)flag_handle;
}

// No argv in the browser — configuration comes in as WASI env vars.
int sc_get_argc(void) {
    return 0;
}

const char *sc_get_argv(int index) {
    (void)index;
    return NULL;
}

// No termios on WASI; xterm.js handles all key input on the JS side.
void sc_enable_raw_mode(void) {}
void sc_disable_raw_mode(void) {}

// MARK: - Browser abort bridge
//
// The JS host calls the agent_abort export when the user hits Ctrl+C while
// the agent is running. It only writes a C global (no allocator, no Swift
// runtime), so it's safe to call while the main wasm stack is suspended via
// JSPI. The Swift HTTP layer polls it at chunk boundaries.

static volatile int g_wasm_abort = 0;

__attribute__((export_name("agent_abort")))
void agent_abort(void) {
    g_wasm_abort = 1;
}

int sc_wasm_abort_pending(void) {
    return g_wasm_abort;
}

void sc_wasm_abort_clear(void) {
    g_wasm_abort = 0;
}

#else // !__wasi__

// MARK: - Native threads (pthreads)

void *sc_thread_create(sc_thread_callback_t callback, void *context) {
    if (callback == NULL) {
        return NULL;
    }

    pthread_t *thread = (pthread_t *)malloc(sizeof(pthread_t));
    if (thread == NULL) {
        return NULL;
    }

    if (pthread_create(thread, NULL, callback, context) != 0) {
        free(thread);
        return NULL;
    }
    return thread;
}

void sc_thread_join(void *thread_handle) {
    if (thread_handle == NULL) {
        return;
    }
    pthread_t *thread = (pthread_t *)thread_handle;
    pthread_join(*thread, NULL);
    free(thread);
}

void *sc_mutex_create(void) {
    pthread_mutex_t *mutex = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));
    if (mutex == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(mutex, NULL) != 0) {
        free(mutex);
        return NULL;
    }
    return mutex;
}

void sc_mutex_lock(void *mutex_handle) {
    if (mutex_handle == NULL) {
        return;
    }
    pthread_mutex_lock((pthread_mutex_t *)mutex_handle);
}

void sc_mutex_unlock(void *mutex_handle) {
    if (mutex_handle == NULL) {
        return;
    }
    pthread_mutex_unlock((pthread_mutex_t *)mutex_handle);
}

void sc_mutex_destroy(void *mutex_handle) {
    if (mutex_handle == NULL) {
        return;
    }
    pthread_mutex_t *mutex = (pthread_mutex_t *)mutex_handle;
    pthread_mutex_destroy(mutex);
    free(mutex);
}

void *sc_cond_create(void) {
    pthread_cond_t *cond = (pthread_cond_t *)malloc(sizeof(pthread_cond_t));
    if (cond == NULL) {
        return NULL;
    }
    if (pthread_cond_init(cond, NULL) != 0) {
        free(cond);
        return NULL;
    }
    return cond;
}

void sc_cond_signal(void *cond_handle) {
    if (cond_handle == NULL) {
        return;
    }
    pthread_cond_signal((pthread_cond_t *)cond_handle);
}

void sc_cond_timedwait(void *cond_handle, void *mutex_handle, int timeout_ms) {
    if (cond_handle == NULL || mutex_handle == NULL || timeout_ms < 0) {
        return;
    }

    struct timespec deadline;
    if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
        return;
    }

    const int ms_per_second = 1000;
    const long ns_per_ms = 1000000L;
    const long ns_per_second = 1000000000L;

    deadline.tv_sec += timeout_ms / ms_per_second;
    deadline.tv_nsec += (long)(timeout_ms % ms_per_second) * ns_per_ms;
    if (deadline.tv_nsec >= ns_per_second) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= ns_per_second;
    }

    pthread_cond_timedwait(
        (pthread_cond_t *)cond_handle,
        (pthread_mutex_t *)mutex_handle,
        &deadline
    );
}

void sc_cond_destroy(void *cond_handle) {
    if (cond_handle == NULL) {
        return;
    }
    pthread_cond_t *cond = (pthread_cond_t *)cond_handle;
    pthread_cond_destroy(cond);
    free(cond);
}

// MARK: - SIGINT handler

static sc_flag_t *g_sc_sigint_flag = NULL;

static void sc_sigint_handler(int signo) {
    (void)signo;
    if (g_sc_sigint_flag != NULL) {
        *g_sc_sigint_flag = 1;
    }
}

void sc_install_sigint_handler(void *flag_handle) {
    g_sc_sigint_flag = (sc_flag_t *)flag_handle;
    signal(SIGINT, sc_sigint_handler);
}

// MARK: - Raw terminal mode

static struct termios g_orig_termios;
static int g_raw_mode_enabled = 0;

void sc_enable_raw_mode(void) {
    if (g_raw_mode_enabled) return;
    if (tcgetattr(STDIN_FILENO, &g_orig_termios) != 0) return;

    struct termios raw = g_orig_termios;
    raw.c_lflag &= ~(ICANON | ECHO | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0) {
        g_raw_mode_enabled = 1;
    }
}

void sc_disable_raw_mode(void) {
    if (!g_raw_mode_enabled) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
    g_raw_mode_enabled = 0;
}

// MARK: - argv capture

#ifdef __APPLE__

int sc_get_argc(void) {
    return *_NSGetArgc();
}

const char *sc_get_argv(int index) {
    return (*_NSGetArgv())[index];
}

#else

static int g_argc = 0;
static char **g_argv = NULL;

__attribute__((constructor))
static void sc_save_args(int argc, char **argv, char **envp) {
    (void)envp;
    g_argc = argc;
    g_argv = argv;
}

int sc_get_argc(void) {
    return g_argc;
}

const char *sc_get_argv(int index) {
    if (g_argv == NULL || index < 0 || index >= g_argc) return NULL;
    return g_argv[index];
}

#endif

#endif // !__wasi__
