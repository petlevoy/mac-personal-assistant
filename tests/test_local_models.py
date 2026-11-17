import hashlib,json,pathlib,struct,sys,tempfile,threading,time,unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from local_models import LocalModels,gguf_info
from core import Store
PAYLOAD=b'GGUF'+struct.pack('<I',3)+b'\0'*(2*1024*1024)
class Hub(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  if '/resolve/' in self.path:
   offset=int(self.headers.get('Range','bytes=0-').split('=')[1].split('-')[0]);data=PAYLOAD[offset:]
   self.send_response(206 if offset else 200);self.send_header('Content-Length',str(len(data)));self.end_headers()
   try:
    for i in range(0,len(data),16384):self.wfile.write(data[i:i+16384]);self.wfile.flush();time.sleep(.005)
   except (BrokenPipeError,ConnectionResetError):pass
   return
  if self.path.startswith('/api/models?'):obj=[{'id':'test/model','downloads':2,'likes':1}]
  else:obj={'siblings':[{'rfilename':'model.gguf','size':len(PAYLOAD),'lfs':{'sha256':hashlib.sha256(PAYLOAD).hexdigest()}}]}
  data=json.dumps(obj).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
class LocalTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.local=LocalModels(self.root)
  self.http=ThreadingHTTPServer(('127.0.0.1',0),Hub);threading.Thread(target=self.http.serve_forever,daemon=True).start()
  self.patch=patch('local_models.HF',f'http://127.0.0.1:{self.http.server_address[1]}');self.patch.start()
 def tearDown(self):self.local.close();self.http.shutdown();self.http.server_close();self.patch.stop();self.tmp.cleanup()
 def settle(self,id):
  end=time.monotonic()+5
  while self.local.downloads[id].get('_active') and time.monotonic()<end:time.sleep(.02)
  self.assertFalse(self.local.downloads[id].get('_active'))
 def test_download_pause_resume_integrity_library(self):
  self.assertEqual(self.local.search('test')[0]['id'],'test/model')
  id=self.local.start_download('test/model','model.gguf');time.sleep(.12);self.local.control(id,'pause');self.settle(id)
  d=self.local.downloads[id];self.assertEqual(d['status'],'paused');self.assertGreater(d['bytes'],0)
  self.local.control(id,'resume');self.settle(id);self.assertEqual(d['status'],'complete',d)
  self.assertEqual(pathlib.Path(d['path']).read_bytes(),PAYLOAD);self.assertEqual(len(self.local.library()),1)
 def test_cancel_partial(self):
  id=self.local.start_download('test/model','model.gguf');time.sleep(.1);self.local.control(id,'cancel');self.settle(id)
  self.assertEqual(self.local.downloads[id]['status'],'cancelled');self.assertFalse(pathlib.Path(self.local.downloads[id]['path']+'.part').exists())
 def test_invalid_gguf_and_paths(self):
  p=self.root/'bad.gguf';p.write_text('not a model')
  with self.assertRaises(ValueError):gguf_info(p)
  with self.assertRaises(ValueError):self.local.start_download('test/model','../model.gguf')
 def test_missing_engine_is_visible_error(self):
  p=self.root/'good.gguf';p.write_bytes(PAYLOAD);self.local.load(str(p),4096)
  end=time.monotonic()+3
  while self.local.state['status']=='loading' and time.monotonic()<end:time.sleep(.01)
  self.assertEqual(self.local.state['status'],'error');self.assertIn('движок',self.local.state['error'])
 def test_local_default_and_prompt_persistence(self):
  s=Store(self.root/'store');self.assertEqual(s.data['settings']['provider'],'local')
  profile=s.data['profiles'][0];s.profile_save({'id':profile['id'],'name':'Test','prompt':'persistent prompt'})
  again=Store(self.root/'store');self.assertEqual(again.data['profiles'][0]['prompt'],'persistent prompt');s.local.close();again.local.close()
 def test_restart_releases_download_active_flag(self):
  self.local.downloads={'x':{'id':'x','status':'downloading','_active':True}};self.local.persist()
  other=LocalModels(self.root);self.assertEqual(other.downloads['x']['status'],'paused');self.assertNotIn('_active',other.downloads['x']);other.close()
 def test_restore_keeps_model_weights_without_exporting_them(self):
  s=Store(self.root/'store');weights=s.root/'models'/'kept.gguf';weights.write_bytes(PAYLOAD)
  backup=s.export(self.root/'backup.zip')
  import zipfile
  with zipfile.ZipFile(backup) as z:self.assertFalse(any(n.startswith('models/') for n in z.namelist()))
  s.restore_backup(backup);self.assertEqual(weights.read_bytes(),PAYLOAD);self.assertEqual(len(s.local.library()),1);s.local.close()
