<div align="center">

# Outbound Monitor for OpenWrt

**Availability and HTTP latency history for sing-box / podkop VPN outbounds.**

[English](./README.md) |
[Русский](./docs/README.ru.md) |
[Development](./docs/DEVELOPMENT.md) |
[Разработка](./docs/DEVELOPMENT.ru.md) |
[Releases](https://github.com/romanilyin/outbound-monitor-openwrt/releases)

[![CI](https://github.com/romanilyin/outbound-monitor-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/romanilyin/outbound-monitor-openwrt/actions/workflows/ci.yml)

</div>

Outbound Monitor checks sing-box / podkop VPN outbounds every five minutes through an already enabled Clash API: standalone keys, members of URLTest or selector groups, and podkop VPN sections using a tunnel interface such as WARP. Open **Status → Outbound Monitor** in LuCI.

The original source installation was tested on **OpenWrt 25.12.4**. Release builds target **OpenWrt 25.12.4 / APK** and **24.10.6 / IPK**; the 24.10 target has not been tested on hardware. See the [verification report](./docs/VERIFICATION.md) for the tested revision and scope.

## What it does

- Separate SVG charts for each outbound: HTTP latency in milliseconds, red VPN probe failures at **−10**, and blue points at **−10** for suspected common network failures.
- History for 1 hour, 6 hours, 24 hours or 7 days; inspect points with a mouse, touch or arrow keys, and export the selected period as JSON or CSV.
- A comparison table above the charts: VPN failure percentage, mean HTTP delay, population variance and standard deviation for the selected period.
- Successful-probe percentage, median latency and time of the last successful probe.
- A recommendation to check or replace an outbound after three consecutive failures.
- Distinct states for API errors, missing measurements and stale data.
- Discovery of standalone proxy outbounds, URLTest and selector groups, including nested groups, and matching interface-bound podkop VPN outbounds. Stable hashes preserve history when podkop links change positions and archive a replaced link independently.
- Two direct HTTPS control probes, with optional IPRegion DNS diagnostics when both fail.

These are **HTTP measurements through the VPN**, not ICMP ping. A failure means the chosen HTTPS address could not be checked through that outbound at that moment. Internet, DNS or test-site problems can also cause failures; a failed probe does not prove that a VPN subscription has expired. Percentages describe discrete probes, not continuous uptime.

The comparison table sorts by VPN failure percentage, then mean delay. Failure percentage is `100 × failures / (successes + failures)`. Mean, population variance and standard deviation use **successful probes only**; unknown results (`−1`), suspected common network failures (`−2`) and missing samples are excluded from these metrics. Variance is in ms², standard deviation in ms; one successful sample gives zero variance. Compare sample counts and freshness alongside the figures.

Standalone proxy outbounds are monitored even when no URLTest group references them. A sing-box `direct` outbound bound to an interface is included only when its tag and interface match a podkop section with `connection_type=vpn`. For example, a `warp` section using `interface=awg0` can supply `warp-out` with `bind_interface=awg0`; LuCI displays **Interface: awg0** beside its history and comparison row. Ordinary direct internet outbounds and unrelated interface-bound direct outbounds are excluded from VPN charts. The separate internet control probes retain their existing scope.

## Key identity

The chart ID is always **SHA-256 of the complete canonical outbound configuration, including credentials but excluding its top-level `tag`**. Reordering links or renaming tags updates current API tags and labels while preserving samples. Changing one connection's credentials/settings creates a new identity and archives only its old history. Equivalent duplicate connections share one history and probe, with their tags and groups merged.

For an interface-bound VPN such as WARP, this identity includes the outbound configuration and interface name (for example, `bind_interface=awg0`). Tunnel credentials managed outside sing-box are not visible to the monitor: replacing them while keeping the same outbound and interface name does not create a new chart. Existing URLTest histories keep their IDs.

For matching podkop entries, the monitor separately stores `link_hash`: SHA-256 of the observed UCI link after trimming whitespace and removing its `#fragment` label. This is metadata, **never the history lookup key**, and does not prove that the UCI link was applied. URI labels or parameters that do not change the generated outbound configuration do not split a chart. Raw links are never stored in history or returned through RPC.

Older history transfers only on an exact credential-bearing configuration match; matching server names alone are insufficient, and ambiguous matches remain archived. This identity rule applies immediately, without forcing a VPN restart or waiting to adopt a different ID scheme.

## Common network failures and DNS

With a suitable existing sing-box `direct` outbound available, each collection cycle also probes `https://www.gstatic.com/generate_204` and `https://cp.cloudflare.com/generate_204`. When **both direct checks and every VPN probe fail**, the VPN samples are marked blue as a suspected common network failure. They do not count toward the VPN failure rate or replacement recommendation. If direct checks fail while any VPN probe succeeds, the result is reported as mixed instead.

These controls help distinguish patterns, but do not prove an ISP fault. An eligible direct outbound does not dial through another VPN outbound, but DNS resolution follows existing settings and the system's default route may itself use a VPN. These are not guaranteed physical-WAN checks. Routing, DNS and endpoint failures can affect the diagnosis.

If **IPRegion is already installed**, both failed direct checks can also trigger its DNS diagnostics, including in the mixed case. This is optional (`dns_check=1` by default; set `0` to disable) and does not install IPRegion or change its configuration. The check uses the resolvers and transports available in the installed IPRegion version, including UDP/TCP and DoT/DoH where supported. It runs with `--no-uci`, a two-second request timeout, no retries and an overall 25-second cap, in a separate runtime directory. Installed versions without isolated-runtime support are reported as unsupported and are not run.

DNS checks use the router's route, which is not guaranteed to bypass a VPN. Their results do not prove DNS tampering or identify a provider responsible for a failure. The page shows the latest DNS check time and compact resolver results; the saved result remains available if checks are later disabled or IPRegion is removed, so check its timestamp. At most **128 detailed network/DNS incidents** are kept within the configured retention period (up to seven days), alongside the latest DNS result. JSON exports include these records; per-key charts retain their full configured period independently.

## Install

Run as root on the router:

```sh
wget -qO- https://raw.githubusercontent.com/romanilyin/outbound-monitor-openwrt/main/install.sh | sh
```

The installer detects `apk` or `opkg`, downloads matching packages from the latest stable [GitHub Release](https://github.com/romanilyin/outbound-monitor-openwrt/releases/latest), verifies them against `SHA256SUMS` and installs all three packages:

| Package | Purpose |
| --- | --- |
| `outbound-monitor` | Collector, CLI and procd service |
| `luci-app-outbound-monitor` | LuCI page with English source strings |
| `luci-i18n-outbound-monitor-ru` | Russian LuCI translation |

The packages contain scripts and web assets and are architecture-independent. Native dependencies come from the router's configured OpenWrt feeds, which must match its firmware.

To install a specific release:

```sh
wget -qO- https://raw.githubusercontent.com/romanilyin/outbound-monitor-openwrt/main/install.sh | OUTBOUND_MONITOR_RELEASE=2026-9-23-1 sh
```

Release tags use `YYYY-M-D-N`, for example `2026-9-23-1`.

Installation and updates preserve `/etc/config/outbound-monitor`, history in `/tmp/outbound-monitor` and the existing service enabled/disabled setting. The monitor starts on first installation; an update restarts it if it was running. The installer reloads `rpcd` to register RPC methods. Refresh an already open LuCI page after installation.

### Manual package installation

Download the three packages for your firmware and `SHA256SUMS` from the **same release**, then verify their checksums before installing. Stable asset names are:

| OpenWrt | Release assets |
| --- | --- |
| 25.12 / `apk` | `outbound-monitor.apk`, `luci-app-outbound-monitor.apk`, `luci-i18n-outbound-monitor-ru.apk` |
| 24.10 / `opkg` | `outbound-monitor.ipk`, `luci-app-outbound-monitor.ipk`, `luci-i18n-outbound-monitor-ru.ipk` |

OpenWrt 25.12:

```sh
apk update
apk add --allow-untrusted ./outbound-monitor.apk ./luci-app-outbound-monitor.apk ./luci-i18n-outbound-monitor-ru.apk
```

The APK files are published by this project outside the official OpenWrt feed, which is why this command uses `--allow-untrusted`.

OpenWrt 24.10:

```sh
opkg update
opkg install ./outbound-monitor.ipk ./luci-app-outbound-monitor.ipk ./luci-i18n-outbound-monitor-ru.ipk
```

For development or offline file-based installation, see the [source bundle instructions](./docs/DEVELOPMENT.md#source-bundle).

## LuCI and updates

The page is at **Status → Outbound Monitor** (`/cgi-bin/luci/admin/status/outbound-monitor`). English is the source language; the Russian translation follows LuCI's language selection.

Use **Check updates** to query the latest stable GitHub release, then **Update from GitHub** to install it. Both actions run asynchronously and start only when clicked. The update uses the same package installer as the command above. Opening the page does not start an update check or install packages.

## Resource use and storage

The router uses LuCI, `ucode`, `curl` and `procd`; it needs no database, Node.js, Python, RRD, charting library or additional web server. Between checks, only the collector shell and `sleep` remain running; `ucode` and `curl` run during collection. Probes are sequential, with at most 32 current and 32 archived outbounds.

History is stored in RAM at `/tmp/outbound-monitor/state.json`, for at most seven days. With three outbounds and a 300-second interval, this is about 6,050 outbound samples, plus network/DNS metadata and event records. Both record age and count are bounded. **A router reboot erases history**; export JSON or CSV if needed. Statistics are not written persistently to flash.

## Probe behavior and privacy

The collector reads GET `/proxies` and GET `/proxies/{tag}/delay` from the existing Clash API. It does not change podkop, sing-box, network, firewall, DNS or cron configuration, or send commands to select an outbound.

**The delay endpoint performs an active probe.** sing-box updates its internal latency history, as it does during a manual dashboard test. URLTest uses those measurements when choosing an outbound, and a probe can also shift its own testing schedule. Choose `test_url` with this shared behavior in mind.

Passwords, UUIDs, raw VPN links and the API secret are neither returned to LuCI nor recorded in history. The collector passes the API secret to `curl` through a temporary file with mode `0600` in a directory with mode `0700`. The page uses the existing authenticated LuCI session and opens no new ports. Probe sites receive the VPN or direct control traffic; optional DNS diagnostics contact the tested resolvers. GitHub is contacted when installing, checking for updates or updating.

## Configuration and CLI

`/etc/config/outbound-monitor` contains only this plugin's settings:

| Option | Default | Allowed |
| --- | --- | --- |
| `enabled` | `1` | `0` / `1` |
| `interval` | `300` seconds | 60–86400 |
| `retention_days` | `7` | 1–7 |
| `timeout` | `8` seconds | 1–30 |
| `dns_check` | `1` | `0` / `1`; use installed IPRegion after both direct checks fail |
| `test_url` | `https://www.gstatic.com/generate_204` | HTTPS URL |
| `sing_box_config` | `/etc/sing-box/config.json` | Path to the active sing-box JSON file |

After changing settings, run `/etc/init.d/outbound-monitor restart`.

The API address and secret are read from the sing-box configuration; wildcard addresses `0.0.0.0` and `[::]` are replaced with loopback. If the API is disabled, the monitor reports an error and does not enable it. Only configurations contained in a single JSON file are supported.

When the outbounds on disk or the hashed podkop connection metadata (links and interface mappings) change, the monitor waits for a new sing-box process before assigning measurements to the changed configuration. It also checks for changes during collection and discards affected measurements. On first observation and after a process change, it **assumes that the specified JSON matches the running sing-box configuration**. The API does not expose loaded passwords or UUIDs, so it cannot prove this match. Outbound/metadata fingerprints plus the PID/start time of the unique live `sing-box run` server detect subsequent changes; short-lived check/version/help commands are ignored. The observed link hash never determines which credential history receives a sample. Save and apply changes through podkop as usual; manual JSON edits after a restart but before the next poll can break the association.

```sh
outbound-monitor status 24       # last 24 hours as JSON
outbound-monitor collect         # extra probe; flock prevents overlapping collectors
/etc/init.d/outbound-monitor stop
/etc/init.d/outbound-monitor start
```

With many outbounds, the sum of probe timeouts may exceed the interval. Cycles do not overlap; the next starts after the previous one finishes. Missing samples appear as gaps. Moving the clock backwards removes future-dated points from the current window.

## Uninstall

For a package installation, use the router's package manager:

```sh
# OpenWrt 25.12
apk del luci-i18n-outbound-monitor-ru luci-app-outbound-monitor outbound-monitor

# OpenWrt 24.10
opkg remove luci-i18n-outbound-monitor-ru luci-app-outbound-monitor outbound-monitor
```

For a source archive installation, see [development notes](./docs/DEVELOPMENT.md#remove-a-source-installation). Remove saved configuration or history separately only if you no longer need it.

## Development

See [development and release notes](./docs/DEVELOPMENT.md), [CI](https://github.com/romanilyin/outbound-monitor-openwrt/actions) and the [MIT license](./LICENSE).

The collector uses the [sing-box Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/) and its [individual delay endpoint](https://github.com/SagerNet/sing-box/blob/v1.12.0/experimental/clashapi/proxies.go).
