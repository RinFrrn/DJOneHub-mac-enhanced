#define _DARWIN_C_SOURCE

#define _POSIX_C_SOURCE 200809L
#define INTERNET_IPV4_PATH "v4"
#define INTERNET_IPV6_PATH "v6"
#define INTERNET_SAVED_PATH "saved"
#include "djonehub_internet_policy.c"
#include <assert.h>
#include <stdlib.h>
int main(void)
{
    char directory[] = "/tmp/djonehub-internet-test.XXXXXX";
    assert(mkdtemp(directory));
    assert(chdir(directory) == 0);
    assert(write_value("v4", 1) == 0 && write_value("v6", 2) == 0);
    assert(djonehub_internet_state() == 2);
    assert(djonehub_internet_set(0) == 0);
    assert(djonehub_internet_state() == 1);
    assert(djonehub_internet_set(0) == 0);
    assert(write_value("v4", 1) == 0 && write_value("v6", 2) == 0);
    djonehub_internet_restore();
    assert(djonehub_internet_state() == 1);
    assert(djonehub_internet_set(1) == 0);
    assert(read_value("v4") == 1 && read_value("v6") == 2);
    assert(djonehub_internet_set(1) == 0);
    assert(djonehub_internet_set(2) != 0);
    assert(unlink("v6") == 0);
    assert(djonehub_internet_state() == 0);
    assert(djonehub_internet_set(0) != 0 && read_value("v4") == 1);
    assert(unlink("v4") == 0);
    assert(chdir("/") == 0);
    assert(rmdir(directory) == 0);
    puts("Internet policy persistence, restoration and unknown state: PASS");
    return 0;
}
