# Performance & Resource Usage Verification

RaindropShot is built around one core principle:
> **When nothing needs to happen, essentially nothing should be running.**

This document provides measured data and the exact commands to independently verify that RaindropShot uses zero idle memory for background uploads, near-zero CPU, and minimal network calls.

---

## 1. Measured Benchmarks

Measurements conducted on Apple Silicon (macOS Sonoma / Sequoia / Tahoe):

| Component | Metric | Measured Value | Comparison with Legacy Node.js |
| :--- | :--- | :--- | :--- |
| **Background Worker Idle RAM** | Resident Memory | **0.0 MB** (Process terminates) | ~70–120 MB permanently resident |
| **Background Worker Idle CPU** | CPU Usage | **0.0%** (Process does not exist) | Constant timer / FS events polling |
| **Background Worker Peak RAM** | Peak Footprint | **~3.0 MB** | ~120 MB Node runtime initialization |
| **Background Worker Run Duration** | Execution Time | **0.01s – 0.05s** (10–50 ms) | Permanently running daemon |
| **Menu Bar Controller Idle CPU** | CPU Usage | **0.0%** | N/A (Node version had no UI) |
| **Menu Bar Controller Idle RAM** | Resident RSS | **~50 MB** (Standard AppKit) | N/A |
| **Network Requests per Screenshot** | HTTP Calls | **1** (`PUT /raindrop/file`) | 3 (`/raindrops/0`, `/raindrop/file`, `/user`) |

---

## 2. Verification Steps

### A. Verify Background Worker is NOT Resident When Idle

The background worker performs one unit of work and terminates immediately. Verify that no worker process remains alive:

```bash
# Check if any worker process is currently running:
pgrep -l RaindropShotWorker
```
*Expected result:* Empty output (exit code 1). No process exists.

### B. Verify Worker Runtime & Peak Memory Footprint

Use macOS's `/usr/bin/time -l` to inspect maximum resident set size (RSS), page faults, and real runtime:

```bash
/usr/bin/time -l .build/release/RaindropShotWorker --dry-run
```

*Sample Output:*
```text
Finished run. Health: ok, Message: Synced, Pending: 0
        0.01 real         0.00 user         0.00 sys
            10223616  maximum resident set size
             3015256  peak memory footprint
```
- Real runtime: **10 ms** (0.01s)
- Peak memory footprint: **~3.0 MB**

### C. Verify Menu Bar App Idle CPU

Launch the menu bar app and inspect its CPU utilization:

```bash
# Start menu bar app in background
./RaindropShot.app/Contents/MacOS/RaindropShot &
PID=$!

# Wait 2 seconds for AppKit runloop to settle
sleep 2

# Inspect CPU and memory
ps -o pid,rss,%cpu,command -p $PID

# Clean up
kill $PID
```

*Sample Output:*
```text
  PID    RSS  %CPU COMMAND
83676  52096   0.0 ./RaindropShot.app/Contents/MacOS/RaindropShot
```
Notice `%CPU` is **0.0%**. The menu bar application contains zero polling timers; it wakes only on user interaction or upon receiving an asynchronous Darwin kernel notification (`com.tejxv.RaindropShot.status-changed`) posted by the worker.

### D. Verify Network Requests per Screenshot

Unlike the legacy implementation which made:
1. `GET /raindrops/0?search=...` (redundant remote deduplication query)
2. `PUT /raindrop/file` (upload with full file buffered in Node memory)
3. `GET /user` (quota information fetched after every single upload)

RaindropShot uses durable local state in `~/Library/Application Support/RaindropShot/state.json`:
- **Pre-upload check:** 0 network requests. Deduplication is handled locally via filesystem device and inode tracking.
- **Upload:** Exactly 1 multipart request streamed directly from a disk-backed temporary file via `URLSession.uploadTask(with:fromFile:)`. Memory does not buffer multi-megabyte screenshots.
- **Post-upload quota:** 0 network requests. Quota is only queried on demand when the user clicks "Test" in Settings.

---

## 3. Kernel Sample & Memory Map Deep-Dive

An empirical analysis using Apple's official diagnostic tools (`/usr/bin/sample` and `/usr/bin/vmmap`) on a running production `RaindropShot` instance reveals:

### A. 100% Idle Kernel Traps (`/usr/bin/sample`)
When sampled continuously across 2,530 consecutive 1ms intervals:
* **Main Thread (`Thread_4077963`)**: 2,530 / 2,530 samples (100.0%) blocked in `mach_msg2_trap` waiting on `ReceiveNextEventCommon` / `RunCurrentEventLoopInMode`.
* **NSEventThread (`Thread_4077986`)**: 2,530 / 2,530 samples (100.0%) blocked in `mach_msg2_trap`.
* **Grand Central Dispatch Workqueues**: Parked in `__workq_kernreturn`.

**Result:** True **0.0% CPU usage** at idle. No background timers, no busy-waiting, no polling loops.

### B. Virtual Memory Anatomy (`/usr/bin/vmmap`)
* **Physical Footprint:** ~32 MB (macOS Sequoia / Darwin 26 system baseline for an active `NSApplication` connected to WindowServer / SkyLight).
* **Actual App Heap:** Only **~3.2 MB resident dirty allocations** across the entire application runtime.
* **Shared Libraries (`dyld`):** ~26.2 MB in `__AUTH_CONST` / `__DATA_CONST` (read-only shared pages mapped from macOS system libraries).
* **Leak Analysis (`/usr/bin/leaks`):** Zero app-level leaks.

---

## 4. Ultra-Low-Memory Mode (Zero Visible Processes)

Because the menu bar controller is optional and independent of the background worker:
1. Configure settings once via the UI or `settings.json`.
2. Quit the menu bar application (`Quit RaindropShot Menu Bar`).
3. The background LaunchAgent continues executing `RaindropShotWorker` every 5 minutes (or your configured cadence).
4. Between sync intervals, **zero processes are running and memory consumption is 0.0 MB**.

