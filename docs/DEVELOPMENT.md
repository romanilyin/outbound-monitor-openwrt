# Development and packaging

[English README](../README.md) · [Русский README](./README.ru.md) · [Разработка на русском](./DEVELOPMENT.ru.md)

## Repository layout

| Path | Purpose |
| --- | --- |
| `outbound-monitor/` | Collector, CLI, UCI configuration and procd service |
| `luci-app-outbound-monitor/` | LuCI JavaScript/CSS, rpcd methods and ACL, menu, gettext catalogs |
| `install.sh` | Public GitHub Release package installer |
| `scripts/install-local.sh` | File installer included in the source bundle as `install.sh` |
| `scripts/make-bundle.py` | Reproducible source-install archive |
| `scripts/build-sdk-packages.sh` | APK/IPK build using the matching OpenWrt SDK |
| `scripts/ci/` | Static checks and host `ucode` build helper |
| `tests/` | UI, core and isolated collection tests |
| `VERSION` | Public release tag, in `YYYY-M-D-N` format |

The three release packages are `outbound-monitor`, `luci-app-outbound-monitor` and `luci-i18n-outbound-monitor-ru`. They are script-only and architecture-independent; native dependencies belong in package metadata and come from the matching OpenWrt feeds.

Runtime evidence exists for OpenWrt 25.12.4; see [the original verification report](./VERIFICATION.md). The release SDK matrix covers 25.12.4 and 24.10.6. A successful SDK build is not hardware runtime verification for 24.10.

## Checks

Run from the repository root with Python 3, Node.js and a compatible `ucode` installation:

```sh
python3 scripts/ci/static-checks.py
node --test --test-isolation=none tests/ui.test.cjs tests/i18n.test.cjs
ucode tests/core.uc
ucode tests/podkop.uc
ucode tests/runtime.uc /tmp/outbound-monitor-runtime
ucode tests/network.uc
ucode tests/update.uc
```

CI uses `scripts/ci/build-ucode.sh` to prepare a host `ucode` build when needed. Runtime code requires the `fs`, `uci` and `digest` modules. Shell and JSON checks, LuCI syntax, translations and release metadata belong in the static checks; behavior belongs in the focused UI/core/integration tests.

For isolated collection and syntax tests on a router:

```sh
python3 scripts/check-router.py --env /path/to/external.env
```

The helper requires Python `paramiko` on the development computer. The external environment file must contain `ROUTER_IP` and `ROUTER_PASSWORD`; `ROUTER_USER` and `ROUTER_PORT` are optional. Keep it out of the repository and release artifacts. SSH host keys are stored locally in `.local/known_hosts`.

`check-router.py` uploads test sources to `/tmp/outbound-monitor-check`, compiles `ucode`, checks shell syntax and runs isolated collection scenarios with stubbed requests, process identity and podkop link mapping. It does not install the plugin or restart services. Cover successful and failed probes, API errors, stable link identity, reorder/replacement, configuration changes before apply and during collection, credential redaction, direct-probe classification and bounded DNS results.

For real router verification, also check the LuCI page in English and Russian, comparison metrics, both failure colors, DNS result timestamps, period selection, exports, dark theme, narrow screens, scheduled collection and update controls. Record whether tests used source files or packages, the OpenWrt version and the exact revision. Keep private router addresses, credentials and VPN endpoints out of screenshots and public reports.

## SDK builds

On a Linux host with the OpenWrt SDK prerequisites installed:

```sh
scripts/build-sdk-packages.sh 25.12.4
scripts/build-sdk-packages.sh 24.10.6
```

The helper uses the corresponding x86/64 SDK. The resulting project packages are architecture-independent; native `ucode`, `curl` and other dependencies are not bundled from the SDK target. OpenWrt 25.12.4 produces APK files; 24.10.6 produces IPK files.

To compile in an existing matching SDK with the LuCI feed available, run from this repository's root:

```sh
ln -s "$PWD" "$SDK/package/outbound-monitor-openwrt"
cd "$SDK"
make defconfig
make package/outbound-monitor/compile package/luci-app-outbound-monitor/compile V=s
```

Keep the whole repository layout: the backend Makefile references `../VERSION` and `../install.sh`. Copying only the two package directories loses those inputs. Ensure the Russian LuCI translation is selected when producing release packages. The release helper and CI own the complete three-package build.

## Identity and measurement invariants

