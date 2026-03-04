#include <stdio.h>

void flush_stdout(void) {
    fflush(stdout);
}

void write_stderr(const char *msg) {
    fputs(msg, stderr);
}
