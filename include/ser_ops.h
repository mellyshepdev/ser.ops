#ifndef SER_OPS_H
#define SER_OPS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SER_OPS_VERSION "1.0.0"
#define BUF_SIZE 8192

// Helper functions shared across ser.ops
void ser_ops_log(const char *level, const char *msg);

#endif // SER_OPS_H
