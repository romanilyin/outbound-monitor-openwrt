// SPDX-License-Identifier: MIT
'use strict';
import * as fs from 'fs';
import { newer, valid_release } from './update-core.uc';
const DIR = '/tmp/outbound-monitor';
const FILE = DIR + '/update.json';
const VERSION = '/usr/share/outbound-monitor/version';
const INSTALLER = '/usr/share/outbound-monitor/install.sh';
const API = 'https://api.github.com/repos/romanilyin/outbound-monitor-openwrt/releases/latest';

function current() { return trim(fs.readfile(VERSION) || '0.1.0'); }
function read_state() {
	try { let s = json(fs.readfile(FILE)); if (type(s) == 'object') return s; } catch(e) {}
	return { latest: null, checked_at: null, stage: 'idle', error: null };
}
function process_id(pid) {
	let stat = fs.readfile('/proc/' + pid + '/stat');
	if (!stat) return null;
	return split(substr(stat, index(stat, ') ') + 2), ' ')[19];
}
function status() {
	let s = read_state();
	let live = s._pid && s._start && s._start == process_id(s._pid);
	let working = s.stage == 'checking' || s.stage == 'updating';
	return {
		current: current(), latest: s.latest, checked_at: s.checked_at,
		available: newer(s.latest, current()), running: !!(working && live),
		stage: working && !live ? 'failed' : s.stage,
		error: working && !live ? 'Update worker stopped unexpectedly. Check for updates again.' : s.error,
		release_url: s.latest ? 'https://github.com/romanilyin/outbound-monitor-openwrt/releases/tag/' + s.latest : null
	};
}
function write(s) {
	if (fs.writefile(FILE + '.new', sprintf('%J', s)) == null || !fs.rename(FILE + '.new', FILE)) die('Cannot save update status\n');
}
function command(args, capture_stderr) {
	let quoted = map(args, (v) => "'" + replace('' + v, "'", "'\"'\"'") + "'");
	let p = fs.popen(join(' ', quoted) + (capture_stderr ? ' 2>&1' : ' 2>/dev/null'), 'r');
	let data = p ? p.read('all') : '';
	return {code: p ? p.close() : -1, data};
}
function run(action) {
	fs.mkdir(DIR, 0700);
	let dir_stat = fs.lstat(DIR);
	if (dir_stat?.type != 'directory' || dir_stat.uid != 0 || (dir_stat.mode & 0777) != 0700) die('Unsafe state directory\n');
	let s = read_state();
	let target = s.latest;
	let allowed = newer(target, current()) && s.checked_at && time() - s.checked_at <= 86400;
	s.stage = action == 'check' ? 'checking' : 'updating';
	s.error = null;
	s._pid = int(split(fs.readfile('/proc/self/stat'), ' ')[0]);
	s._start = process_id(s._pid);
	write(s);
	try {
		if (action == 'check') {
			let r = command(['curl', '--fail', '--silent', '--location', '--proto', '=https', '--proto-redir', '=https',
				'--connect-timeout', '8', '--max-time', '30', '--max-filesize', '1048576', API]);
			if (r.code != 0) die('Cannot check GitHub releases. Check internet access or try later.');
			let release; try { release = json(r.data); } catch(e) { die('Invalid GitHub release response.'); }
			let format = fs.access('/sbin/apk', 'x') || fs.access('/usr/bin/apk', 'x') ? 'apk' : 'ipk';
			if (!valid_release(release, format)) die('No complete stable release is available for this package manager.');
			s.latest = release.tag_name;
			s.checked_at = time();
			s.stage = 'idle';
		} else {
			if (!allowed) die('Check for a newer release before updating.');
			let r = command(['env', 'OUTBOUND_MONITOR_RELEASE=' + target, 'sh', INSTALLER], true);
			fs.writefile(DIR + '/update.log', substr(r.data, -32768));
			if (r.code != 0 || current() != target) die('Package installation failed. See /tmp/outbound-monitor/update.log.');
			s.stage = 'done';
		}
	} catch(e) {
		s.stage = 'failed';
		s.error = '' + (e.message || e);
	}
	write(s);
}
if (ARGV[0] == 'status') printf('%J\n', status());
else if (ARGV[0] == 'check' || ARGV[0] == 'install') run(ARGV[0]);
else die('Unknown update command\n');
