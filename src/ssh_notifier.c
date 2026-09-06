#include "ser_ops.h"

void notify_ssh_login(const char *user, const char *ip_address) {
    char log_msg[256];
    snprintf(log_msg, sizeof(log_msg), "SSH Login Event detected: User '%s' from IP '%s'", user, ip_address);
    ser_ops_log("SECURITY", log_msg);
}

int main(int argc, char *argv[]) {
    ser_ops_log("INFO", "Starting SSH Notifier Skill...");

    if (argc < 3) {
        printf("Usage: %s <username> <ip_address>\n", argv[0]);
        return 1;
    }

    notify_ssh_login(argv[1], argv[2]);

    return 0;
}
