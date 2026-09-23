// Synthetic proc files only. Does not inspect or modify live sing-box processes.
import * as fs from 'fs';
import { process_generation } from '../outbound-monitor/files/usr/share/outbound-monitor/runtime.uc';
let base = ARGV[0] || '/tmp/outbound-monitor-check/runtime';
fs.mkdir(base, 0700);
let st = fs.lstat(base);
let own_uid = fs.stat('/proc/self')?.uid;
if (st?.type != 'directory' || own_uid == null || st.uid != own_uid || (st.mode & 0777) != 0700) die('Unsafe runtime test directory\n');
let work = fs.mkdtemp(base + '/case-XXXXXX');
if (!work) die('Cannot create runtime test directory\n');
let root = work + '/proc';
fs.mkdir(root, 0700);
let count = 0;
function check(ok, message) { if (!ok) die('FAIL runtime: ' + message + '\n'); count++; }
function stat(pid, start, state) {
	let fields = [state || 'S'];
	for (let i = 1; i < 19; i++) push(fields, '' + i);
	push(fields, '' + start);
	return pid + ' (sing-box) ' + join(' ', fields) + ' 4096 100\n';
}
function process(pid, args, start, state) {
	let dir = root + '/' + pid;
	fs.mkdir(dir, 0700);
	fs.writefile(dir + '/comm', 'sing-box\n');
	fs.writefile(dir + '/stat', stat(pid, start, state));
	fs.writefile(dir + '/cmdline', join(chr(0), ['/usr/bin/sing-box', ...args]) + chr(0));
}
function remove(pid) {
	let dir = root + '/' + pid;
	for (let file in ['comm', 'stat', 'cmdline']) fs.unlink(dir + '/' + file);
	fs.rmdir(dir);
}
function clear() {
	for (let dir in fs.glob(root + '/*')) {
		for (let file in ['comm', 'stat', 'cmdline']) fs.unlink(dir + '/' + file);
		fs.rmdir(dir);
	}
}
try {
	check(process_generation(root) == null, 'absent daemon');
	process('101', ['run', '-c', '/etc/sing-box/config.json'], 321);
	check(process_generation(root) == '/proc/101/comm:321', 'normal run preserves historical identity');
	process('101', ['--directory', '/tmp', '--disable-color', '-c', 'run', '--config-directory=/etc/sing-box', 'run'], 321);
	check(process_generation(root) == '/proc/101/comm:321', 'globals before run and value named run');
	process('101', ['-C/etc/sing-box', '-D/tmp', '-cconfig.json', 'run', '--disable-color=false'], 321);
	check(process_generation(root) == '/proc/101/comm:321', 'attached short globals and globals after action');
	process('1', ['-c', 'run', 'check'], 901);
	process('900', ['--disable-color', 'version'], 902);
	process('201', ['run', '--help'], 903);
	check(process_generation(root) == '/proc/101/comm:321', 'helper overlap ignored');
	clear();
	process('900', ['version'], 902);
	process('1', ['check'], 901);
	process('101', ['run'], 321);
	check(process_generation(root) == '/proc/101/comm:321', 'reverse fixture creation and helper PID order preserve identity');
	process('202', ['run'], 445); fs.unlink(root + '/202/cmdline');
	check(process_generation(root) == null, 'existing unreadable second process remains ambiguous');
	remove('202');
	check(process_generation(root) == '/proc/101/comm:321', 'missing process directory does not affect stable server');
	process('102', ['run'], 444);
	check(process_generation(root) == null, 'multiple live run processes ambiguous');
	process('102', ['run'], 444, 'Z'); fs.writefile(root + '/102/cmdline', '');
	check(process_generation(root) == '/proc/101/comm:321', 'empty cmdline zombie is not a server');
	process('102', ['run'], 444, 'X');
	check(process_generation(root) == '/proc/101/comm:321', 'exited process is not a server');
	remove('102');
	fs.writefile(root + '/101/stat', '101 (sing-box) S 1 2\n');
	check(process_generation(root) == null, 'truncated stat identity refused');
	fs.writefile(root + '/101/stat', stat('101', 'bad-start'));
	check(process_generation(root) == null, 'malformed start time refused');
	fs.writefile(root + '/101/stat', stat('999', 321));
	check(process_generation(root) == null, 'stat PID mismatch refused');
	fs.unlink(root + '/101/stat'); fs.mkdir(root + '/101/stat', 0700);
	check(process_generation(root) == null, 'unreadable non-file stat refused');
	fs.rmdir(root + '/101/stat');
	process('101', ['run'], 321);
	fs.unlink(root + '/101/cmdline');
	check(process_generation(root) == null, 'unreadable cmdline refused');
	fs.writefile(root + '/101/cmdline', '/usr/bin/sing-box' + chr(0) + 'run');
	check(process_generation(root) == null, 'truncated cmdline refused');
	process('101', ['--unknown-global', 'run'], 321);
	check(process_generation(root) == null, 'unknown option arity fails closed');
	process('101', ['--config'], 321);
	check(process_generation(root) == null, 'missing global value refused');
	process('101', ['run'], 999);
	check(process_generation(root) == '/proc/101/comm:999', 'PID reuse changes start-time identity');
	process('333', ['run'], 444); fs.writefile(root + '/333/comm', 'other-program\n');
	check(process_generation(root) == '/proc/101/comm:999', 'unrelated process ignored');
	clear();
	process('1', ['check'], 901); process('900', ['version'], 902);
	check(process_generation(root) == null, 'helpers alone do not establish a runtime');
} catch (e) {
	// Remove the deliberately unreadable fixture if an assertion failed there.
	fs.rmdir(root + '/101/stat');
	clear(); fs.rmdir(root); fs.rmdir(work);
	die(e);
}
clear(); fs.rmdir(root); fs.rmdir(work);
printf('PASS %d runtime assertions\n', count);
