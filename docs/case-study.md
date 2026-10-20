# Engineering case study: Saleae Test Automation

## 1. The task and operating context

Extend the Saleae workflow with scheduled recording windows and duration-controlled capture so a marine control and monitoring module can be observed through a PC during performance testing.

The author used this software while supporting Type Approval activities for a Control and Monitoring Module for Marine under test plans referring to DNV-CG-0339 and LR-TS-01. Product identities, employers, laboratories, and customer names are withheld.

## 2. The problem before the tool

The test setup required PC-based logging of CAN/SSI communication and periodic operating-status signals. The workflow needed reservation-style start/stop times and timed recording periods that the author could not obtain from the Saleae application workflow used on site. Repeating these operations manually made the operator part of the acquisition schedule.

## 3. The intervention

Build a Python desktop application around the vendor Automation API. Keep scheduling and user interaction on the GUI side, execute acquisition in a worker, and retain raw transitions alongside timestamped result and event logs. Separate the capture scheduler from experimental recovery utilities so ordinary recording does not silently inherit device-reset behavior.

### Input → decision → output

1. **Input:** Plan test windows.
2. **Processing:** Acquire via API.
3. **Interpretation:** Analyze transitions.
4. **Output:** Retain test evidence.

This workflow is illustrated in the README and is mapped to actual source entry points in [architecture](architecture.md).

## 4. Work enabled by the implementation

- Prepare start/stop windows before a test instead of manually starting every acquisition.
- Use duration and interval settings to collect the required portions of product performance data.
- Review captured clock and SSI behavior together with acquisition events rather than relying only on a live display.

The author confirms that the scheduler was used during actual product performance logging. Burst and surge energy also affected the PC USB path through the measurement setup and caused device disconnections. A USB isolator was introduced and resolved that connection problem. The repository does not attribute that physical-layer fix to its recovery code.

## 5. Technical choices and tradeoffs

### Use the vendor API

Explicit capture calls are more controllable than operating a desktop window through keystrokes. The legacy recovery experiment remains separate because its keyboard-driven behavior has different risks.

### Separate capture, analysis and evidence

A result summary should remain traceable to a captured interval. Raw transition exports and event timestamps support that traceability.

### Distinguish the device from the measurement chain

A broken USB session is a logging-system event, not by itself evidence that the marine module failed. Physical USB isolation addressed the reported disturbance path.

## 6. Engineering contribution

Schedule start/stop windows and duration-controlled capture through the vendor API. The linked architecture document identifies implementation entry points; validation records distinguish source inspection, executable checks and hardware-dependent behavior.

## 7. Evidence and scope

Python AST parsing completed. Actual Logic 2/device capture, timing accuracy, USB disturbance behavior and duration limits have not been rerun in this preparation environment.

- Recorded use is author-confirmed; no private test report or certificate is published.
- Time saved, unattended test hours, recovery success rate and approval completion are not quantified.
- The software supports a test workflow; it is not a certified instrument and does not issue Type Approval.
- A watchdog may restart or terminate measurement processes. It must be evaluated independently from normal scheduled capture.

## 8. Next measurable milestone

- [ ] Reproduce a scheduled start/stop test with a small public synthetic signal.
- [ ] Add device-disconnect and cancellation integration tests without publishing private captures.
- [ ] Document a neutral export schema and an example test-evidence package.

## Before and after the intervention

| Before | Implementation | Work enabled and evidence |
|---|---|---|
| Capture windows depended on an operator starting and stopping recording. | Schedule start/stop windows and duration-controlled capture through the vendor API. | The software was used for product performance logging during marine Type Approval work. |
