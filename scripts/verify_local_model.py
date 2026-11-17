"""Release gate: real GGUF download, integrity, bundled engine and tool roundtrip."""
import json,pathlib,sys,tempfile,time,threading,urllib.request
app=pathlib.Path(sys.argv[1]);sys.path.insert(0,str(app/'Contents/Resources/backend'))
from core import Store,request_json
checks=[]
with tempfile.TemporaryDirectory() as folder:
 s=Store(folder)
 try:
  found=s.local.search('Qwen3-0.6B-GGUF');assert any(v['id']=='Qwen/Qwen3-0.6B-GGUF' for v in found);checks.append('live HF Explore search')
  did=s.local.start_download('Qwen/Qwen3-0.6B-GGUF','Qwen3-0.6B-Q8_0.gguf')
  deadline=time.monotonic()+600
  while s.local.downloads[did]['status'] in ('downloading','verifying') and time.monotonic()<deadline:time.sleep(1)
  d=s.local.downloads[did];assert d['status']=='complete',d;checks.append('GGUF downloaded and SHA256 verified')
  assert s.local.library();checks.append('download indexed in library')
  model=d['path'];s.update_settings({'provider':'local','model':model,'toolsEnabled':False,'contextLimit':4096,'temperature':0})
  base,key=s.local.endpoint(model,4096,threading.Event());checks.append('bundled llama-server loads real GGUF')
  pid=s.data['projects'][0]['id'];cid=s.data['projects'][0]['chats'][0]['id']
  profile=s.data['profiles'][0];s.profile_save({'id':profile['id'],'name':profile['name'],'prompt':'Answer briefly. /no_think'})
  jid=s.start(pid,cid,'Say hello in one short sentence. /no_think')
  deadline=time.monotonic()+180
  while s.jobs[jid]['status']=='running' and time.monotonic()<deadline:time.sleep(.2)
  assert s.jobs[jid]['status']=='done',s.jobs[jid]
  assert s.chat(pid,cid)['messages'][-1]['content'].strip();checks.append('real streaming chat through Store')
  # Required tool choice removes probabilistic selection, tests runtime protocol + actual tool execution.
  tool={'type':'function','function':{'name':'list_files','description':'List project files','parameters':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}}}
  body={'model':'local-model','messages':[{'role':'user','content':'List files in the current directory.'}], 'tools':[tool],
        'tool_choice':{'type':'function','function':{'name':'list_files'}},'temperature':0,'max_tokens':256,'chat_template_kwargs':{'enable_thinking':False}}
  with request_json(base+'/chat/completions',body,key,timeout=120) as r:res=json.load(r)
  call=res['choices'][0]['message']['tool_calls'][0];assert call['function']['name']=='list_files',res
  result=s.execute({'id':'smoke','projectID':pid,'stop':threading.Event()},'list_files',json.loads(call['function']['arguments']),s.data['settings'])
  assert result is not None;checks.append('real GGUF emits tool call and project list_files executes')
  s.save();again=Store(folder);assert again.data['profiles'][0]['prompt']=='Answer briefly. /no_think';again.local.close();checks.append('system prompt survives Store restart')
  print(json.dumps({'status':'passed','checks':checks,'model':d['file'],'bytes':d['bytes'],'chat':s.chat(pid,cid)['messages'][-1]['content']},ensure_ascii=False,indent=2),flush=True)
 finally:s.stop();s.local.close()
