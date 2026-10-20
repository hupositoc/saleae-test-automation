# Validation and evidence record

## Evidence vocabulary

| Label | Meaning |
|---|---|
| Source inspected | A mechanism exists in the cited implementation; this alone is not proof of successful execution. |
| Locally executed | A named check was run in the current preparation environment, with its scope stated. |
| Author-reported use | Historical operating context supplied by the author; private reports are not published. |
| Pending | A check has not been reproduced and is not presented as a result. |

## Current record

Python AST parsing completed. Actual Logic 2/device capture, timing accuracy, USB disturbance behavior and duration limits have not been rerun in this preparation environment.

**Historical/context statement:** The author confirms that the scheduler was used during actual product performance logging. Burst and surge energy also affected the PC USB path through the measurement setup and caused device disconnections. A USB isolator was introduced and resolved that connection problem. The repository does not attribute that physical-layer fix to its recovery code.

## Integration verification checklist

- [ ] Record exact runtime, dependency versions, input/configuration and date.
- [ ] Run a nominal case with a predictable expected output.
- [ ] Exercise an invalid input or interruption and inspect the failure state.
- [ ] Retain a shareable output and the procedure that produced it.
- [ ] Compare the result with the original task, rather than only checking that the program launched.

## Claims deliberately kept separate

- Recorded use is author-confirmed; no private test report or certificate is published.
- Time saved, unattended test hours, recovery success rate and approval completion are not quantified.
- The software supports a test workflow; it is not a certified instrument and does not issue Type Approval.
- A watchdog may restart or terminate measurement processes. It must be evaluated independently from normal scheduled capture.

An expected output, architecture drawing or sample configuration is not a measured result. This document is the place to add test logs when integration work is actually completed.
