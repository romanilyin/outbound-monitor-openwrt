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

Release `2026-9-23-1` was installed from GitHub using the LuCI update buttons.
The three APK packages totalled 31,677 bytes; all 14 published assets matched
their published checksums. The installer added only the three monitor packages
and their `flock` dependency. All existing packages, protected configuration,
the sing-box process and monitor enabled/running state were unchanged. Every
pre-install sample survived migration; the new collector then measured both
direct controls successfully. The Russian translation was verified in LuCI.
This check exposed a cached stylesheet in a previously open tab; revision 2
adds a release-specific stylesheet URL and a regression check.

The subsequent button update to `2026-9-23-2` also succeeded. The installed
version and latest GitHub release agree; the three APK files total 31,708 bytes.
All 14 release assets passed checksum verification with their published names.
Only the three monitor packages changed during this update. All chart IDs,
pre-update samples, protected configuration and the sing-box process were
preserved; each of the three keys had 25 samples after the first new collection.
The page's own reload button refreshed the original browser tab, which loaded
`style.css?v=2026-9-23-2`, displayed the blue legend and all three charts, and
reported no JavaScript errors. The final UI/i18n suite passed 25 tests; both
SDK package builds and the release workflow passed on GitHub Actions.

Revision `2026-9-23-3` adds standalone proxy keys, selector-only groups and
podkop VPN interface sections. Its candidate passed 62 core, 9 podkop-mapping,
22 process-identity, 22 updater, 34 network and 22 isolated DNS assertions,
all collector/installer integration scenarios and 26 UI/i18n tests. A focused
independent review found no substantive issues. Synthetic process fixtures
cover concurrent check/version/help commands, malformed records, ambiguity,
vanished records and PID reuse; integrations distinguish actual process,
configuration and podkop-mapping races.

A real collection used a separate copy of production history and discovered
the existing three proxy keys plus the `warp-out` section bound to `awg0`.
WARP answered the HTTP probe successfully (732 ms in that sample), both direct
controls succeeded, every old ID/sample remained present, and the sing-box
generation was unchanged. The source archive includes the new mapping and
process modules. The separately reported router with one standalone key was
unavailable for direct verification; that topology was tested in isolation,
so its screenshot's specific runtime-error cause remains unconfirmed.

The published revision 3 passed both SDK builds and verification of all 14
release checksums; its three APK files total 33,521 bytes. The LuCI button
successfully upgraded the router from revision 2. Only the monitor's three
packages changed; protected configuration, the sing-box process, monitor
settings/service state and all previous chart IDs/samples remained unchanged.
The installed collector reported four active connections with no error: the
three existing keys had 61 samples each and WARP had its first successful
sample. After the page's reload button, LuCI showed four charts and
`direct · Интерфейс: awg0` on the WARP card/comparison row. No JavaScript errors
were logged after the update; an older expired-session error preceded login.

Automated coverage includes key discovery, credential-safe identities, key
reordering/replacement, migration, API errors, bounded history, chart statistics,
translations and updater behavior. Run the current suites using the commands in
[development notes](./DEVELOPMENT.md); GitHub Actions records release build results.

A real seven-day soak and router reboot are intentionally outside this check.
RAM retention is tested with synthetic timestamps. Active delay probes update
sing-box URLTest latency history; see the README for effects and identity limits.
