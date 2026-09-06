#include "ser_ops.h"

int transfer_archive_to_unit3(const char *file_path, const char *destination_host) {
    char cmd[512];
    char log_msg[256];

    snprintf(log_msg, sizeof(log_msg), "Transferring archive %s to %s via SCP...", file_path, destination_host);
    ser_ops_log("INFO", log_msg);

    snprintf(cmd, sizeof(cmd), "scp -q %s %s:/data/archivebox/archive/", file_path, destination_host);
    int status = system(cmd);
    if (status != 0) {
        snprintf(log_msg, sizeof(log_msg), "SCP transfer of %s to %s failed", file_path, destination_host);
        ser_ops_log("ERROR", log_msg);
        return -1;
    }

    ser_ops_log("INFO", "SCP transfer completed successfully.");
    return 0;
}

int register_archivebox_catalog(const char *file_path, const char *destination_host) {
    char cmd[512];
    char log_msg[256];

    snprintf(log_msg, sizeof(log_msg), "Registering archive %s into ArchiveBox catalog on %s...", file_path, destination_host);
    ser_ops_log("INFO", log_msg);

    snprintf(cmd, sizeof(cmd), "ssh -q %s \"archivebox add /data/archivebox/archive/%s --depth=0\" > /dev/null 2>&1", destination_host, file_path);
    int status = system(cmd);
    if (status != 0) {
        snprintf(log_msg, sizeof(log_msg), "Failed to register %s in ArchiveBox catalog on %s", file_path, destination_host);
        ser_ops_log("WARN", log_msg);
        return -1;
    }

    ser_ops_log("INFO", "ArchiveBox catalog registration complete.");
    return 0;
}

int main(int argc, char *argv[]) {
    ser_ops_log("INFO", "Starting SCP Transfer & ArchiveBox Catalog Skill...");

    if (argc < 2) {
        printf("Usage: %s <compressed_file.xz> [destination_host]\n", argv[0]);
        return 1;
    }

    const char *file_path = argv[1];
    const char *destination_host = (argc > 2) ? argv[2] : "unit3";

    if (transfer_archive_to_unit3(file_path, destination_host) == 0) {
        register_archivebox_catalog(file_path, destination_host);
    } else {
        ser_ops_log("ERROR", "Aborting catalog registration due to transfer failure.");
        return 1;
    }

    return 0;
}