`core.uc` always identifies a chart by SHA-256 of the complete canonical credential-bearing outbound configuration excluding its top-level tag. `podkop.uc` maps `proxy_string` to `section-out`, URLTest/selector link positions to `section-N-out`, and VPN interface sections to allowed tag/interface pairs. `link_hash` is computed from the trimmed observed link before its `#fragment`. This hash is metadata only: never use it to find or assign credential history, and never persist the original link. URI-only changes that do not alter the generated outbound do not split a chart. Duplicate connection identities merge their tags/groups and use one current API alias.

Rebinding must update the current tag, label, type, server, interface and groups without replacing samples. Legacy migration compares the full old credential-bearing hash with the current configuration using the old tag; never merge by server alone or guess among ambiguous matches. Preserve the existing runtime outbounds fingerprint when upgrading. Discovery version 2 adopts the expanded podkop metadata fingerprint once; subsequent changes on the same sing-box process remain rejected until restart. Check both fingerprints again after probing. The chart identity scheme does not change after a restart; JSON/runtime correspondence retains the documented assumption, while an unapplied UCI link cannot redirect history through its hash.

`runtime.uc` identifies the unique live `sing-box run` process using PID/start time; short-lived check/version/help commands do not count as additional servers. Its tests use synthetic proc directories. Collector errors distinguish server identity, JSON configuration and podkop metadata changes; they do not claim that every configuration race is a daemon restart.

Samples are `[timestamp, status, delay]`:

| Status | Meaning | Chart/statistics |
| --- | --- | --- |
| `1` | Successful VPN probe | Delay in ms; included in latency metrics |
| `0` | Failed VPN probe | Red at −10; included in VPN failure rate |
| `−1` | Unknown/control error | Gap; excluded from metrics |
| `−2` | Suspected common network failure | Blue at −10; excluded from metrics and VPN failure streaks |

VPN failure percentage divides `0` samples by `0 + 1` samples. Mean, population variance (divide by `n`) and standard deviation use successful delays only. Unknown, missing and `−2` results are excluded; one success gives zero variance. Keep the selected time range, counts and freshness visible when comparing keys.

## Direct controls and optional DNS

The collector uses a suitable existing `direct` outbound for two HTTPS controls: gstatic and Cloudflare's `generate_204` endpoints; `network.uc` classifies the results. Reject VPN detours and inherited `route.default_interface`/`route.default_mark` controls. Mark a common failure only when both controls and all VPN probes fail. If any VPN succeeds while both controls fail, report a mixed result. The DNS resolver or even the system default route may still use a VPN: these are existing-direct-outbound checks, not proof of physical ISP reachability.

With `dns_check=1` and IPRegion already installed, both failed controls trigger optional DNS diagnosis, even for mixed results. Run IPRegion with `--no-uci`, timeout `2`, retries `0`, an isolated `IPREGION_RUNTIME_DIR` and a 25-second overall cap. Use the installed version's available resolvers/transports, including UDP/TCP and DoT/DoH where supported. Accept DNS result schemas v1 and v2 and retain compact transport statuses rather than assuming a fixed resolver count. Do not add a package dependency, install IPRegion or change its settings. Its route is the router's route and may include a VPN; failed resolver comparisons do not prove tampering or identify a responsible provider.

Store the latest compact DNS result and at most 128 newest detailed `network_events`, also bounded by `retention_days` (maximum seven days). Preserve the saved DNS result and its timestamp when checks are disabled or IPRegion is removed. Keep raw IPRegion runtime files isolated from its regular session; refuse installed versions without `IPREGION_RUNTIME_DIR` support. JSON exports include the bounded network events; this incident cap must not shorten per-key chart history. Preserve the state-directory ownership/mode checks and avoid persistent statistics writes.

## LuCI, RPC and update boundaries

- Keep English source strings inside `_('...')`; the Russian gettext catalog produces `luci-i18n-outbound-monitor-ru`. Do not translate API field names or outbound identifiers.
- The rpcd object is `luci.outbound-monitor`. Its ACL must remain limited to the methods required by the page, without generic shell execution.
- `update_status`, `check_update` and `update` take no caller-supplied repository, URL or shell arguments. Checks and installation start only after an explicit button click; progress can be polled locally.
- `/usr/bin/outbound-monitor-update check` and `install` implement the update operations for the fixed `romanilyin/outbound-monitor-openwrt` repository.
- Update only from stable releases using the release package installer and SHA-256 verification. Do not add an unattended update loop.
- Preserve the monitor's UCI configuration, RAM history and enabled/disabled state across an update. Restart its service only if it was running or this is a first install; use `rpcd reload` for registration.

