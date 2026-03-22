#ifndef CSTDIO_H
#define CSTDIO_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pthread.h>

char **get_environ(void);

void flush_stdout(void);
void write_stderr(const char *msg);

/// Reads a line from stdin into a malloc'd buffer (caller must free).
/// Returns NULL on EOF. Strips the trailing newline.
char *read_line_stdin(void);

/// Wrapper around rand() — Darwin marks it __swift_unavailable.
int c_rand(void);

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

#endif
