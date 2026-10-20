# Architecture and source walkthrough

## System boundary

Build a Python desktop application around the vendor Automation API. Keep scheduling and user interaction on the GUI side, execute acquisition in a worker, and retain raw transitions alongside timestamped result and event logs. Separate the capture scheduler from experimental recovery utilities so ordinary recording does not silently inherit device-reset behavior.

```mermaid
flowchart LR
    A["Plan test windows"] --> B["Acquire via API"]
    B --> C["Analyze transitions"]
    C --> D["Retain test evidence"]
```

This is a source-derived conceptual diagram, not a captured execution trace. The text equivalent is Plan test windows → Acquire via API → Analyze transitions → Retain test evidence.

## Source responsibilities

| Source entry point | Responsibility |
|---|---|
| [`SaleaeClockMonitorWindow`](../sampling-assistant/app.py#L1686) | Owns configuration, scheduled start/stop windows, progress and operator actions. |
| [`SaleaeMonitorWorker`](../sampling-assistant/app.py#L399) | Runs capture work away from the GUI thread. |
| [`analyze_reference_clock`](../sampling-assistant/app.py#L298) | Checks reference-clock behavior in exported transitions. |
| [`analyze_ssi_clock_rx`](../sampling-assistant/app.py#L333) | Analyzes the reconstructed SSI receive-side clock. |
| [`compare_to_baseline`](../sampling-assistant/app.py#L363) | Compares analyzed values with configured reference behavior. |
| [`hard_restart`](../recovery/saleae-guard/saleae_guard.py#L293) | Experimental software recovery path; not the confirmed isolation remedy. |

## Design decisions

### Use the vendor API

Explicit capture calls are more controllable than operating a desktop window through keystrokes. The legacy recovery experiment remains separate because its keyboard-driven behavior has different risks.

### Separate capture, analysis and evidence

A result summary should remain traceable to a captured interval. Raw transition exports and event timestamps support that traceability.

### Distinguish the device from the measurement chain

A broken USB session is a logging-system event, not by itself evidence that the marine module failed. Physical USB isolation addressed the reported disturbance path.

## Input/output contract to preserve

The input configuration must be recoverable alongside the output. Defaults should be treated as this implementation’s starting values, not an external standard. An integration test must check the real host/runtime because an isolated function test cannot establish timing, UI, hardware or external-service behavior.

When modifying the code, identify which responsibility changes: input acquisition, interpretation, persistent state or output presentation. Keep the public behavior and its test evidence together. Avoid silently converting a missing input or failed integration into a successful result.

## Known boundaries

- Recorded use is author-confirmed; no private test report or certificate is published.
- Time saved, unattended test hours, recovery success rate and approval completion are not quantified.
- The software supports a test workflow; it is not a certified instrument and does not issue Type Approval.
- A watchdog may restart or terminate measurement processes. It must be evaluated independently from normal scheduled capture.
