#!/bin/sh
for tool in ucode curl wget uclient-fetch jsonfilter timeout sha256sum flock; do command -v "$tool" || true; done
apk info | grep -E '^(podkop|sing-box|ucode|rpcd|luci-base|curl)' || true
ucode -e '
import * as fs from "fs";
let c = json(fs.readfile("/etc/sing-box/config.json"));
let a = c.experimental?.clash_api;
printf("%J\n", {controller: a?.external_controller, has_secret: !!a?.secret,
 outbounds: map(c.outbounds, (o) => ({tag:o.tag,type:o.type,outbounds:o.outbounds,url:o.url,interval:o.interval}))});
'
sha256sum /etc/config/podkop /etc/config/sing-box /etc/sing-box/config.json /etc/config/network /etc/config/firewall /etc/config/dhcp
pidof sing-box
ls /usr/lib/ucode
ls /usr/share/rpcd/ucode
sed -n '1,120p' /etc/init.d/rpcd
command -v wget >/dev/null && wget -qO- http://127.0.0.1:9090/proxies
