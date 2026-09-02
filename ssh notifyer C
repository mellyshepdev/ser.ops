tobsco.3, unit3, tobsco.4, unit4, tobsco.7 unit7, tobsco.8, unit8, tobsco.9 unit9

ssh ""


**PostgreSQL LZMA Compression Utility in C**
This C program connects to your PostgreSQL database, queries the target table/data, and applies LZMA compression using liblzma before saving or transmitting the output.
**Prerequisites**
 * Install development headers: sudo apt-get install libpq-dev liblzma-dev
 * Compile with: gcc -o pg_lzma_exporter pg_lzma_exporter.c -lpq -llzma
```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libpq-fe.h>
#include <lzma.h>

#define BUF_SIZE 8192

// Compresses input buffer using LZMA and writes to output file
int compress_lzma(const unsigned char *in_buf, size_t in_len, FILE *out_file) {
    lzma_stream strm = LZMA_STREAM_INIT;
    lzma_ret ret = lzma_easy_encoder(&strm, 6, LZMA_CHECK_CRC64);
    if (ret != LZMA_OK) return -1;

    unsigned char out_buf[BUF_SIZE];
    strm.next_in = in_buf;
    strm.avail_in = in_len;
    strm.next_out = out_buf;
    strm.avail_out = BUF_SIZE;

    lzma_action action = LZMA_FINISH;

    do {
        ret = lzma_code(&strm, action);
        size_t write_len = BUF_SIZE - strm.avail_out;
        if (fwrite(out_buf, 1, write_len, out_file) != write_len) {
            lzma_end(&strm);
            return -1;
        }
        strm.next_out = out_buf;
        strm.avail_out = BUF_SIZE;
    } while (strm.avail_out == 0 || ret == LZMA_OK);

    lzma_end(&strm);
    return (ret == LZMA_STREAM_END) ? 0 : -1;
}

int main() {
    // 1. Connect to PostgreSQL
    const char *conninfo = "dbname=your_db user=your_user password=your_pass host=localhost";
    PGconn *conn = PQconnectdb(conninfo);

    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "Connection to database failed: %s\n", PQgeterrorMessage(conn));
        PQfinish(conn);
        return 1;
    }

    // 2. Query target data
    PGresult *res = PQexec(conn, "SELECT * FROM target_table;");
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "Query execution failed: %s\n", PQgeterrorMessage(conn));
        PQclear(res);
        PQfinish(conn);
        return 1;
    }

    // 3. Serialize query results into a memory buffer
    int rows = PQntuples(res);
    int cols = PQnfields(res);
    
    // Estimating buffer capacity
    size_t capacity = 1024 * 1024;
    unsigned char *data_buffer = malloc(capacity);
    size_t offset = 0;

    for (int i = 0; i < rows; i++) {
        for (int j = 0; j < cols; j++) {
            char *val = PQgetvalue(res, i, j);
            size_t val_len = strlen(val);
            if (offset + val_len + 2 > capacity) {
                capacity *= 2;
                data_buffer = realloc(data_buffer, capacity);
            }
            memcpy(data_buffer + offset, val, val_len);
            offset += val_len;
            data_buffer[offset++] = (j == cols - 1) ? '\n' : '\t';
        }
    }

    // 4. Compress serialized data to an LZMA file
    FILE *out_file = fopen("pg_backup.xz", "wb");
    if (!out_file) {
        perror("Failed to open output file");
        free(data_buffer);
        PQclear(res);
        PQfinish(conn);
        return 1;
    }

    if (compress_lzma(data_buffer, offset, out_file) == 0) {
        printf("Successfully exported and compressed %d rows to pg_backup.xz\n", rows);
    } else {
        fprintf(stderr, "Compression failed.\n");
    }

    // Cleanup
    fclose(out_file);
    free(data_buffer);
    PQclear(res);
    PQfinish(conn);
    return 0;
}

```


                 #include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <libpq-fe.h>
#include <lzma.h>
#include "llama.h"

#define BUF_SIZE 8192
#define IDLE_THRESHOLD_SECS 3600 // 1 hour

typedef struct {
    char container_id[64];
    char container_name[64];
    time_t last_active_time;
    int is_paused;
} ContainerState;

// 1. LZMA Compression Helper
int compress_lzma(const unsigned char *in_buf, size_t in_len, FILE *out_file) {
    lzma_stream strm = LZMA_STREAM_INIT;
    if (lzma_easy_encoder(&strm, 6, LZMA_CHECK_CRC64) != LZMA_OK) return -1;

    unsigned char out_buf[BUF_SIZE];
    strm.next_in = in_buf;
    strm.avail_in = in_len;
    strm.next_out = out_buf;
    strm.avail_out = BUF_SIZE;

    lzma_ret ret;
    do {
        ret = lzma_code(&strm, LZMA_FINISH);
        size_t write_len = BUF_SIZE - strm.avail_out;
        if (fwrite(out_buf, 1, write_len, out_file) != write_len) {
            lzma_end(&strm);
            return -1;
        }
        strm.next_out = out_buf;
        strm.avail_out = BUF_SIZE;
    } while (strm.avail_out == 0 || ret == LZMA_OK);

    lzma_end(&strm);
    return (ret == LZMA_STREAM_END) ? 0 : -1;
}

// 2. Throttle & Pause Container via Docker CLI
void throttle_and_pause_container(ContainerState *c) {
    char cmd[256];
    
    // Throttle CPU quotas down (5% allocation)
    snprintf(cmd, sizeof(cmd), "docker update --cpu-quota 5000 %s > /dev/null 2>&1", c->container_id);
    system(cmd);
