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

all: $(BIN)

$(BIN): pg_lzma_export.c
	$(CC) $(CFLAGS) $(PG_CFLAGS) -o $@ $< $(PG_LDFLAGS) $(LDLIBS)

# Address/UB sanitizers — run the benchmark under this before trusting it.
debug: CFLAGS = -O0 -g -std=c11 -Wall -Wextra -fsanitize=address,undefined
debug: clean $(BIN)

clean:
	rm -f $(BIN)

.PHONY: all debug clean
