import json, pathlib, subprocess, sys, time, os
import http.server, threading

# Real local HTTP streaming fixture: exercises the app backend without paid APIs,
# user credentials, user chat data or a probabilistic model response.
class SettingsStreamFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            for index in range(60):
                part = 'STREAM_COMPLETED' if index == 59 else 'stream '
                data = {'choices':[{'delta':{'content':part}}]}
                self.wfile.write(('data: ' + json.dumps(data) + '\n\n').encode())
                self.wfile.flush()
                time.sleep(.2)
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), SettingsStreamFixture)
threading.Thread(target=fixture.serve_forever, daemon=True).start()
fixture_base = 'http://127.0.0.1:' + str(fixture.server_address[1])
app = pathlib.Path(sys.argv[1]).resolve()
report = pathlib.Path(sys.argv[2]).resolve()
command = [str(app / 'Contents/MacOS/PersonalAssistant'), '-ApplePersistenceIgnoreState', 'YES', '--smoke-test', str(report)]
if '--launchservices' in sys.argv:
    command = ['/usr/bin/open', '-n', '-F', '-W', '-a', str(app), '--args', '-ApplePersistenceIgnoreState', 'YES', '--smoke-test', str(report), '--skip-capture','--skip-keychain']
command += ['--settings-busy-smoke-base', fixture_base]
if '--skip-keychain' in sys.argv: command += ['--skip-keychain']
proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    stdout, stderr = proc.communicate(timeout=120)
except subprocess.TimeoutExpired:
    proc.terminate()
    stdout, stderr = proc.communicate(timeout=10)
    raise AssertionError('Native smoke timed out: ' + stderr.decode(errors='replace')[-3000:])
fixture.shutdown()
fixture.server_close()
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
