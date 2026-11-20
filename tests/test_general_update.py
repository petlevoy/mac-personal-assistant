import json, pathlib, struct, sys, tempfile, threading, unittest, subprocess
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store
from context_budget import budget
from diagnostics import report
from sandbox import launch

class GeneralUpdate(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.s=Store(self.root/'data');self.pid=self.s.data['projects'][0]['id'];self.cid=self.s.project(self.pid)['chats'][0]['id']
 def tearDown(self):self.s.local.close();self.tmp.cleanup()
 def test_skill_discovery_activation_and_escape(self):
  root=self.root/'catalog';good=root/'a'/'b';good.mkdir(parents=True)
  (good/'SKILL.md').write_text('---\nname: xlsx\ntriggers: spreadsheet, таблица\n---\nUse spreadsheet instructions')
  outside=self.root/'outside';outside.mkdir();(outside/'SKILL.md').write_text('secret')
  (root/'link').symlink_to(outside,target_is_directory=True)
  self.s.import_skill(self.pid,root);self.assertEqual(len(self.s.project(self.pid)['skills']),1)
  self.s.chat(self.pid,self.cid)['messages'].append({'role':'user','content':'сделай таблица'})
  self.assertIn('Use spreadsheet instructions',self.s.prepare_messages(self.pid,self.cid)[0]['content'])
  new=root/'new';new.mkdir();(new/'SKILL.md').write_text('new skill')
  self.s.prepare_messages(self.pid,self.cid);self.assertEqual(len(self.s.project(self.pid)['skills']),2)
 def test_context_metadata_and_no_universal_128k_cap(self):
  model=self.root/'m.gguf';key=b'llama.context_length'
  model.write_bytes(b'GGUF'+struct.pack('<IQQQ',3,0,1,len(key))+key+struct.pack('<II',4,262144))
  self.assertEqual(budget({'provider':'local','model':str(model),'contextLimit':400000})['effective'],262144)
  self.s.update_settings({'contextLimit':200000});self.assertEqual(self.s.data['settings']['contextLimit'],200000)
 def test_diagnostics_redacts_and_explains_missing_data(self):
  self.s.secrets['model']='test_secret_key';self.s.log(self.pid,'error','token=test_secret_key')
  data=report(self.s,self.pid);self.assertNotIn('test_secret_key',json.dumps(data));self.assertEqual(data['app'],'inij');self.assertEqual(data['paths']['models']['path'],str(self.s.local.folder));self.assertEqual(data['connections']['probe'].split(';')[0],'not_run')
 def test_english_errors_do_not_translate_user_content(self):
  from localization import presentation
  self.assertEqual(presentation({'error':'Путь вне выбранной папки проекта','content':'Новый чат'}),{'error':'Path is outside the selected project folder','content':'Новый чат'})
  with patch.dict('os.environ',{'INIJ_UI_LANG':'en-US'}):
   cid=self.s.create_chat(self.pid);self.assertEqual(self.s.chat(self.pid,cid)['title'],'New chat')
 def test_one_time_approval_cannot_persist(self):
  self.s.pending['r']={'id':'r','kind':'approval','oneTimeOnly':True,'tool':'run_command','arguments':{'command':'pwd'}}
  with self.assertRaises(ValueError):self.s.resolve('r',{'approved':True,'scope':'all'})
  self.assertFalse(self.s.data['permissions']['all'])
 def test_unsupported_platform_fails_closed(self):
  with patch('sandbox.sys.platform','linux'):
   with self.assertRaises(ValueError):launch(['/bin/sh','-c','true'],self.root)
 @unittest.skipUnless(sys.platform=='darwin','macOS kernel enforcement')
 def test_kernel_denies_sibling_secret_and_network(self):
  workspace=self.root/'workspace';workspace.mkdir();secret=self.root/'secret';secret.write_text('private')
  cmd,env=launch(['/bin/sh','-c',f'cat "{secret}"; echo success > local.txt'],workspace)
  proc=subprocess.run(cmd,cwd=workspace,env=env,capture_output=True,text=True)
  self.assertNotIn('private',proc.stdout);self.assertTrue((workspace/'local.txt').exists());self.assertIn('Operation not permitted',proc.stderr)
  from http.server import HTTPServer,BaseHTTPRequestHandler
  class Handler(BaseHTTPRequestHandler):
   def do_GET(self):self.send_response(200);self.end_headers();self.wfile.write(b'network_ok')
   def log_message(self,*a):pass
  server=HTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever);thread.start()
  try:
   args=['/usr/bin/curl','--max-time','2','http://127.0.0.1:'+str(server.server_port)]
   cmd,env=launch(args,workspace)
   proc=subprocess.run(cmd,cwd=workspace,env=env,capture_output=True,text=True);self.assertNotEqual(proc.returncode,0)
   cmd,env=launch(args,workspace,network=True)
   proc=subprocess.run(cmd,cwd=workspace,env=env,capture_output=True,text=True);self.assertEqual(proc.returncode,0);self.assertEqual(proc.stdout,'network_ok')
  finally:server.shutdown();thread.join();server.server_close()
  cmd,env=launch(['/bin/cat',str(secret)],workspace,escalated=True)
  self.assertEqual(subprocess.check_output(cmd,cwd=workspace,env=env,text=True),'private')
if __name__=='__main__':unittest.main()
