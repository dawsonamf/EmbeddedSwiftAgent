#ifndef CSTDIO_H
#define CSTDIO_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>

char **get_environ(void);

void flush_stdout(void);
void write_stderr(const char *msg);

/// Reads a line from stdin into a malloc'd buffer (caller must free).
/// Returns NULL on EOF. Strips the trailing newline.
char *read_line_stdin(void);

/// Wrapper around rand() — Darwin marks it __swift_unavailable.
int c_rand(void);

#endif
