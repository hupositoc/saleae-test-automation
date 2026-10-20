# SaleaeGuard: capture-watchdog experiment

This separate Python utility explores capture monitoring through the Saleae Automation API. It checks recording/device state and attempts to recover stale or interrupted sessions. Its source also describes earlier on-site observations about log buffering and keyboard-based capture control; those timings are historical source statements, not freshly reproduced measurements.

## Why it is separate from the scheduler

The confirmed operational use is scheduled/duration-controlled performance logging. In the reported burst/surge incident, energy coupled through the measurement chain affected the PC USB connection. The author resolved that physical connection issue by applying a USB isolator. This watchdog must not be credited with that physical-layer fix.

## Source behavior

`ensure_capturing`, `clear_orphan_sessions` and `hard_restart` address capture/session state. The program can terminate/relaunch Logic, change automation settings and restart captures. Review `--help` and the source before using it with an actual measurement session. API error interpretation and stale-session handling require host/device integration tests.

## Evidence status

The Python source parses successfully. This public preparation did not rerun hardware disconnect/reconnect, validate recovery rates, verify the historical timing observations or establish lossless acquisition. Consult the main case study and validation record for confirmed use and pending tests.
