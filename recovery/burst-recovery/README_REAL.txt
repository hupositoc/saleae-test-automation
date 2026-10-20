BurstRecovery: historical USB recovery experiment

This PowerShell version monitors Saleae/Kvaser device presence and communication state, attempts device scanning/restarts, and uses keyboard commands in parts of its recovery flow. Review the source and device identifiers before running it. It requires an appropriately authorized Windows test environment and can affect measurement sessions and device state.

It is preserved as a separate experiment, not as proof of the reported solution to the test site's physical USB disturbance. The author confirms that USB isolation resolved that issue. Scheduled performance logging is implemented in sampling-assistant/app.py; do not confuse that use with a verified watchdog recovery result.

There is no START_REAL.bat launcher in this curated package. Read the PowerShell script and adapt it deliberately rather than following an absent historical launcher path. Original hardware timing/recovery behavior has not been reproduced here.
