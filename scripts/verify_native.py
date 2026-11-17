import json, pathlib, subprocess, sys, time, os
app = pathlib.Path(sys.argv[1]).resolve()
report = pathlib.Path(sys.argv[2]).resolve()
command = [str(app / 'Contents/MacOS/PersonalAssistant'), '-ApplePersistenceIgnoreState', 'YES', '--smoke-test', str(report)]
if '--launchservices' in sys.argv:
    command = ['/usr/bin/open', '-n', '-F', '-W', '-a', str(app), '--args', '-ApplePersistenceIgnoreState', 'YES', '--smoke-test', str(report), '--skip-capture','--skip-keychain']
proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    stdout, stderr = proc.communicate(timeout=90)
except subprocess.TimeoutExpired:
    proc.terminate()
    stdout, stderr = proc.communicate(timeout=10)
    raise AssertionError('Native smoke timed out: ' + stderr.decode(errors='replace')[-3000:])
assert proc.returncode == 0, 'Launch failed: ' + stderr.decode(errors='replace')[-3000:]
assert report.exists(), 'Native report missing: ' + stderr.decode(errors='replace')[-3000:]
result = json.loads(report.read_text())
print(json.dumps(result, indent=2))
assert result['status'] == 'passed', result
pid = result['backend_pid']
for _ in range(30):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(.1)
else:
    raise AssertionError('Backend survived application quit')
print('Native launch, window/reopen, WebKit and quit cleanup: PASS')
if result.get('limitations'): print('LIMITATIONS:', result['limitations'])
