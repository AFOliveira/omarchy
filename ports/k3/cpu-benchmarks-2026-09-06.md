# K3 CPU and browser bottleneck diagnosis — 2026-09-06

The tested browser is CPU-bound in its software compositing path: Chromium’s Viz compositor thread saturates one core while the renderer main thread is mostly idle. The eight available CPU cores scale normally on the tested parallel workloads. This supports focusing optimization work on browser compositing/presentation and the graphics path; it does not prove that the CPU’s single-thread performance is irrelevant, or that enabling GPU acceleration alone will fix everything.

## Environment and scope

Physical K3, vendor Linux 6.18.3-generic, native Arch RISC-V userspace, current Omarchy port. GCC 16.2.1, sysbench 1.0.20, OpenSSL 3.6.4, Chromium 148.0.7778.215. Chromium used an isolated profile and `--disable-gpu`, matching the existing working configuration, with its sandbox retained. Hyprland used the existing vendor graphics stack and virtual 1920×1080 output. Decorative demo services were frozen during testing. Other existing desktop applications remained present.

The session’s affinity is CPUs 0–7. Setting the test process’s affinity to CPU 8 returned EINVAL; the reason for that restriction was not established. `lscpu -e` maps CPUs 0–7 to the 2.4 GHz maximum-frequency group. All frequency samples reported 2.2 GHz for that group and 1.8 GHz for CPUs 8–15, both with the userspace governor. No frequencies, governors, CPU restrictions, kernel settings or desktop/browser defaults were changed. User and user-1000 slice CPU quotas were `max 100000`.

## Native CPU scaling

`sysbench cpu --cpu-max-prime=10000 --threads=N --time=5 run`, three runs per thread count. These are synthetic prime-calculation events, not a general-purpose CPU rating.

| Threads | Median events/s | Speedup over one thread |
|---|---:|---:|
| 1 | 1,641.99 | 1.00× |
| 2 | 3,277.87 | 2.00× |
| 4 | 6,563.32 | 4.00× |
| 8 | 13,051.17 | 7.95× |

Linux performance counters were collected through `perf_event_open` with user-space cycles, instructions and task-clock, inheriting into the benchmark’s child threads/processes. The stock `perf` package could not be fetched: all configured mirrors returned 404 for the version in the installed repository metadata. No system upgrade or performance-security setting change was made. The small counter wrapper and its source are included with the results.

The first single-thread run consumed 0.999 CPU cores; the first eight-thread run consumed 7.92 cores. Counts were not multiplexed: enabled and running times matched. Measured cycles/task-clock imply about 2.19 GHz. IPC was about 0.59 on this division-heavy prime workload; this value alone is not evidence of a processor or optimization defect. All benchmark subprocesses exited successfully, and all requested counters opened successfully.

The hottest sensor sampled during the native suite was 62°C. Sampled frequencies stayed constant. This provides no evidence of frequency throttling in this short run, not a guarantee against all forms of throttling under longer loads.

## Controlled compiler optimization comparison

A small native floating-point array triad (`a[i] = b[i] + 3*c[i]`) was built three ways and pinned to CPU 2. Each timed run lasted at least two seconds, repeated three times. All elements were checked for correctness after every run, and floating-point contraction was disabled consistently. These are diagnostic kernels, not an official STREAM benchmark.

| Build | 768 KiB combined working set | 48 MiB combined working set |
|---|---:|---:|
| O0 | 2.34 GB/s | 2.31 GB/s |
| O3-scalar | 8.49 GB/s | 8.60 GB/s |
| O3-rvv | 14.98 GB/s | 9.35 GB/s |

Scalar flags: `-O3 -fno-tree-vectorize`. Vector flags: `-O3 -march=rv64gcv -mabi=lp64d`. Disassembly confirms `vle32.v`, `vfmul.vv`, `vfadd.vv` and `vse32.v` in the vector loop. Reported bandwidth counts two logical reads and one write per element; it is not a direct measurement of memory-controller traffic.

RVV is 1.76× faster than optimized scalar code for the cache-sized working set, and 1.09× for the larger working set. Compared with `-O0`, optimized scalar code is 3.63× faster in the small case. This demonstrates optimization headroom for this loop; it does **not** establish that Chromium was built unoptimized or will receive the same gains from compiler flags.

Sysbench’s repeated 1 MiB global-buffer reads reached 18,727 MiB/s with one thread and 33,335 MiB/s with eight. Those reads heavily exercise caches and shared-buffer behavior; they should not be presented as sustainable DRAM bandwidth. The larger triad above provides a separate streaming-working-set result.

## Existing library optimization: SHA-256

OpenSSL speed used 16 KiB messages and three-second wall-clock runs. Its normal hardware detection reports RISC-V vector/crypto extensions and a 256-bit vector length. In three CPU-2-pinned runs per mode:

