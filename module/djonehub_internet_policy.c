#define _POSIX_C_SOURCE 200809L
#include "djonehub_internet_policy.h"
#include <stdio.h>
#include <unistd.h>
#ifndef INTERNET_IPV4_PATH
#define INTERNET_IPV4_PATH "/proc/sys/net/ipv4/conf/bridge0/forwarding"
#define INTERNET_IPV6_PATH "/proc/sys/net/ipv6/conf/bridge0/forwarding"
#define INTERNET_SAVED_PATH "/usrdata/djonehub/internet-disabled"
#endif
static int read_value(const char *path)
{
    FILE *file = fopen(path, "r");
    int value = -1;
    if (!file) return -1;
    if (fscanf(file, "%d", &value) != 1 || value < 0 || value > 2) value = -1;
    fclose(file);
    return value;
}
static int write_value(const char *path, int value)
{
    FILE *file = fopen(path, "w");
    int failed;
    if (!file) return -1;
    failed = fprintf(file, "%d\n", value) < 0;
    if (fclose(file) != 0) failed = 1;
    return !failed && read_value(path) == value ? 0 : -1;
}
static int saved_values(int *v4, int *v6)
{
    FILE *file = fopen(INTERNET_SAVED_PATH, "r");
    int ok;
    if (!file) return -1;
    ok = fscanf(file, "%d %d", v4, v6) == 2 && *v4 > 0 && *v4 <= 2 && *v6 > 0 && *v6 <= 2;
    fclose(file);
    return ok ? 0 : -1;
}
uint8_t djonehub_internet_state(void)
{
    int v4 = read_value(INTERNET_IPV4_PATH), v6 = read_value(INTERNET_IPV6_PATH);
    if (v4 < 0 || v6 < 0) return 0;
    if (v4 == 0 && v6 == 0) return 1;
    return v4 > 0 && v6 > 0 ? 2 : 0;
}
int djonehub_internet_set(int enabled)
{
    int old4 = read_value(INTERNET_IPV4_PATH), old6 = read_value(INTERNET_IPV6_PATH);
    int new4 = 0, new6 = 0;
    FILE *file;
    int failed;
    if (old4 < 0 || old6 < 0 || (enabled != 0 && enabled != 1)) return -1;
    if (enabled) {
        if (old4 > 0 && old6 > 0 && access(INTERNET_SAVED_PATH, F_OK) != 0) return 0;
        if (saved_values(&new4, &new6) != 0) return -1;
    } else {
        if (old4 == 0 && old6 == 0) return 0;
        if (old4 == 0 || old6 == 0) return -1;
        file = fopen(INTERNET_SAVED_PATH ".tmp", "w");
        if (!file) return -1;
        failed = fprintf(file, "%d %d\n", old4, old6) < 0;
        if (fflush(file) != 0 || fsync(fileno(file)) != 0) failed = 1;
        if (fclose(file) != 0) failed = 1;
        if (failed || rename(INTERNET_SAVED_PATH ".tmp", INTERNET_SAVED_PATH) != 0) return -1;
    }
    if (write_value(INTERNET_IPV4_PATH, new4) != 0 || write_value(INTERNET_IPV6_PATH, new6) != 0) {
        (void)write_value(INTERNET_IPV4_PATH, old4);
        (void)write_value(INTERNET_IPV6_PATH, old6);
        if (!enabled) (void)unlink(INTERNET_SAVED_PATH);
        return -1;
    }
    if (enabled && unlink(INTERNET_SAVED_PATH) != 0) {
        (void)write_value(INTERNET_IPV4_PATH, old4);
        (void)write_value(INTERNET_IPV6_PATH, old6);
        return -1;
    }
    return 0;
}
void djonehub_internet_restore(void)
{
    int v4, v6;
    if (saved_values(&v4, &v6) == 0) {
        (void)write_value(INTERNET_IPV4_PATH, 0);
        (void)write_value(INTERNET_IPV6_PATH, 0);
    }
}
