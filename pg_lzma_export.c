/*
 * pg_lzma_export — stream a PostgreSQL query straight into an .xz file.
 *
 * The point of this program is that it never holds the result set in memory.
 * Rows arrive from the server in chunks via the COPY protocol, each chunk is
 * fed to liblzma as it lands, and compressed output is flushed to disk as it
 * is produced. Memory is flat whether the query returns ten rows or ten
 * million.
 *
 * "Flat" is not "small": the floor is set by the LZMA encoder's dictionary,
 * not by our 64K buffers. Encoder memory per preset, from liblzma:
 *
 *     preset 0    3 MiB      preset 5   94 MiB
 *     preset 1    9 MiB      preset 6   94 MiB   (default)
 *     preset 2   17 MiB      preset 7  186 MiB
 *     preset 3   32 MiB      preset 8  370 MiB
 *     preset 4   48 MiB      preset 9  674 MiB
 *
 * Measured peak RSS at preset 6 is ~156 MB including libpq and the runtime.
 * Mind this on small hosts — preset 9 on a box with under 1 GB free will be
 * killed by the OOM reaper, and a backup job that dies is worse than a
 * slightly larger file.
 *
 * Why COPY rather than SELECT + PQgetvalue:
 *
 *   - PQgetvalue returns "" for SQL NULL, which is indistinguishable from an
 *     empty string. COPY encodes NULL as \N, so the distinction survives.
 *   - COPY escapes tabs, newlines and backslashes inside values. Naive
 *     string concatenation corrupts any row containing them, which for a
 *     table of free-text log messages is a guarantee, not a risk.
 *   - COPY streams. PQexec buffers the entire result in the client first.
 *
 * The output is a normal .xz file: `xz -d` and `unxz` read it, and the
 * payload is COPY text format, so `psql -c "\copy tbl FROM ..."` restores it.
 *
 * Build:  make
 * Deps:   libpq-dev liblzma-dev
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <getopt.h>

#include <libpq-fe.h>
#include <lzma.h>

#define CHUNK 65536

/* ------------------------------------------------------------------ */
/* xz sink: incremental encoder wrapping a FILE*                       */
/* ------------------------------------------------------------------ */

typedef struct {
    lzma_stream strm;
    FILE       *out;
    uint8_t     buf[CHUNK];
    uint64_t    bytes_in;
    uint64_t    bytes_out;
} xz_sink;

static bool xz_open(xz_sink *z, FILE *out, uint32_t preset)
{
    lzma_stream init = LZMA_STREAM_INIT;
    z->strm      = init;
    z->out       = out;
    z->bytes_in  = 0;
    z->bytes_out = 0;

    lzma_ret ret = lzma_easy_encoder(&z->strm, preset, LZMA_CHECK_CRC64);
    if (ret != LZMA_OK) {
        fprintf(stderr, "lzma_easy_encoder failed (preset %u): %d\n", preset, ret);
        return false;
    }
    return true;
}

/*
 * Push `len` bytes through the encoder.
 *
 * LZMA_RUN consumes input and may produce no output at all — the encoder
 * buffers internally until it has enough to emit a block. So the loop
 * condition differs by action: for RUN we are done when the input is
 * consumed; for FINISH we are done only at LZMA_STREAM_END.
 */
static bool xz_pump(xz_sink *z, const uint8_t *in, size_t len, lzma_action action)
{
    z->strm.next_in  = in;
    z->strm.avail_in = len;
    z->bytes_in     += len;

    for (;;) {
        z->strm.next_out  = z->buf;
        z->strm.avail_out = sizeof z->buf;

        lzma_ret ret = lzma_code(&z->strm, action);
        if (ret != LZMA_OK && ret != LZMA_STREAM_END) {
            fprintf(stderr, "lzma_code failed: %d\n", ret);
            return false;
        }

        size_t have = sizeof z->buf - z->strm.avail_out;
        if (have > 0) {
            if (fwrite(z->buf, 1, have, z->out) != have) {
                perror("write");
                return false;
            }
            z->bytes_out += have;
        }

        if (action == LZMA_RUN) {
            if (z->strm.avail_in == 0) return true;
        } else if (ret == LZMA_STREAM_END) {
            return true;
        }
    }
}

