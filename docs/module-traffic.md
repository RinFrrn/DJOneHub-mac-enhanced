# Module traffic metering

AirPhone's module panel exposes 网速与流量. The authenticated TLS POST
`/v1/traffic` accepts `{}` with an active long-term device credential and does
not issue or rotate a voice session.

The module samples `/proc/net/dev` once per second and sums logical
`rmnet_data*` interfaces only. The QDC507 uses `rmnet_data0` for its default
IPv4 and IPv6 routes; `rmnet0` is a parent carrying duplicate traffic.
USB ECM, bridge, loopback and phone PCM traffic are excluded.

Rates use monotonic sample intervals. Counters moving backwards establish a
new baseline. Boot counters reflect the current kernel interface counters;
an interface recreation can reset these even without a full module reboot.
Persistent totals count from activation of the meter, survive daemon restarts,
and are saved privately and atomically to the pairing directory's `traffic.json`
every minute and on graceful shutdown. Abrupt power loss can lose at most the
unflushed interval. Traffic while the metering daemon is stopped is not counted.

iOS polls only while the traffic view is active, at one-second intervals after
success and five-second intervals after failure. Failure preserves the displayed
totals while replacing the rates with a dash. The meter runs independently of
the app. Values are device estimates, not carrier billing records.

The traffic request can include an authenticated iPhone Unix timestamp and
timezone offset, plus optional `plan_gb` and `billing_day` (1–28). The module
advances this clock with monotonic elapsed time and requires calibration after
daemon restart. Daily byte buckets are retained for one year and recalculated
when the billing day changes. Unknown-time traffic stays in `unassigned` and
the lifetime totals, never silently attributed to a billing month. Plan values
use decimal GB. The first billing cycle contains only recorded usage; it cannot
recover carrier usage from before activation. SIM attribution and history
charts remain future work.

The module menu now displays live upload/download rates and current-cycle
usage. It polls only while that menu is active. The history page requests
`history: true` to obtain an independent copy of the daily buckets, groups
them by calendar month, and loads on entry or pull-to-refresh. Normal one-second
traffic responses omit the historical buckets.

SIM accounting uses a read-only module-local DMS Get ICCID request.
A separate bounded monitor query runs every five seconds, outside the
voice path. Only a SHA-256-derived account key and the ICCID's last four digits
are persisted. Consecutive identity observations must agree before pending
traffic is attributed; transitions and failed queries use the unknown account.
If the vendor query terminates by signal, polling stops until runtime restart
instead of repeatedly launching a crashing process.
The short identity polling window can still miss a complete switch-and-return
between observations. Kernel boot counters remain module-wide.

Each account has independent totals, daily history, quota and billing day.
Legacy pre-accounting records migrate to the unknown account without guessing
their SIM. Requests saving a plan carry the expected account key and fail if
the SIM changed while the settings form was open. Unsampled identity intervals
at shutdown are conservatively persisted as unknown usage.
