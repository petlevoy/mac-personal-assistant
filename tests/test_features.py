import json,pathlib,sys,tempfile,threading,unittest,zipfile,copy,io
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store,TOOLS

class FeatureTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.s=Store(self.root/'data')
  self.pid=self.s.data['projects'][0]['id'];self.cid=self.s.project(self.pid)['chats'][0]['id']
 def tearDown(self): self.tmp.cleanup()
 def job(self): return {'id':'test','projectID':self.pid,'chatID':self.cid,'stop':threading.Event()}
 def test_image_draft_can_enable_save_reopen_and_disable(self):
  from image_generation import generate
  self.s.update_settings({'imageEnabled':True,'imageBaseURL':'','imageModel':''})
  reopened=Store(self.s.root)
  self.assertTrue(reopened.data['settings']['imageEnabled'])
  self.assertEqual(reopened.data['settings']['imageBaseURL'],'')
  with self.assertRaises(ValueError):
   generate(reopened,self.job(),{'prompt':'test'},{**reopened.data['settings'],'mode':'internet'})
  reopened.update_settings({'imageEnabled':False})
  self.assertFalse(Store(self.s.root).data['settings']['imageEnabled'])
 def test_profile_version_restore_and_persist(self):
  p=copy.deepcopy(self.s.data['profiles'][0]);self.s.profile_save({'id':p['id'],'name':'New','prompt':'Changed'})
  version=self.s.data['profiles'][0]['versions'][0]['id'];self.s.profile_restore(p['id'],version)
  actual=Store(self.s.root).data['profiles'][0]
  self.assertEqual(actual['prompt'],p['prompt']);self.assertEqual(len(actual['versions']),2)
 def test_backup_roundtrip_rebases_and_disables_mcp(self):
  skill=self.root/'skill';skill.mkdir();(skill/'SKILL.md').write_text('reference')
  self.s.import_skill(self.pid,skill); self.s.mcp_save({'name':'test','command':'/bin/echo','args':[]})
  self.s.project(self.pid)['memory']='saved';self.s.save();(self.s.root/'service.log').write_text('not exportable')
  backup=self.root/'backup.zip';self.s.export(backup)
  with zipfile.ZipFile(backup) as z:self.assertNotIn('service.log',z.namelist())
  other=Store(self.root/'other');r=other.restore_backup(backup)
  self.assertEqual(other.project(self.pid)['memory'],'saved');self.assertFalse(other.data['mcp'][0]['enabled'])
  self.assertTrue(other.project(self.pid)['workspace'].startswith(str(other.root)))
  self.assertTrue(pathlib.Path(other.project(self.pid)['skills'][0]['folder'],'SKILL.md').is_file())
  self.assertTrue(pathlib.Path(r['backup']).is_file());self.assertTrue(pathlib.Path(r['previousData']).is_dir())
 def test_restore_rejects_paths_and_links(self):
  for name in ('../escape','/absolute','C:\\file','a/../../file'):
   zpath=self.root/'bad.zip'
   with zipfile.ZipFile(zpath,'w') as z:z.writestr(name,'bad')
   before=self.s.path.read_bytes()
   with self.assertRaises(ValueError):self.s.restore_backup(zpath)
   self.assertEqual(self.s.path.read_bytes(),before)
  with zipfile.ZipFile(zpath,'w') as z:
   info=zipfile.ZipInfo('link');info.external_attr=0o120777<<16;z.writestr(info,'/etc/passwd')
  with self.assertRaises(ValueError):self.s.restore_backup(zpath)
 def test_restore_bad_schema_leaves_state_unchanged(self):
  p=self.root/'bad.zip'
  with zipfile.ZipFile(p,'w') as z:z.writestr('state.json','{"version":999}')
  before=self.s.path.read_bytes()
  with self.assertRaises(ValueError):self.s.restore_backup(p)
  self.assertEqual(before,self.s.path.read_bytes())
 def test_delete_archives_last_chat(self):
  c=self.s.chat(self.pid,self.cid);c['messages']=[{'role':'user','content':'keep me'}]
  self.s.change_chat({'projectID':self.pid,'chatID':self.cid,'action':'delete'})
  self.assertTrue(self.s.project(self.pid)['chats'])
  self.assertIn('keep me',next((self.s.root/'archives').glob('*.json')).read_text())
 def test_retry_and_edit_preserve_old_and_truncate_tool_chain(self):
  c=self.s.chat(self.pid,self.cid);c['messages']=[{'role':'user','content':'old'},{'role':'assistant','content':'answer'}]
  with patch.object(self.s,'start',return_value='job') as start:
   self.s.change_chat({'projectID':self.pid,'chatID':self.cid,'action':'edit','index':0,'text':'new'})
   start.assert_called_once_with(self.pid,self.cid,'new');self.assertEqual(c['messages'],[])
  self.assertIn('answer',next((self.s.root/'archives').glob('*.json')).read_text())
 def test_search_providers_and_missing_keys(self):
  for provider,payload in [('brave',{'web':{'results':[{'title':'t','url':'u'}]}}),('tavily',{'results':[{'title':'t','url':'u'}]}),('serper',{'organic':[{'title':'t','link':'u'}]})]:
   self.s.update_settings({'searchProvider':provider})
   with self.assertRaises(ValueError):self.s.search_web('hello')
   self.s.secrets[provider]='SECRET'
   with patch('core.request_json',return_value=io.BytesIO(json.dumps(payload).encode())) as req:
    self.assertEqual(self.s.search_web('hello')[0]['url'],'u');self.assertEqual(req.call_count,1)
   self.assertNotIn('SECRET',self.s.path.read_text())
 def test_offline_guards_every_network_tool(self):
  for name in ('mcp_list','mcp_call','browser_click','browser_fill','web_search'):
   with self.assertRaises(ValueError):self.s.execute(self.job(),name,{},self.s.data['settings'])
 def test_browser_approval_and_payload(self):
  self.s.update_settings({'mode':'internet'});j=self.job()
  with patch.object(self.s,'await_action',side_effect=[{'approved':False}]) as ask:
   self.assertEqual(self.s.execute(j,'browser_click',{'ref':'123'},self.s.data['settings'])['status'],'rejected');self.assertEqual(ask.call_count,1)
  with patch.object(self.s,'await_action',side_effect=[{'approved':True},{'title':'Page'}]) as ask:
   self.assertEqual(self.s.execute(j,'browser_fill',{'ref':'r','text':'abc'},self.s.data['settings']),{'title':'Page'})
   self.assertEqual(ask.call_args_list[-1].args[2]['arguments']['text'],'abc')
 def test_template_preserves_namespaces_escapes_and_requires_markers(self):
  root=pathlib.Path(self.s.project(self.pid)['workspace']);source=root/'template.docx'
  xml='<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:mc="urn:mc" xmlns:w14="urn:w14" mc:Ignorable="w14"><w:p><w:r><w:t>{{name}}</w:t></w:r></w:p></w:document>'
  with zipfile.ZipFile(source,'w') as z:z.writestr('word/document.xml',xml);z.writestr('other.bin',b'keep')
  result=self.s.template_document(root,'template.docx','out.docx',{'name':'A & B < C'})
  with zipfile.ZipFile(result['path']) as z:
   text=z.read('word/document.xml').decode();self.assertIn('xmlns:w14=',text);self.assertIn('A &amp; B &lt; C',text);self.assertEqual(z.read('other.bin'),b'keep')
  with self.assertRaises(ValueError):self.s.template_document(root,'template.docx','missing.docx',{'unknown':'x'})
  self.assertFalse((root/'missing.docx').exists())
  with self.assertRaises(ValueError):self.s.template_document(root,'template.docx','../escape.docx',{'name':'x'})
 def test_mcp_stdio_initialize_list_call_and_cleanup(self):
  server=self.root/'mcp.py';server.write_text('''import sys,json
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r:continue
 result={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]} if r['method']=='tools/list' else {'content':[{'type':'text','text':r.get('params',{}).get('arguments',{}).get('message','')}]}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
''')
  config=self.s.mcp_save({'name':'test','command':sys.executable,'args':[str(server)]});self.s.update_settings({'mode':'internet'})
  with patch.object(self.s,'await_action',return_value={'approved':True}):
   self.assertEqual(self.s.execute(self.job(),'mcp_list',{'serverID':config['id']},self.s.data['settings'])['tools'][0]['name'],'echo')
   result=self.s.execute(self.job(),'mcp_call',{'serverID':config['id'],'name':'echo','arguments':{'message':'hello'}},self.s.data['settings'])
   self.assertEqual(result['content'][0]['text'],'hello')
 def test_running_mutations_rejected(self):
  self.s.jobs={'j':{'status':'running'}}
  with self.assertRaises(ValueError):self.s.profile_save({'name':'x','prompt':'x'})
  with self.assertRaises(ValueError):self.s.change_chat({'projectID':self.pid,'chatID':self.cid,'action':'delete'})

if __name__=='__main__':unittest.main()
