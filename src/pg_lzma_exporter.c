#include "ser_ops.h"
#include <libpq-fe.h>
#include <lzma.h>

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

int main(int argc, char *argv[]) {
    const char *conninfo = (argc > 1) ? argv[1] : "dbname=postgres user=postgres password=postgres host=localhost";
    const char *query = (argc > 2) ? argv[2] : "SELECT NOW();";
    const char *output_filename = (argc > 3) ? argv[3] : "pg_backup.xz";

    ser_ops_log("INFO", "Starting PostgreSQL LZMA Export Skill...");

    PGconn *conn = PQconnectdb(conninfo);
    if (PQstatus(conn) != CONNECTION_OK) {
        char err_msg[256];
        snprintf(err_msg, sizeof(err_msg), "Connection to database failed: %s", PQerrorMessage(conn));
        ser_ops_log("ERROR", err_msg);
        PQfinish(conn);
        return 1;
    }

    PGresult *res = PQexec(conn, query);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        char err_msg[256];
        snprintf(err_msg, sizeof(err_msg), "Query execution failed: %s", PQerrorMessage(conn));
        ser_ops_log("ERROR", err_msg);
        PQclear(res);
        PQfinish(conn);
        return 1;
    }

    int rows = PQntuples(res);
    int cols = PQnfields(res);

    size_t capacity = 1024 * 1024;
    unsigned char *data_buffer = malloc(capacity);
    if (!data_buffer) {
        ser_ops_log("ERROR", "Failed to allocate memory buffer");
        PQclear(res);
        PQfinish(conn);
        return 1;
    }
    size_t offset = 0;

    for (int i = 0; i < rows; i++) {
        for (int j = 0; j < cols; j++) {
            char *val = PQgetvalue(res, i, j);
            size_t val_len = strlen(val);
            if (offset + val_len + 2 > capacity) {
                capacity *= 2;
                unsigned char *new_buf = realloc(data_buffer, capacity);
                if (!new_buf) {
                    ser_ops_log("ERROR", "Failed to reallocate memory buffer");
                    free(data_buffer);
                    PQclear(res);
                    PQfinish(conn);
                    return 1;
                }
                data_buffer = new_buf;
            }
            memcpy(data_buffer + offset, val, val_len);
            offset += val_len;
            data_buffer[offset++] = (j == cols - 1) ? '\n' : '\t';
        }
    }

    FILE *out_file = fopen(output_filename, "wb");
    if (!out_file) {
        ser_ops_log("ERROR", "Failed to open output .xz file");
        free(data_buffer);
        PQclear(res);
        PQfinish(conn);
        return 1;
    }

    if (compress_lzma(data_buffer, offset, out_file) == 0) {
        char log_msg[256];
        snprintf(log_msg, sizeof(log_msg), "Successfully exported %d rows to %s", rows, output_filename);
        ser_ops_log("INFO", log_msg);
    } else {
        ser_ops_log("ERROR", "LZMA Compression failed.");
    }

    fclose(out_file);
    free(data_buffer);
    PQclear(res);
    PQfinish(conn);
    return 0;
}
