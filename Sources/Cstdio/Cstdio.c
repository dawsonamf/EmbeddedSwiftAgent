#include "include/Cstdio.h"

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
