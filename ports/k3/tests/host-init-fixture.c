/* Minimal PID 1 programs for the isolated QEMU host-init recovery test. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <unistd.h>

int main(int argc, char **argv) {
  (void) argc;
  setbuf(stdout, NULL);
  if (!strcmp(argv[0], "/bootstrap")) {
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 && errno != EBUSY) return 1;
    if (mount("proc", "/proc", "proc", 0, NULL) < 0) return 1;
    if (mount("sysfs", "/sys", "sysfs", 0, NULL) < 0) return 1;
    if (mount("tmpfs", "/run", "tmpfs", 0, NULL) < 0) return 1;
    execl("/usr/local/lib/omarchy-k3/host-init", "host-init", (char *) NULL);
    return 1;
  }
  if (getpid() != 1) return 1;
  if (access("/arch-fixture", F_OK) == 0) {
    printf("HOST_INIT_TEST: Arch root reached as PID 1\n");
    FILE *state = fopen("/run/omarchy-k3-boot-guard.pid", "r");
    long pid = -1;
    if (!state || fscanf(state, "%ld", &pid) != 1) return 1;
    fclose(state);
    printf("HOST_INIT_TEST: waiting for recovery guard %ld\n", pid);
    for (;;) pause();
  }
  printf("HOST_INIT_TEST: Bianbu fallback reached as PID 1\n");
  sync();
  reboot(RB_POWER_OFF);
  for (;;) pause();
}
