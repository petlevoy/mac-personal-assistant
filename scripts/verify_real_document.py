"""Actual bundled local inference on >60k text; no model/user file deletion."""
import json,pathlib,sys,tempfile,time,threading
app=pathlib.Path(sys.argv[1]).resolve();sys.path.insert(0,str(app/'Contents/Resources/backend'))
from core import Store
root=pathlib.Path(sys.argv[2]).resolve();root.mkdir(parents=True,exist_ok=True)
s=Store(root/'real-document-data');checks=[]
try:
 did=s.local.start_download('Qwen/Qwen3-0.6B-GGUF','Qwen3-0.6B-Q8_0.gguf')
 deadline=time.monotonic()+600
 while s.local.downloads[did]['status'] in ('downloading','verifying') and time.monotonic()<deadline:time.sleep(1)
 d=s.local.downloads[did];assert d['status']=='complete',d;checks.append('HF GGUF download integrity verified')
 s.update_settings({'provider':'local','model':d['path'],'contextLimit':8192,'temperature':0,'toolsEnabled':False})
 pid=s.data['projects'][0]['id'];cid=s.create_chat(pid)
 text='List each Record identifier value mentioned in this file.\n[Файл: large.txt]\nRecord identifier: MARK-111\n'+'Routine maintenance record. Status: normal.\n'*900+'Record identifier: MARK-222\n'+'Routine maintenance record. Status: normal.\n'*900+'Record identifier: MARK-333\n[Конец файла]'
 assert len(text)>60000
 jid=s.start(pid,cid,text);deadline=time.monotonic()+900
 while s.jobs[jid]['status']=='running' and time.monotonic()<deadline:time.sleep(.5)
 j=s.jobs[jid];assert j['status']=='done',{k:v for k,v in j.items() if k!='stop'}
 folder=s.root/'projects'/pid/'files'/('analysis-'+jid[:8]);coverage=json.loads((folder/'coverage.json').read_text())
 assert coverage['complete'] and coverage['processedCharacters']==len(text)
 assert (folder/'original.txt').read_text()==text
 checks.append('actual local model processed every character of >60k source')
 answer=s.chat(pid,cid)['messages'][-1]['content']
 assert all(x in answer for x in ['MARK-111','MARK-222','MARK-333']),answer
 checks.append('beginning/middle/end markers all present in actual local final response')
 result={'status':'passed','checks':checks,'characters':len(text),'parts':coverage['parts'],'answer':answer,'model':d['path'],'bytes':d['bytes']}
 (root/'real-document.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2))
finally:s.stop();s.local.close()
