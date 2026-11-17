import pathlib,plistlib,subprocess,sys,os,json,tempfile,urllib.request
app=pathlib.Path(sys.argv[1]).resolve(); res=app/'Contents/Resources'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundlePackageType']=='APPL' and not info.get('LSUIElement',False)
assert (res/'AppIcon.icns').stat().st_size>0
assert (app/'Contents/MacOS'/info['CFBundleExecutable']).stat().st_size>0
python=res/'python/bin/python3'
assert python.exists()
with tempfile.TemporaryDirectory() as d:
 p=subprocess.Popen([str(python),'-I','-B',str(res/'backend/server.py'),'--data',d],env={'MAC_ASSISTANT_TOKEN':'bundle-smoke-test-token-1234567890','PATH':'/usr/bin:/bin'},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  import select
  assert select.select([p.stdout],[],[],15)[0], 'service startup timeout'
  port=json.loads(p.stdout.readline())['port']
  r=urllib.request.Request(f'http://127.0.0.1:{port}/state',headers={'X-App-Token':'bundle-smoke-test-token-1234567890'})
  with urllib.request.urlopen(r,timeout=5) as resp: state=json.load(resp)
  assert state['projects']
 finally:
  p.terminate(); p.wait(timeout=10)
print('Bundle structure, bundled Python, authenticated backend startup: PASS')