The collection code must not modify podkop, sing-box, networking, firewall, DNS or cron. Preserve the active URLTest side effect and configuration/process identity assumptions documented in both READMEs. API failures must remain distinct from failed outbound probes. Keep credentials out of history, RPC responses, logs and process arguments.

## Source bundle

This fallback copies files and does not register packages with `apk` or `opkg`. Prefer package installation for managed upgrades and the compiled Russian translation. The source bundle's LuCI UI is English.

Build locally:

```sh
python3 scripts/make-bundle.py
scp -O dist/outbound-monitor-2026-9-23-1.tar.gz root@ROUTER:/tmp/
```

On the router:

```sh
mkdir -p /tmp/outbound-monitor-install
tar -xzf /tmp/outbound-monitor-2026-9-23-1.tar.gz -C /tmp/outbound-monitor-install
sh /tmp/outbound-monitor-install/install.sh
```

The archive name follows `VERSION`. Its `install.sh` comes from `scripts/install-local.sh`, not the repository-root downloader. The local installer does not download dependencies and stops if required programs or modules are missing. Runtime dependencies include `ucode`, `ucode-mod-fs`, `ucode-mod-uci`, `ucode-mod-digest`, `curl`, `ca-bundle`, `flock`, `luci-base` and `rpcd-mod-ucode`. HTTPS delay probes themselves are performed by sing-box; the updater uses the router's HTTPS client and CA certificates.

## Release workflow

Tags use **`YYYY-M-D-N`**, with unpadded month/day and a release sequence number. The first release is `2026-9-23-1`. OpenWrt package metadata represents that release as `PKG_VERSION:=2026.9.23` and `PKG_RELEASE:=1`; keep package metadata and `VERSION` consistent.

Before creating the tag, run the focused checks and review the final installer, updater, package metadata and translated UI. Verify reorder/replacement history, direct/VPN mixed cases, optional DNS absence/disable/timeout and exported event bounds. Test updates against an existing installation: configuration, history and service state must survive; a failed check or checksum verification must not install unverified files. Record any hardware testing gaps explicitly.

Pushing the release tag triggers the GitHub Actions SDK matrix for **25.12.4** and **24.10.6**, followed by release publishing. A complete release contains:

| Format | Stable download names |
| --- | --- |
| APK | `outbound-monitor.apk`, `luci-app-outbound-monitor.apk`, `luci-i18n-outbound-monitor-ru.apk` |
| IPK | `outbound-monitor.ipk`, `luci-app-outbound-monitor.ipk`, `luci-i18n-outbound-monitor-ru.ipk` |
| Source fallback | `outbound-monitor-2026-9-23-1.tar.gz` for the first release |
| Integrity | `SHA256SUMS` for the published artifacts |

After publishing, verify that the release is stable, every required artifact is present, checksums match the downloads and the one-line installer resolves that release. Keep versioned package files if the workflow publishes them alongside the stable aliases. Do not describe an unstarted or failed Actions run as a successful build.

GitHub packages are external to the official OpenWrt feeds. The APK installation uses `--allow-untrusted`, with downloads checked against the release's `SHA256SUMS`; this verifies consistency with the published release, not a separate package-signing trust chain. Official feed submission would require a separate review of the GitHub updater and packaging policy.

## Remove a source installation

Use these commands only for an installation from the source archive; use `apk` or `opkg` for package removal:

```sh
/etc/init.d/outbound-monitor stop
/etc/init.d/outbound-monitor disable
rm -f /etc/init.d/outbound-monitor /usr/bin/outbound-monitor
rm -f /usr/bin/outbound-monitor-update
rm -f /usr/share/outbound-monitor/core.uc /usr/share/outbound-monitor/main.uc
rm -f /usr/share/outbound-monitor/network.uc
rm -f /usr/share/outbound-monitor/update.uc /usr/share/outbound-monitor/update-core.uc
rm -f /usr/share/outbound-monitor/install.sh /usr/share/outbound-monitor/version
rm -f /usr/share/rpcd/ucode/outbound-monitor.uc
rm -f /usr/share/rpcd/acl.d/luci-app-outbound-monitor.json
rm -f /usr/share/luci/menu.d/luci-app-outbound-monitor.json
rm -f /www/luci-static/resources/view/outbound-monitor/status.js
rm -f /www/luci-static/resources/outbound-monitor/style.css
/etc/init.d/rpcd reload
```

This leaves `/etc/config/outbound-monitor` and history intact. Remove them separately only if they are no longer needed.
