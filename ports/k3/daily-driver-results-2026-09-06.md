# K3 Omarchy daily-driver measurements — 2026-09-06

Measurements run on the physical K3, not an emulator or an Arch container. Browser automation was controlled over SSH, but page and frame timing came from Chromium's own performance clock on the board. These are short exploratory tests, not an all-day stability certification or a comparison against an x86 laptop.

Environment: vendor Linux 6.18.3-generic, native Arch RISC-V userspace, Omarchy v3.8.4-based port, Hyprland 0.55.4, Chromium 148.0.7778.215. The board exposes 16 CPUs; the test user has affinity to CPUs 0–7. Memory is approximately 31 GiB. Chromium used the port's `--disable-gpu` workaround, a separate temporary profile, and its normal sandbox. Hyprland uses the vendor graphics stack. Output was virtual 1920×1080 at 60 Hz; WayVNC was capped at 20 FPS.

Earlier decorative demo services were frozen for these tests. Other existing desktop applications remained open. First visits used the new profile; repeats retained cache. Browser page-load events are not the same as first visible content or completion of every background request. The initial website tests used the then-current tiled layout; the rendering tests and Speedometer used a dedicated workspace with a 1896×943 browser viewport.

## Everyday application and storage results

| Test | Result | Meaning |
|---|---:|---|
| Foot terminal window mapped, median of 3 | 125 ms | Local process launch through compositor window discovery; polling overhead included, not keyboard-to-photon latency |
| LazyVim first screen update, median of 3 | 488 ms | Neovim internal startup clock, configured editor opening a 400-line Markdown file; deferred plugins/LSP readiness not included |
| Neovim configured headless start/exit, median of 5 | 73 ms | CLI startup only; not full interactive LazyVim readiness |
| Temporary 256 MiB sequential write plus fsync | 1.71 s / 150 MiB/s | One sample through the root filesystem; temporary file removed |
| Established SSH echo round trip, median of 10 | 291 ms | Range 286–327 ms; includes transport through the provider, excludes SSH connection setup |

The repeat file read hit the Linux page cache (0.050 s); it is **not a disk read-speed measurement**. These tests did not drop system caches.

## Website loading

| Page | First load event | Repeat load event | First contentful paint, first / repeat |
|---|---:|---:|---:|
| Arch homepage | 2.78 s | 0.10 s | 2.60 / 0.37 s |
| GitHub Omarchy repository | 3.69 s | 1.56 s | 2.80 / 1.77 s |

Both returned HTTP 200. First-response times were 1.35 s for Arch and 1.06 s for GitHub on their initial visits. These include the board’s Internet path, DNS, connection setup, redirects and server response. They exclude the user’s SSH-control delay. Wikipedia timed out at 30 seconds on both attempts; MDN returned `ERR_CONNECTION_CLOSED` on both attempts. This establishes failed reachability in this session, not the exact cause or proof of filtering.

## Browser responsiveness

[Speedometer 3.1](https://browserbench.org/Speedometer3.1/) completed its default 580-step run: **3.02 ± 0.095**, as displayed by the benchmark. The uncertainty is the benchmark’s own within-run statistic, not independent repeated-run variability. No x86 or other-board comparison was run.

| Foreground browser workload | Mean callback interval | Approximate callbacks/s |
|---|---:|---:|
| Idle requestAnimationFrame | 16.7 ms | 60.0 |
| Small animated rectangle | 17.9 ms | 55.7 |
| Scripted scroll: https://archlinux.org/ | 107.5 ms | 9.3 |
| Scripted scroll: https://github.com/omacom/omarchy | 131.7 ms | 7.6 |
| Local 3,000-row document scrolling | 167.8 ms | 6.0 |

These are JavaScript `requestAnimationFrame` intervals during programmatic scrolling/animation, **not measured display FPS, mouse-wheel input latency, or VNC-delivered FPS**. The website scroll samples contain 120 callbacks; the Arch page reaches its scroll limit during the test. The synthetic document contains 3,000 styled rows (102,000 px high), and its sample contains 180 callbacks. Creating and laying out those rows took 319 ms. Updating 100 rows and waiting for the next callback took a median 25 ms, with a maximum 167 ms across 10 trials. These workloads demonstrate uneven browser responsiveness; simple animations should not be conflated with document scrolling.

## Resource sample

During a 30-second portion of Speedometer, the dedicated browser cgroup averaged 1.79 CPU cores, peaked at 733 MiB of cgroup-accounted memory, and the machine retained at least 27.8 GiB available RAM. Cgroup memory includes more than private process memory; this is not browser PSS. The hottest thermal sensor sampled was 59°C, compared with 48–54°C in earlier idle/short-test snapshots. This was not a sustained thermal or throttling test. No swap was configured.

## Capture comparison and practical assessment

With WayVNC stopped, the same 3,000-row scrolling workload averaged **167.1 ms** per callback, versus **167.8 ms** with capture running. A small animated rectangle averaged **16.6 ms** without capture and **17.9 ms** with it. These single-run comparisons suggest screen capture is not the main cause of slow document scrolling in this setup. They do not identify whether Chromium software rasterization, buffer upload, compositor behavior, or a combination is responsible. Chromium GPU acceleration remains disabled in this tested configuration; this result is not a measurement of the K3’s best possible browser performance.

The current port looks usable for terminal work and light editing. I would not yet describe its browsing experience as a polished daily driver: normal pages load successfully where reachable, but document scrolling is uneven, and heavier web workloads expose limitations. The approximately 291 ms remote round trip adds a separate delay to interaction from Portugal. A physically attached display should remove that transport delay, but this test does not establish its scrolling performance.

The short run completed without an observed browser/compositor crash. The kernel warning/error journal for the surrounding 30 minutes returned no entries. This does not establish long-term reliability. Video calls, streaming/DRM, audio, suspend/resume, battery behavior, prolonged compilation, large tab sets and an eight-hour workday were not tested. The existing cloud session also lacks an established audio path. No new kernel, driver, browser or Omarchy performance changes were made.

## Evidence and restoration

- [Native desktop screenshot: Speedometer result](../../build/k3-daily-driver/speedometer-desktop.png)
- [Native desktop screenshot: GitHub rendered](../../build/k3-daily-driver/browser-desktop.png)
- [Speedometer full JSON](../../build/k3-daily-driver/speedometer-results.json)
- [Page and synthetic DOM timings](../../build/k3-daily-driver/browser-results.json)
- [Real-page scrolling samples](../../build/k3-daily-driver/site-scroll.json)
- [Capture-disabled synthetic DOM timings](../../build/k3-daily-driver/dom-vnc-off.json)
- [GUI startup measurements and Neovim startup logs](../../build/k3-daily-driver/gui-results.json)
- [Host/CLI/storage measurements](../../build/k3-daily-driver/host-results.json)
- [Browser load/thermal samples](../../build/k3-daily-driver/load-samples.json)
- [SSH RTT samples](../../build/k3-daily-driver/ssh-rtt.json)

The raw evidence and test scripts reside in the local ignored `build/k3-daily-driver/` directory; they are not automatically included in a Git push. Test browser stopped, CDP listener closed, demo services thawed, WayVNC restarted, workspace 15 restored, and hypridle resumed. Temporary disk-test file removed. Screenshots were taken with Omarchy’s fullscreen capture command and visually inspected. The browser profile was isolated from the user’s normal profile.
