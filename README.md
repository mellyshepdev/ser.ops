# ser.ops - Operational C/C++ Skills Suite

`ser.ops` provides C/C++ operational skills and utilities for system monitoring, PostgreSQL database exports with LZMA compression (`.xz`), automated SCP file transfers and ArchiveBox catalog registration, Docker container throttling/pausing, and SSH login security notifications.

## Overview of Skills

1. **PostgreSQL LZMA Exporter (`bin/pg_lzma_exporter`)**
   - Connects to PostgreSQL using `libpq`.
   - Serializes query results into memory.
   - Applies LZMA compression using `liblzma` and writes `.xz` archive files.

2. **Docker Container Idle Throttler (`bin/docker_throttler`)**
   - Monitors container idle status.
   - Throttles CPU quotas down to 5% allocation (`docker update --cpu-quota 5000`).
   - Automatically pauses containers exceeding the idle threshold.

3. **SCP Transfer & ArchiveBox Cataloging (`bin/archive_transfer`)**
   - Transfers compressed `.xz` archives to `unit3` via `scp`.
   - Registers/indexes the new archive into the ArchiveBox catalog destination on `unit3`.

4. **SSH & Operations Notifier (`bin/ssh_notifier`)**
   - Logs and notifies SSH login security events and operational activity.

## Prerequisites

On Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install -y gcc make libpq-dev liblzma-dev
```

## Compilation

To compile all skills:
```bash
make
```

To clean build artifacts:
```bash
make clean
```

The compiled binaries will be output to the `bin/` directory.

## Usage Examples

### 1. PostgreSQL LZMA Export
```bash
./bin/pg_lzma_exporter "dbname=postgres user=postgres password=postgres host=localhost" "SELECT * FROM my_table;" "output.xz"
```

### 2. Docker Container Idle Throttling
```bash
./bin/docker_throttler <container_id_or_name> [idle_seconds]
```

### 3. Archive Transfer & ArchiveBox Ingestion
```bash
./bin/archive_transfer output.xz unit3
```

### 4. SSH Login Notification
```bash
./bin/ssh_notifier <username> <ip_address>
```
