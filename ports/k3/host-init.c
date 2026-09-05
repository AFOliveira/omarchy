/* One-shot Arch host trial, reached through the unchanged vendor initramfs.
 * Restore the next boot to Bianbu before switching to the staged Arch root.
 * This does not protect against a kernel hang before this program starts.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef BOOT_DEVICE
#define BOOT_DEVICE "/dev/disk/by-partuuid/dea91215-8a70-4045-82b5-33296f8be0ac"
#endif
#ifndef GUARD_SECONDS
#define GUARD_SECONDS "600"
#endif
#define TRIAL_DIR "/var/lib/omarchy-k3-baremetal"
#define ARCH_ROOT TRIAL_DIR "/rootfs"
#define GUARD "/usr/local/lib/omarchy-k3/boot-guard"
#define GUARD_PID "/run/omarchy-k3-boot-guard.pid"
#define INIT_LOG "/var/lib/omarchy-k3-boot-trials/physical-init.log"

static const char stock_env[] =
  "knl_name=vmlinuz-6.18.3-generic\n"
  "ramdisk_name=initrd.img-6.18.3-generic\n"
  "dtb_dir=spacemit/6.18.3-generic\n"
  "ramdisk_addr=0x130000000\n"
  "loglevel=8\n"
  "commonargs=setenv bootargs plymouth.prefer-fbcon plymouth.ignore-serial-consoles splash\n";

static int log_fd = -1;

static void record(const char *message) {
  dprintf(STDERR_FILENO, "Omarchy host trial: %s\n", message);
  if (log_fd >= 0) {
    dprintf(log_fd, "%s\n", message);
    fsync(log_fd);
  }
}

static void fallback(const char *reason) {
  record(reason);
  record("Continuing with the existing Bianbu init.");
  execl("/sbin/init", "/sbin/init", (char *) NULL);
  record("Bianbu init failed; requesting recovery reboot.");
  sync();
  reboot(RB_AUTOBOOT);
  for (;;) pause();
}

static int restore_boot(void) {
  if (mount(BOOT_DEVICE, "/boot", "ext4", 0, NULL) < 0) return -1;
  int current = open("/boot/env_k3.txt", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  char contents[4096] = {0};
  ssize_t length = current < 0 ? -1 : read(current, contents, sizeof(contents) - 1);
  if (current >= 0) close(current);
  int result = -1;
  if (length <= 0 || !strstr(contents, "omarchy.host_trial=1")) goto done;
  int replacement = open("/boot/.omarchy-env-restore", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
  if (replacement < 0) goto done;
  size_t offset = 0;
  while (offset < sizeof(stock_env) - 1) {
    ssize_t count = write(replacement, stock_env + offset, sizeof(stock_env) - 1 - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (size_t) count;
  }
  int flushed = fsync(replacement);
  close(replacement);
  if (offset != sizeof(stock_env) - 1 || flushed < 0) goto remove_temp;
  if (rename("/boot/.omarchy-env-restore", "/boot/env_k3.txt") < 0) goto remove_temp;
  int directory = open("/boot", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (directory >= 0) {
    result = fsync(directory);
    close(directory);
  }
remove_temp:
  unlink("/boot/.omarchy-env-restore");
done:
  if (umount("/boot") < 0) result = -1;
  return result;
}

static pid_t start_guard(void) {
  unlink(GUARD_PID);
  pid_t pid = fork();
  if (pid == 0) {
    setsid();
    execl(GUARD, GUARD, GUARD_SECONDS, "reboot", (char *) NULL);
    _exit(127);
  }
  if (pid < 0) return -1;
  for (int attempt = 0; attempt < 50; attempt++) {
    if (waitpid(pid, NULL, WNOHANG) == pid) return -1;
    FILE *state = fopen(GUARD_PID, "r");
    long observed = -1;
    if (state) {
      int parsed = fscanf(state, "%ld", &observed);
      fclose(state);
      if (parsed == 1 && observed == (long) pid) return pid;
    }
    usleep(100000);
  }
  kill(pid, SIGTERM);
  return -1;
}

int main(void) {
  if (getpid() != 1 || getuid() != 0) {
    fprintf(stderr, "This temporary boot init can run only as host PID 1.\n");
    return 2;
  }
  if (mount(NULL, "/", NULL, MS_REMOUNT, NULL) < 0) fallback("Cannot make the existing root writable.");
  log_fd = open(INIT_LOG, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  record("Physical startup program reached as PID 1.");
  if (restore_boot() < 0) fallback("Could not confirm restoration of the stock boot selection.");
  record("Stock kernel/initramfs/DTB selection restored and synchronized.");
  if (access(TRIAL_DIR "/armed", F_OK) < 0 ||
      access(ARCH_ROOT "/.omarchy-k3-host-ready", F_OK) < 0 ||
      access(ARCH_ROOT "/usr/lib/systemd/systemd", X_OK) < 0 ||
      access("/usr/bin/switch_root", X_OK) < 0 || access(GUARD, X_OK) < 0) {
    fallback("Trial prerequisites are missing.");
  }
  if (unlink(TRIAL_DIR "/armed") < 0) fallback("Cannot consume the one-shot trial marker.");
  sync();
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0 ||
      mount(ARCH_ROOT, ARCH_ROOT, NULL, MS_BIND, NULL) < 0) {
    fallback("Cannot prepare the Arch root mount.");
  }
  pid_t guard = start_guard();
  if (guard < 0) fallback("Recovery timer did not start.");
  record("Recovery timer armed for " GUARD_SECONDS " seconds; handing PID 1 to Arch.");
  execl("/usr/bin/switch_root", "switch_root", ARCH_ROOT, "/usr/lib/systemd/systemd", (char *) NULL);
  kill(guard, SIGTERM);
  fallback("Could not execute switch_root.");
}
