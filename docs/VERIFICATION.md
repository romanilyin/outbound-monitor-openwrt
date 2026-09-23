# Router verification — 2026-09-23

Tested on OpenWrt 25.12.4, Cudy WR3000P v1 (mediatek/filogic),
with sing-box-extended 1.12.17. OpenWrt 24.10 is an SDK build target;
no 24.10 hardware runtime claim is made.

The initial source installation was checked in authenticated LuCI, including
three outbound charts, period selection, red failures at −10, dark theme and
a 522 px viewport. The procd service remained running and enabled; two real
automatic samples were 301 seconds apart. The idle collector shell used
approximately 1.2 MB RSS, excluding shared pages and temporary probe processes.

The existing sing-box process and hashes of podkop, sing-box, network, firewall
and DHCP configuration were unchanged. No VPN or network service was restarted.
Only the monitor service and RPC registration are involved in installation.
Private router endpoints, keys and configuration hashes are omitted here.

The release candidate passed 49 core, 22 updater, 34 network and 22 isolated DNS
assertions on the router, plus mocked collection/update integration and 24 UI/i18n
tests. A real collection using a separate copy of history preserved all old
samples, measured both direct controls successfully and identified one failing
VPN among three. The installed IPRegion v2 result was parsed as six compact
resolver rows. An isolated installer test rejected a corrupt package before
any package/service operation and preserved configuration/history across all
four combinations of service enabled/running state.

Automated coverage includes key discovery, credential-safe identities, key
reordering/replacement, migration, API errors, bounded history, chart statistics,
translations and updater behavior. Run the current suites using the commands in
[development notes](./DEVELOPMENT.md); GitHub Actions records release build results.

A real seven-day soak and router reboot are intentionally outside this check.
RAM retention is tested with synthetic timestamps. Active delay probes update
sing-box URLTest latency history; see the README for effects and identity limits.
