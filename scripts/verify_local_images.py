"""Native mouse → real bundled image engine → offline PNG preview/save + cancellation."""
import json, os, pathlib, subprocess, sys, time
app=pathlib.Path(sys.argv[1]).resolve(); model=pathlib.Path(sys.argv[2]).resolve(); report=pathlib.Path(sys.argv[3]).resolve()
command=[str(app/'Contents/MacOS/PersonalAssistant'),'-ApplePersistenceIgnoreState','YES','--smoke-test',str(report),'--skip-keychain','--local-image-smoke-model',str(model)]
proc=subprocess.run(command,capture_output=True,timeout=240)
assert proc.returncode==0,proc.stderr.decode(errors='replace')[-3000:]
result=json.loads(report.read_text()); print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['status']=='passed',result
output=pathlib.Path(result['local_image_saved'])
assert output.is_file() and output.stat().st_size>1000
assert output.read_bytes()[:8]==b'\x89PNG\r\n\x1a\n'
for _ in range(50):
    try: os.kill(result['backend_pid'],0)
    except ProcessLookupError: break
    time.sleep(.1)
else: raise AssertionError('Backend survived quit')
commands=subprocess.check_output(['/bin/ps','-axo','command']).decode()
assert str(app/'Contents/Resources/stable-diffusion/sd-cli') not in commands, 'Image engine survived quit'
print('PASS: real offline local image, native mouse control, decode/save, cancellation and quit')
