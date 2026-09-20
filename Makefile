# ser.ops build.
#
# Two target sets, merged from two lines of development that both owned this
# file:
#   * pg_lzma_export  — the original root-level exporter (pg_lzma_export.c),
#                       with Homebrew keg-only path handling so it builds on
#                       unit3 (macOS) as well as Linux.
#   * bin/*           — the C/C++ operational suite under src/, added by the
#                       ser-ops-c-skills branch.
# Neither replaces the other: pg_lzma_export is the benchmarked baseline that
# BLA-21 says must stay measurable against the suite's pg_lzma_exporter.

CC      ?= cc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion
LDLIBS   = -lpq -llzma

PG_CFLAGS  := $(shell pg_config --includedir 2>/dev/null | sed 's/^/-I/')
PG_LDFLAGS := $(shell pg_config --libdir 2>/dev/null | sed 's/^/-L/')

# Homebrew keeps libpq and xz keg-only, so their headers are not on the
# default search path. Harmless no-ops on Linux, where brew is absent.
BREW := $(shell command -v brew 2>/dev/null)
ifneq ($(BREW),)
LIBPQ_PREFIX := $(shell brew --prefix libpq 2>/dev/null)
XZ_PREFIX    := $(shell brew --prefix xz 2>/dev/null)
ifneq ($(LIBPQ_PREFIX),)
PG_CFLAGS  += -I$(LIBPQ_PREFIX)/include
PG_LDFLAGS += -L$(LIBPQ_PREFIX)/lib
endif
ifneq ($(XZ_PREFIX),)
PG_CFLAGS  += -I$(XZ_PREFIX)/include
PG_LDFLAGS += -L$(XZ_PREFIX)/lib
endif
endif

BIN = pg_lzma_export

# ---------------------------------------------------------------- C suite
BUILD_DIR  = bin
SRC_DIR    = src
COMMON_SRC = $(SRC_DIR)/ser_ops_common.c
SUITE_CFLAGS = -Wall -Wextra -Iinclude $(PG_CFLAGS) -O2

SUITE = $(BUILD_DIR)/pg_lzma_exporter \
        $(BUILD_DIR)/docker_throttler \
        $(BUILD_DIR)/archive_transfer \
        $(BUILD_DIR)/ssh_notifier

# `make` builds the baseline only — the suite needs libpq headers that are not
# present on every unit. `make suite` or `make all-targets` builds both.
all: $(BIN)

all-targets: $(BIN) suite

suite: $(BUILD_DIR) $(SUITE)

$(BIN): pg_lzma_export.c
	$(CC) $(CFLAGS) $(PG_CFLAGS) -o $@ $< $(PG_LDFLAGS) $(LDLIBS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/pg_lzma_exporter: $(SRC_DIR)/pg_lzma_exporter.c $(COMMON_SRC)
	$(CC) $(SUITE_CFLAGS) $^ -o $@ $(PG_LDFLAGS) $(LDLIBS)

$(BUILD_DIR)/docker_throttler: $(SRC_DIR)/docker_throttler.c $(COMMON_SRC)
	$(CC) $(SUITE_CFLAGS) $^ -o $@

$(BUILD_DIR)/archive_transfer: $(SRC_DIR)/archive_transfer.c $(COMMON_SRC)
	$(CC) $(SUITE_CFLAGS) $^ -o $@

$(BUILD_DIR)/ssh_notifier: $(SRC_DIR)/ssh_notifier.c $(COMMON_SRC)
	$(CC) $(SUITE_CFLAGS) $^ -o $@

# Address/UB sanitizers — run the benchmark under this before trusting it.
debug: CFLAGS = -O0 -g -std=c11 -Wall -Wextra -fsanitize=address,undefined
debug: clean $(BIN)

clean:
	rm -f $(BIN)
	rm -rf $(BUILD_DIR)

.PHONY: all all-targets suite debug clean
