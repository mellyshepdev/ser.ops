#include "ser_ops.h"

void ser_ops_log(const char *level, const char *msg) {
    time_t now = time(NULL);
    char time_buf[64];
    struct tm *tm_info = localtime(&now);
    strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", tm_info);
    printf("[%s] [%s] %s\n", time_buf, level, msg);
}
