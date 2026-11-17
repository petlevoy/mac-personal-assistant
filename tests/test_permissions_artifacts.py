import json,pathlib,sys,tempfile,threading,time,unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store

class PermissionsArtifactsTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.s=Store(pathlib.Path(self.tmp.name)/'data');self.pid=self.s.data['projects'][0]['id'];self.cid=self.s.project(self.pid)['chats'][0]['id']
  self.j={'id':'test','projectID':self.pid,'chatID':self.cid,'stop':threading.Event()}
 def tearDown(self):self.s.local.close();self.tmp.cleanup()
 def payload(self,tool='write_file'):return {'tool':tool,'arguments':{},'workspace':self.s.project(self.pid)['workspace']}
 def decision(self,response,payload=None,store=None,kind='approval'):
  store=store or self.s;out=[]
  thread=threading.Thread(target=lambda:out.append(store.await_action(self.j,kind,payload or self.payload())))
  thread.start();deadline=time.monotonic()+3
  while not store.pending and time.monotonic()<deadline:time.sleep(.01)
  try:
   self.assertTrue(store.pending);store.resolve(next(iter(store.pending)),response)
  finally:
   if not store.pending:self.j['stop'].set()
   thread.join(3)
  self.assertFalse(thread.is_alive());return out[0]
 def test_once_reject_per_tool_restart_and_reset(self):
  for approved in (False,True):
   self.assertEqual(self.decision({'approved':approved})['approved'],approved)
   self.assertEqual(self.s.data['permissions'],{'all':False,'tools':[]})
  self.decision({'approved':True,'scope':'tool'})
  again=Store(self.s.root)
  try:
   self.assertTrue(again.await_action(self.j,'approval',self.payload())['approved'])
   self.assertFalse(self.decision({'approved':False},self.payload('run_command'),again)['approved'])
   again.reset_permissions()
   self.assertFalse(self.decision({'approved':False},store=again)['approved'])
   self.assertEqual(json.loads(again.path.read_text())['permissions'],{'all':False,'tools':[]})
  finally:again.local.close()
 def test_global_persists_but_browser_response_and_offline_restrictions_remain(self):
  self.decision({'approved':True,'scope':'all'})
  again=Store(self.s.root)
  try:
   self.assertTrue(again.await_action(self.j,'approval',self.payload('run_command'))['approved'])
   self.assertEqual(self.decision({'ok':True},{'action':'browser_read'},again,kind='browser'),{'ok':True})
   with self.assertRaisesRegex(ValueError,'Интернет отключен'):again.execute(self.j,'web_search',{'query':'test'},again.data['settings'])
   self.j['stop'].set()
   with self.assertRaises(InterruptedError):again.await_action(self.j,'approval',self.payload())
  finally:again.local.close()
 def test_mcp_scope_binds_server_tool_and_command(self):
  p={'tool':'mcp_call','arguments':{'server':{'id':'a','command':'/bin/a','args':[]},'request':{'name':'read'}}}
  self.decision({'approved':True,'scope':'tool'},p)
  self.assertTrue(self.s.await_action(self.j,'approval',p)['approved'])
  for section,field,value in [('server','id','b'),('server','command','/bin/b'),('request','name','write')]:
   other=json.loads(json.dumps(p));other['arguments'][section][field]=value
   self.assertFalse(self.decision({'approved':False},other)['approved'])
 def test_artifacts_legacy_results_confinement_and_missing(self):
  root=pathlib.Path(self.s.project(self.pid)['workspace']);(root/'test.txt').write_text('hello')
  result=self.s.execute(self.j,'attach_file',{'path':'test.txt'},self.s.data['settings']);self.assertTrue(result['attached'])
  self.s.chat(self.pid,self.cid)['messages'].append({'role':'tool','name':'write_file','content':json.dumps({'written':'test.txt'})})
  artifact=self.s.snapshot()['projects'][0]['chats'][0]['messages'][0]['artifacts'][0]
  self.assertEqual(artifact,{'name':'test.txt','path':'test.txt','bytes':5})
  self.assertEqual(self.s.artifact_path(self.pid,artifact['path']),str(root/'test.txt'))
  outside=pathlib.Path(self.tmp.name)/'secret';outside.write_text('private');(root/'link').symlink_to(outside)
  for path in ('../escape',str(outside),'link','missing','.'):
   with self.subTest(path=path),self.assertRaises(ValueError):self.s.artifact(self.pid,path)
  (root/'test.txt').unlink()
  self.assertNotIn('artifacts',self.s.snapshot()['projects'][0]['chats'][0]['messages'][0])
 def test_rejected_write_does_not_create_file(self):
  self.s.await_action=lambda *a:{'approved':False}
  result=self.s.execute(self.j,'write_file',{'path':'no.txt','text':'no'},self.s.data['settings'])
  self.assertEqual(result['status'],'rejected');self.assertFalse((pathlib.Path(self.s.project(self.pid)['workspace'])/'no.txt').exists())