static bool xz_close(xz_sink *z)
{
    bool ok = xz_pump(z, NULL, 0, LZMA_FINISH);
    lzma_end(&z->strm);
    return ok;
}

/* ------------------------------------------------------------------ */

static void usage(const char *argv0)
{
    fprintf(stderr,
"Usage: %s --out FILE [options]\n"
"\n"
"  --out FILE         output .xz path, or - for stdout   (required)\n"
"  --table NAME       table to export\n"
"  --since TS         only rows with --column > TS (incremental watermark)\n"
"  --column NAME      watermark column            (default: hour_bucket)\n"
"  --query SQL        full SELECT, overrides --table/--since\n"
"  --preset N         lzma preset 0-9             (default: 6)\n"
"  --quiet            suppress the summary line\n"
"\n"
"Connection uses standard libpq environment variables:\n"
"  PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE\n"
"or set PG_CONNINFO to a full connection string.\n"
"\n"
"Examples:\n"
"  # full table\n"
"  %s --table logs_archive --out archive.xz\n"
"\n"
"  # incremental: only buckets newer than the last watermark\n"
"  %s --table logs_archive --since '2026-09-01 00:00:00+00' --out inc.xz\n",
        argv0, argv0, argv0);
}

int main(int argc, char **argv)
{
    const char *out_path = NULL;
    const char *table    = NULL;
    const char *since    = NULL;
    const char *column   = "hour_bucket";
    const char *query    = NULL;
    uint32_t    preset   = 6;
    bool        quiet    = false;

    static struct option opts[] = {
        {"out",    required_argument, 0, 'o'},
        {"table",  required_argument, 0, 't'},
        {"since",  required_argument, 0, 's'},
        {"column", required_argument, 0, 'c'},
        {"query",  required_argument, 0, 'q'},
        {"preset", required_argument, 0, 'p'},
        {"quiet",  no_argument,       0, 'Q'},
        {"help",   no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int c;
    while ((c = getopt_long(argc, argv, "o:t:s:c:q:p:Qh", opts, NULL)) != -1) {
        switch (c) {
        case 'o': out_path = optarg; break;
        case 't': table    = optarg; break;
        case 's': since    = optarg; break;
        case 'c': column   = optarg; break;
        case 'q': query    = optarg; break;
        case 'p': preset   = (uint32_t)strtoul(optarg, NULL, 10); break;
        case 'Q': quiet    = true;   break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 2;
        }
    }

    if (!out_path || (!table && !query)) { usage(argv[0]); return 2; }
    if (preset > 9) { fprintf(stderr, "--preset must be 0-9\n"); return 2; }

    /* Connection details come from the environment. Nothing is hardcoded and
     * no password ever appears in argv, where it would be visible in ps. */
    const char *conninfo = getenv("PG_CONNINFO");
    PGconn *conn = PQconnectdb(conninfo ? conninfo : "");
    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "connection failed: %s", PQerrorMessage(conn));
        PQfinish(conn);
        return 1;
    }

    /* Build the COPY statement. Identifiers and literals both go through
     * libpq's escaping — never sprintf user input into SQL. */
    char *sql = NULL;
    if (query) {
        size_t n = strlen(query) + 64;
        sql = malloc(n);
        if (!sql) { fprintf(stderr, "out of memory\n"); PQfinish(conn); return 1; }
        snprintf(sql, n, "COPY (%s) TO STDOUT", query);
    } else {
        char *tbl = PQescapeIdentifier(conn, table, strlen(table));
        char *col = PQescapeIdentifier(conn, column, strlen(column));
        if (!tbl || !col) {
            fprintf(stderr, "escape failed: %s", PQerrorMessage(conn));
            PQfinish(conn);
            return 1;
        }

        if (since) {
            char *lit = PQescapeLiteral(conn, since, strlen(since));
            if (!lit) {
                fprintf(stderr, "escape failed: %s", PQerrorMessage(conn));
                PQfinish(conn);
                return 1;
            }
            size_t n = strlen(tbl) + strlen(col) + strlen(lit) + 96;
            sql = malloc(n);
            if (sql)
                snprintf(sql, n,
                         "COPY (SELECT * FROM %s WHERE %s > %s::timestamptz ORDER BY %s) TO STDOUT",
                         tbl, col, lit, col);
            PQfreemem(lit);
        } else {
            size_t n = strlen(tbl) + 64;
            sql = malloc(n);
            if (sql) snprintf(sql, n, "COPY (SELECT * FROM %s) TO STDOUT", tbl);
        }
        PQfreemem(tbl);
        PQfreemem(col);
        if (!sql) { fprintf(stderr, "out of memory\n"); PQfinish(conn); return 1; }
    }

    FILE *out = strcmp(out_path, "-") == 0 ? stdout : fopen(out_path, "wb");
    if (!out) { perror(out_path); free(sql); PQfinish(conn); return 1; }

    xz_sink z;
    if (!xz_open(&z, out, preset)) {
        if (out != stdout) fclose(out);
        free(sql);
        PQfinish(conn);
        return 1;
    }

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    PGresult *res = PQexec(conn, sql);
    if (PQresultStatus(res) != PGRES_COPY_OUT) {
        fprintf(stderr, "COPY failed: %s", PQerrorMessage(conn));
        PQclear(res);
        lzma_end(&z.strm);
        if (out != stdout) fclose(out);
        free(sql);
        PQfinish(conn);
        return 1;
    }
    PQclear(res);

    /* Drain the COPY stream. PQgetCopyData allocates each chunk; we own it
     * and must PQfreemem it. Returns >0 = bytes, -1 = end of data,
     * -2 = error. */
    bool  failed = false;
    char *buf    = NULL;
    int   n;

    while ((n = PQgetCopyData(conn, &buf, 0)) > 0) {
        if (!xz_pump(&z, (const uint8_t *)buf, (size_t)n, LZMA_RUN)) {
            PQfreemem(buf);
            failed = true;
            break;
        }
        PQfreemem(buf);
        buf = NULL;
    }

    if (!failed && n == -2) {
        fprintf(stderr, "COPY stream error: %s", PQerrorMessage(conn));
        failed = true;
    }

    /* Even on success the server sends a final result; a failure mid-COPY
     * only shows up here, so this check is not optional. */
    if (!failed) {
        res = PQgetResult(conn);
        if (PQresultStatus(res) != PGRES_COMMAND_OK) {
            fprintf(stderr, "COPY did not complete: %s", PQerrorMessage(conn));
            failed = true;
        }
        PQclear(res);
    }

    if (!failed && !xz_close(&z)) failed = true;
    else if (failed) lzma_end(&z.strm);

    if (out != stdout) {
        if (fclose(out) != 0) { perror("close"); failed = true; }
    } else {
        fflush(stdout);
    }

    free(sql);
    PQfinish(conn);

    /* A partial .xz is worse than none — it looks like a backup. */
    if (failed) {
        if (strcmp(out_path, "-") != 0) remove(out_path);
        return 1;
    }

    if (!quiet) {
        struct timespec t1;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double secs = (double)(t1.tv_sec - t0.tv_sec)
                    + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
        double ratio = z.bytes_in ? (double)z.bytes_in / (double)z.bytes_out : 0.0;

        fprintf(stderr,
                "%llu bytes in, %llu bytes out, %.2fx, %.1fs, %.1f MB/s in\n",
                (unsigned long long)z.bytes_in,
                (unsigned long long)z.bytes_out,
                ratio, secs,
                secs > 0 ? (double)z.bytes_in / secs / (1024 * 1024) : 0.0);
    }

    return 0;
}