| Mode | Median throughput |
|---|---:|
| Normal runtime feature detection | 843.08 MB/s |
| Optional extensions disabled for this subprocess (`OPENSSL_riscvcap=rv64gc`) | 127.49 MB/s |

Normal feature dispatch is **6.61× faster**. The environment override was scoped to the benchmark subprocesses. A separate normal run reached 841.60 MB/s with one worker and 6,716.07 MB/s with eight. This is concrete evidence that at least some installed libraries already use accelerated RISC-V code paths effectively; the userspace is not uniformly missing optimization.

## Browser bottleneck

The same local 3,000-row scrolling fixture was used at two document viewport sizes, retaining the actual browser window and desktop output. CDP device-metrics overrides changed the document viewport; this was not a physical monitor-resolution change. Each condition collected 60 animation callbacks, with three alternating full/small trials. The first full-size trial also enabled tracing; later full-size trials were similar without tracing.

| Document viewport | Median of per-run mean callback intervals | Approximate callbacks/s |
|---|---:|---:|
| 1896×943 | 164.21 ms | 6.09 |
| 800×600 | 44.82 ms | 22.31 |

The smaller viewport improves callback rate about 3.66×. This is evidence of a rendering-area-dependent bottleneck, not a website/network limit. Callback rates are not measured physical display or VNC FPS.

In the full-size traced interval, Chromium’s VizCompositorThread `RunTask` events totalled **9.958 seconds elapsed and 9.950 seconds thread CPU time**. Renderer main-thread tasks totalled approximately **0.103 seconds elapsed and 0.101 seconds CPU time**. This distinguishes active CPU work from a thread merely waiting for a frame or driver response. These totals compare the same event type across threads; nested paint/layout events were not added to the totals.

A separate repeated full-size scrolling run was cross-checked against Linux `/proc` per-thread CPU accounting. During a 27.28-second interior interval entirely within active scrolling:

| Thread | CPU usage, where 100% is one core |
|---|---:|
| Chromium VizCompositorThread | 99.15% |
| Hyprland main thread | 13.38% |
| Chromium renderer main thread | 0.84% |
| Chromium renderer compositor thread | 0.77% |

This establishes a single-thread CPU bottleneck in the tested software-compositing path. The available spare cores do not automatically help this serial stage. Main-thread JavaScript and page layout are not the dominant work in this particular scrolling test. It does not establish that JavaScript-heavy sites cannot separately be limited by CPU performance.

## Practical conclusion and limits

The current evidence favors investigating Chromium’s software Viz compositing/output path and a compatible accelerated graphics path before rebuilding all of Arch or blaming the kernel. Native CPU scaling and accelerated crypto look internally consistent. Browser responsiveness remains constrained by one busy compositing thread, so both the software implementation and the single core’s throughput matter.

No cross-machine baseline was measured, so these tests cannot rank K3 single-thread performance against a current x86/Arm desktop. No fully accelerated Chromium configuration was validated, and there is no function-level native profile identifying the exact hot routine inside Viz. The tests establish where to investigate next, not a completed performance fix.

## Evidence, sources and restoration

Raw evidence and test sources are local under `build/k3-cpu-bench/` (ignored by Git):

- [Native results and counter output](../../build/k3-cpu-bench/results.json)
- [Frequency and temperature samples](../../build/k3-cpu-bench/samples.json)
- [OpenSSL capability comparison](../../build/k3-cpu-bench/crypto-compare.json)
- [Browser viewport measurements](../../build/k3-cpu-bench/browser-diagnostic.json)
- [Chromium trace, including thread CPU durations](../../build/k3-cpu-bench/browser-trace.json)
- [Linux thread CPU samples](../../build/k3-cpu-bench/browser-thread-samples.json)
- [Matching scrolling interval](../../build/k3-cpu-bench/scroll-sample.json)
- [Native test runner](../../build/k3-cpu-bench/run.py), [array kernel](../../build/k3-cpu-bench/kernels.c), [counter wrapper](../../build/k3-cpu-bench/counters.c)

Method references: [sysbench](https://github.com/akopytov/sysbench), [Linux perf-event permissions](https://docs.kernel.org/admin-guide/perf-security.html), [OpenSSL speed](https://docs.openssl.org/3.1/man1/openssl-speed/), [OpenSSL RISC-V feature override](https://docs.openssl.org/3.6/man3/OPENSSL_riscvcap/).

The benchmark browser and its CDP tunnel were stopped; the CDP port is no longer listening. All six demo services were verified thawed, WayVNC remained active, workspace 15 was restored, and hypridle was resumed. Sysbench and its libck dependency remain installed for repeat testing; the failed perf transaction upgraded no packages. Test sources, binaries and isolated browser data remain in the dedicated benchmark directory. The [native diagnostic screenshot](../../build/k3-cpu-bench/browser-diagnostic-desktop.png) was captured with Omarchy’s fullscreen screenshot command and visually inspected.
