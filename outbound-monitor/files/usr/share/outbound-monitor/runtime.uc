// SPDX-License-Identifier: MIT
'use strict';
import * as fs from 'fs';

function read(path) {
	try { return fs.readfile(path); } catch (e) { return null; }
}

// Only identify the command action. Never return or persist command arguments.
// Known value-taking globals must consume their next argument: a config file
// named "run" must not turn a transient `check` invocation into a server.
function action(cmdline) {
	if (type(cmdline) != 'string' || !length(cmdline) || substr(cmdline, -1) != chr(0)) return null;
	let args = split(cmdline, chr(0));
	pop(args);
	if (!length(args[0])) return null;
	let selected = null, positional = false;
	for (let i = 1; i < length(args); i++) {
		let arg = args[i];
		if (!positional && arg == '--') { positional = true; continue; }
		if (!positional && (arg == '--help' || arg == '-h' || arg == '--help=true' ||
			arg == '--version' || arg == '-v')) return 'helper';
		if (!positional && (arg == '--disable-color' || arg == '--disable-color=true' ||
			arg == '--disable-color=false' || arg == '--help=false')) continue;
		if (!positional && index(['-c', '-C', '-D', '--config', '--config-directory', '--directory', '--log-level'], arg) >= 0) {
			if (++i >= length(args) || !length(args[i])) return null;
			continue;
		}
		if (!positional && (match(arg, /^--(config|config-directory|directory|log-level)=.+$/) ||
			match(arg, /^-[cCD].+$/))) continue;
		// Unknown options are not guessed to be boolean or value-taking flags.
		if (!positional && substr(arg, 0, 1) == '-') return null;
		if (selected != null || !length(arg)) return null;
		if (arg != 'run') return 'helper';
		selected = 'run';
	}
	return selected;
}

function identity(stat, pid) {
	if (type(stat) != 'string') return null;
	let prefix = pid + ' (sing-box) ';
	if (substr(stat, 0, length(prefix)) != prefix) return null;
	let fields = filter(split(trim(substr(stat, length(prefix))), ' '), (s) => length(s));
	if (!length(fields) || !match(fields[0], /^[A-Za-z]$/)) return null;
	if (index(['Z', 'X', 'x'], fields[0]) >= 0) return {exited: true};
	// fields[0] is proc stat field 3 (state); fields[19] is field 22 (starttime).
	if (length(fields) < 20 || !match(fields[19], /^[0-9]+$/)) return null;
	for (let i = 1; i < 19; i++) if (!match(fields[i], /^-?[0-9]+$/)) return null;
	return {exited: false, start: fields[19]};
}

// proc_root injection is solely for isolated fixture tests. Production identity
// retains its historical /proc/PID/comm:<starttime> format across this upgrade.
export function process_generation(proc_root) {
	proc_root = proc_root || '/proc';
	if (type(proc_root) != 'string') return null;
	let found = [], uncertain = false;
	for (let path in fs.glob(proc_root + '/[0-9]*/comm') || []) {
		if (trim(read(path) || '') != 'sing-box') continue;
		let pid = match(path, /\/([0-9]+)\/comm$/)?.[1];
		if (!pid) { uncertain = true; continue; }
		let prefix = substr(path, 0, length(path) - 4);
		let command = action(read(prefix + 'cmdline'));
		if (command == 'helper') continue;
		let process = identity(read(prefix + 'stat'), pid);
		if (process?.exited) continue;
		if (command != 'run' || !process) {
			// A helper can disappear between the comm and identity reads. Keep
			// existing unreadable records ambiguous, but ignore a vanished PID.
			if (!fs.stat(prefix)) continue;
			uncertain = true;
			continue;
		}
		push(found, '/proc/' + pid + '/comm:' + process.start);
	}
	return !uncertain && length(found) == 1 ? found[0] : null;
};
