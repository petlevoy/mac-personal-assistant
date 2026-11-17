#!/usr/bin/env python3
import ast, hashlib, json, pathlib, plistlib, subprocess, zipfile
root=pathlib.Path(__file__).resolve().parents[1]
files=[root/'README.md',root/'MAC-ACCEPTANCE.md',root/'build-and-run.command',root/'.gitignore']
for folder in ['backend','macos','tests','examples','scripts']:
    files += [p for p in (root/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc']
for p in files:
    if p.suffix=='.py': ast.parse(p.read_text())
    if p.suffix=='.plist': plistlib.loads(p.read_bytes())
subprocess.run(['bash','-n',str(root/'build-and-run.command')],check=True)
manifest={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
(root/'dist').mkdir(exist_ok=True)
out=root/'dist/Inij-0.3.3-source.zip'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(files): z.write(p,'Inij/'+str(p.relative_to(root)))
    z.writestr('Inij/MANIFEST.json',json.dumps(manifest,ensure_ascii=False,indent=2))
with zipfile.ZipFile(out) as z:
    assert z.testzip() is None
    assert not any('.qa-venv' in n or '__pycache__' in n or '.env' in n for n in z.namelist())
print(json.dumps({'path':str(out),'bytes':out.stat().st_size,'files':len(files)+1,'sha256':hashlib.sha256(out.read_bytes()).hexdigest()},indent=2))
