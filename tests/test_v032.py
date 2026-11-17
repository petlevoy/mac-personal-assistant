import io,json,pathlib,sys,tempfile,threading,unittest,zipfile,time
from unittest.mock import patch,Mock
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store,extract_text
from office import create_office
from telemetry import thermal_guard

class Release032Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.s=Store(self.root/'state');self.p=self.s.data['projects'][0];self.c=self.p['chats'][0]
 def tearDown(self): self.s.stop();self.s.local.close();self.tmp.cleanup()
 def test_office_roundtrip_all_formats_and_safe_cells(self):
  fixtures={'docx':{'title':'Документ','paragraphs':['Привет мир'],'tables':[[['Сумма',42]]]},'pptx':{'slides':[{'title':'Презентация','body':['Привет мир','Пункт 2']}]},'xlsx':{'sheets':[{'name':'Данные','rows':[['Привет мир',42],['=HYPERLINK("bad")',True]]}]}}
  for ext,content in fixtures.items():
   with self.subTest(ext=ext):
    result=create_office(self.root,'out.'+ext,content);self.assertGreater(result['bytes'],100)
    self.assertIn('Привет мир',extract_text(self.root/('out.'+ext))[0])
    with zipfile.ZipFile(self.root/('out.'+ext)) as z:
     self.assertIsNone(z.testzip())
     if ext=='xlsx': self.assertNotIn(b'<f>',z.read('xl/worksheets/sheet1.xml'))
    with self.assertRaises(ValueError):create_office(self.root,'out.'+ext,content)
  with self.assertRaises(ValueError):create_office(self.root,'../escape.docx',{})
 def test_office_tool_requires_approval_and_read_file_works(self):
  job={'id':'test','projectID':self.p['id'],'chatID':self.c['id'],'stop':threading.Event()};args={'output':'a.pptx','content':json.dumps({'slides':[{'title':'Tool created','body':['Verified text']}]})}
  self.s.await_action=lambda *args:{'approved':False}
  self.assertEqual(self.s.execute(job,'create_office',args,self.s.data['settings']),{'status':'rejected'})
  self.assertFalse((pathlib.Path(self.p['workspace'])/'a.pptx').exists())
  self.s.await_action=lambda *args:{'approved':True}
  self.s.execute(job,'create_office',args,self.s.data['settings'])
  self.assertIn('Verified text',self.s.execute(job,'read_file',{'path':'a.pptx'},self.s.data['settings'])['text'])
 def test_profile_delete_last_and_references_survive_restart(self):
  old=self.c['profileID'];replacement=self.s.profile_delete(old)['id'];self.assertNotEqual(replacement,old)
  self.assertEqual(self.c['profileID'],replacement);self.assertEqual(self.s.data['profiles'][0]['prompt'],'')
  self.assertEqual(len(list((self.s.root/'archives').glob('profile-*.json'))),1)
  again=Store(self.s.root)
  try:self.assertEqual(again.data['projects'][0]['chats'][0]['profileID'],replacement)
  finally:again.local.close()
 def test_usage_is_reported_not_estimated_and_thermal_worker_exits(self):
  raw=b'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3}}\n\ndata: [DONE]\n\n'
  observed=[]
  def guard(store,done,limit):
   observed.append(done);done.wait(1)
  self.s.update_settings({'provider':'local','model':'fake','thermalEnabled':True})
  with patch.object(self.s.local,'endpoint',return_value=('http://127.0.0.1:1/v1','')),patch('core.request_json',return_value=io.BytesIO(raw)),patch('telemetry.thermal_guard',side_effect=guard):
   text,calls=self.s.stream_model(self.s.data['settings'],[],threading.Event(),lambda _:None)
  self.assertEqual(text,'Hello');self.assertTrue(observed[0].is_set());self.assertEqual(self.s.usage['inputTokens'],11);self.assertEqual(self.s.usage['outputTokens'],3);self.assertEqual(self.s.usage['sentBytes'],0)
  self.s.update_settings({'provider':'openai','baseURL':'https://example.com/v1','mode':'cloud'})
  with patch('core.request_json',return_value=io.BytesIO(b'data: {"choices":[{"delta":{"content":"No usage"}}]}\n\ndata: [DONE]\n\n')):
   self.s.stream_model(self.s.data['settings'],[],threading.Event(),lambda _:None)
  self.assertEqual(self.s.usage['inputTokens'],11);self.assertEqual(self.s.usage['missingRequests'],1);self.assertGreater(self.s.usage['sentBytes'],0);self.assertGreater(self.s.usage['receivedBytes'],0)
 def test_thermal_guard_resumes_exact_owned_process_on_stop(self):
  done=threading.Event();self.s.local.process=Mock(pid=123456);self.s.local.process.poll.return_value=None
  signals=[]
  def kill(pid,sig):
   signals.append((pid,sig));done.set()
  try:
   with patch('telemetry.temperatures',return_value={'cpu':90,'gpu':None}),patch('telemetry.os.kill',side_effect=kill):thermal_guard(self.s,done,80)
   import signal
   self.assertEqual(signals,[(123456,signal.SIGSTOP),(123456,signal.SIGCONT)]);self.assertFalse(self.s.thermal['limited'])
  finally:self.s.local.process=None
 def test_thermal_settings_persist_and_clamp(self):
  self.s.update_settings({'thermalEnabled':True,'thermalLimit':200});again=Store(self.s.root)
  try:self.assertTrue(again.data['settings']['thermalEnabled']);self.assertEqual(again.data['settings']['thermalLimit'],100)
  finally:again.local.close()

if __name__=='__main__':unittest.main()
