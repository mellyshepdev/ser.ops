CC = gcc
PG_INC = $(shell pg_config --includedir 2>/dev/null || (test -d /usr/include/postgresql && echo "/usr/include/postgresql") || echo "")
CFLAGS = -Wall -Wextra -Iinclude $(if $(PG_INC),-I$(PG_INC)) -O2
LDFLAGS_PG = -lpq -llzma

BUILD_DIR = bin
SRC_DIR = src

TARGETS = $(BUILD_DIR)/pg_lzma_exporter \
          $(BUILD_DIR)/docker_throttler \
          $(BUILD_DIR)/archive_transfer \
          $(BUILD_DIR)/ssh_notifier

COMMON_SRC = $(SRC_DIR)/ser_ops_common.c

all: $(BUILD_DIR) $(TARGETS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/pg_lzma_exporter: $(SRC_DIR)/pg_lzma_exporter.c $(COMMON_SRC)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS_PG)

$(BUILD_DIR)/docker_throttler: $(SRC_DIR)/docker_throttler.c $(COMMON_SRC)
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD_DIR)/archive_transfer: $(SRC_DIR)/archive_transfer.c $(COMMON_SRC)
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD_DIR)/ssh_notifier: $(SRC_DIR)/ssh_notifier.c $(COMMON_SRC)
	$(CC) $(CFLAGS) $^ -o $@

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean
