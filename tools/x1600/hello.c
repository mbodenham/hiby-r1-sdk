#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(void)
{
    printf("Hello from MIPS32r2 (XBurstR2) static musl userland, gid=%s\n",
           __VERSION__);
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
        printf("clock_gettime ok: %ld.%09ld\n", (long)ts.tv_sec, (long)ts.tv_nsec);
    return 0;
}
