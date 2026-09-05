#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/utsname.h>
#include <unistd.h>

int main(void) {
  struct utsname info;
  atomic_uint_fast64_t counter = 40;
  volatile double a = 1.5;
  volatile double b = 2.0;
  uint64_t previous = atomic_fetch_add(&counter, 2);
  if (uname(&info) || previous != 40 || atomic_load(&counter) != 42 || a * b != 3.0) {
    fputs("RV64GC smoke: FAIL\n", stderr);
    return 1;
  }
  printf("RV64GC smoke: PASS; machine=%s; atomics=42; fp=3.0\n", info.machine);
  fflush(stdout);
  const char *poweroff = getenv("K3_SMOKE_POWEROFF");
  if (getpid() == 1 && poweroff && strcmp(poweroff, "1") == 0) {
    sync();
    if (reboot(RB_POWER_OFF)) {
      perror("poweroff");
      return 2;
    }
  }
  return 0;
}
