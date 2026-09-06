#include "ser_ops.h"
#include <unistd.h>

#define IDLE_THRESHOLD_SECS 3600 // Default 1 hour

typedef struct {
    char container_id[64];
    char container_name[64];
    time_t last_active_time;
    int is_paused;
} ContainerState;

void throttle_and_pause_container(ContainerState *c) {
    char cmd[256];
    char log_msg[256];

    snprintf(log_msg, sizeof(log_msg), "Throttling CPU quota for container %s (%s) to 5%% allocation", c->container_id, c->container_name);
    ser_ops_log("WARN", log_msg);

    // Throttle CPU quotas down (5% allocation)
    snprintf(cmd, sizeof(cmd), "docker update --cpu-quota 5000 %s > /dev/null 2>&1", c->container_id);
    int res = system(cmd);
    if (res != 0) {
        snprintf(log_msg, sizeof(log_msg), "Failed to throttle container %s", c->container_id);
        ser_ops_log("ERROR", log_msg);
    }

    // Pause container if idle time exceeds threshold
    time_t now = time(NULL);
    if (!c->is_paused && (now - c->last_active_time) >= IDLE_THRESHOLD_SECS) {
        snprintf(log_msg, sizeof(log_msg), "Container %s is idle (>%d s). Pausing container...", c->container_id, IDLE_THRESHOLD_SECS);
        ser_ops_log("WARN", log_msg);

        snprintf(cmd, sizeof(cmd), "docker pause %s > /dev/null 2>&1", c->container_id);
        res = system(cmd);
        if (res == 0) {
            c->is_paused = 1;
            snprintf(log_msg, sizeof(log_msg), "Container %s paused successfully.", c->container_id);
            ser_ops_log("INFO", log_msg);
        } else {
            snprintf(log_msg, sizeof(log_msg), "Failed to pause container %s", c->container_id);
            ser_ops_log("ERROR", log_msg);
        }
    }
}

int main(int argc, char *argv[]) {
    ser_ops_log("INFO", "Starting Docker Container Idle Throttler Skill...");

    if (argc < 2) {
        printf("Usage: %s <container_id_or_name> [idle_seconds]\n", argv[0]);
        return 1;
    }

    ContainerState c;
    strncpy(c.container_id, argv[1], sizeof(c.container_id) - 1);
    strncpy(c.container_name, argv[1], sizeof(c.container_name) - 1);
    c.is_paused = 0;

    int idle_secs = (argc > 2) ? atoi(argv[2]) : IDLE_THRESHOLD_SECS;
    c.last_active_time = time(NULL) - idle_secs;

    throttle_and_pause_container(&c);

    return 0;
}
