/* Temporary recovery timer for host userspace-transition experiments. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t cancelled;

static void cancel_guard(int signal_number) {
  (void) signal_number;
  cancelled = 1;
}

int main(int argc, char **argv) {
  char *end;
  if (argc != 3 || getuid() != 0) {
    fprintf(stderr, "Usage (root): %s SECONDS observe|reboot\n", argv[0]);
    return 2;
  }
  errno = 0;
  long seconds = strtol(argv[1], &end, 10);
  if (errno || *end || seconds < 30 || seconds > 600 ||
      (strcmp(argv[2], "observe") && strcmp(argv[2], "reboot"))) {
    fprintf(stderr, "Duration must be 30..600 seconds; specify observe or reboot.\n");
    return 2;
  }
  struct sigaction action = { .sa_handler = cancel_guard };
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGUSR1, &action, NULL);
  int log = open("/var/lib/omarchy-k3-boot-trials/guard.log", O_WRONLY | O_CREAT | O_APPEND, 0600);
  int pid_file = open("/run/omarchy-k3-boot-guard.pid", O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (log < 0 || pid_file < 0) {
    perror("guard state");
    return 1;
  }
  dprintf(pid_file, "%ld\n", (long) getpid());
  close(pid_file);
  struct timespec started, now, interval = { .tv_sec = 1 };
  if (clock_gettime(CLOCK_BOOTTIME, &started) < 0) return 1;
  dprintf(log, "armed pid=%ld deadline_seconds=%ld mode=%s\n", (long) getpid(), seconds, argv[2]);
  fsync(log);
  for (;;) {
    if (cancelled) {
      dprintf(log, "cancelled pid=%ld\n", (long) getpid());
      fsync(log);
      close(log);
      return 0;
    }
    if (clock_gettime(CLOCK_BOOTTIME, &now) < 0) return 1;
    long elapsed = now.tv_sec - started.tv_sec;
    if (elapsed >= seconds) break;
    nanosleep(&interval, NULL);
  }
  dprintf(log, "expired pid=%ld mode=%s\n", (long) getpid(), argv[2]);
  fsync(log);
  if (!strcmp(argv[2], "observe")) {
    close(log);
    return 0;
  }
  sync();
  if (reboot(RB_AUTOBOOT) < 0) {
    dprintf(log, "reboot failed: %s\n", strerror(errno));
    fsync(log);
    return 1;
  }
  return 0;
}
