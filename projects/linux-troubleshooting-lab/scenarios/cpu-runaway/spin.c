/* A "report worker" with a bug: its worker threads spin forever instead of
 * waiting for work. Usage: report-worker <busy-threads> */
#include <pthread.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>

static void *spin(void *arg) {
    volatile unsigned long n = 0;
    (void)arg;
    for (;;) n++;          /* the bug: busy loop, no sleep, no blocking wait */
    return NULL;
}

int main(int argc, char **argv) {
    int threads = argc > 1 ? atoi(argv[1]) : 2;
    prctl(PR_SET_NAME, "report-worker", 0, 0, 0);
    for (int i = 0; i < threads; i++) {
        pthread_t t;
        pthread_create(&t, NULL, spin, NULL);
    }
    for (;;) pause();      /* the main thread is idle; only the workers burn CPU */
}
