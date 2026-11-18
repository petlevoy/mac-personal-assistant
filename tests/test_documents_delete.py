import json,pathlib,tempfile,threading,time,unittest,sys,struct
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store,extract_text
from documents import chunks
from model_deletion import preview,delete
class DocumentsDeletion(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name);self.store=Store(self.root/'data')
  self.pid=self.store.data['projects'][0]['id'];self.cid=self.store.data['projects'][0]['chats'][0]['id']
 def tearDown(self): self.store.local.close();self.temp.cleanup()
 def model(self,name='test.gguf',image=False):
  p=self.store.local.folder/name;p.write_bytes(b'GGUF'+struct.pack('<I',3)+b'fixture')
  if image:self.store.update_settings({'imageLocalModel':str(p)})
  else:self.store.local.known.append(str(p));self.store.data['settings']['model']=str(p)
  return p
 def test_full_unicode_and_large_import(self):
  value='START-123\n'+'Русский текст строки\n'*6000+'END-987';p=self.root/'big.txt';p.write_text(value)
  text,truncated=extract_text(p);self.assertEqual(value,text);self.assertFalse(truncated)
  pieces=list(chunks(value,2000));self.assertEqual(''.join(pieces),value);self.assertTrue(all(len(x.encode())<=2000 for x in pieces))
 def test_delete_registered_text_recoverable_and_reusable(self):
  p=self.model();data=p.read_bytes();pre=preview(self.store,str(p));self.assertEqual(pre['size'],len(data))
  self.assertTrue(p.exists()) # preview/cancel non-destructive
  result=delete(self.store,pre['token'],self.root/'trash');self.assertFalse(p.exists());self.assertEqual(pathlib.Path(result['trashedPath']).read_bytes(),data)
  self.assertFalse(self.store.data['settings']['model']);self.assertEqual(self.store.model_library(),[])
  with self.assertRaises(ValueError):delete(self.store,pre['token'],self.root/'trash')
 def test_delete_registered_image_and_clear_setting(self):
  p=self.model('picture.safetensors',True);pre=preview(self.store,str(p));delete(self.store,pre['token'],self.root/'trash')
  self.assertEqual(self.store.data['settings']['imageLocalModel'],'');self.assertFalse(self.store.model_library())
 def test_busy_changed_unknown_symlink_guards(self):
  p=self.model();pre=preview(self.store,str(p));p.write_bytes(p.read_bytes()+b'changed')
  with self.assertRaises(ValueError):delete(self.store,pre['token'],self.root/'trash')
  self.assertTrue(p.exists());self.store.jobs={'x':{'status':'running'}}
  with self.assertRaises(ValueError):preview(self.store,str(p))
  self.store.jobs={};unknown=self.root/'unknown.gguf';unknown.write_bytes(p.read_bytes())
  with self.assertRaises(ValueError):preview(self.store,str(unknown))
  link=self.store.local.folder/'link.gguf';link.symlink_to(p)
  with self.assertRaises(ValueError):preview(self.store,str(link))
 def test_busy_between_preview_and_delete(self):
  p=self.model();pre=preview(self.store,str(p));self.store.jobs={'x':{'status':'running'}}
  with self.assertRaises(ValueError):delete(self.store,pre['token'],self.root/'trash')
  self.assertTrue(p.exists())
 def test_download_reset_and_active_guard(self):
  p=self.model();self.store.local.downloads={'d':{'path':str(p),'status':'complete','id':'d'}}
  pre=preview(self.store,str(p));delete(self.store,pre['token'],self.root/'trash');self.assertEqual(self.store.local.downloads,{})
  p=self.model();self.store.local.downloads={'d':{'path':str(p),'status':'downloading','_active':True,'id':'d'}}
  with self.assertRaises(ValueError):preview(self.store,str(p))
 def test_full_pipeline_all_characters_bounded_and_followup(self):
  self.store.update_settings({'model':'fixture','contextLimit':4096,'toolsEnabled':False})
  value='START-123\n'+'Текст строк.\n'*3500+'MIDDLE-456\n'+'Текст строк.\n'*3500+'END-987'
  text='Найди маркеры.\n[Файл: big.txt]\n'+value+'\n[Конец файла]'
  seen=[];requests=[]
  def stream(s,m,stop,callback,tools_enabled=True):
   self.assertFalse(tools_enabled);raw=m[-1]['content'];requests.append(raw)
   if '<данные>\n' in raw:
    part=raw.split('<данные>\n',1)[1].rsplit('\n</данные>',1)[0]
    if 'Чтение файла,' in raw:seen.append(part)
   answer=' '.join(v for v in ['START-123','MIDDLE-456','END-987'] if v in raw) or 'Нет маркеров.'
   callback(answer);return answer,[]
  self.store.stream_model=stream;jid=self.store.start(self.pid,self.cid,text)
  for _ in range(100):
   if self.store.jobs[jid]['status']!='running':break
   time.sleep(.02)
  job=self.store.jobs[jid];self.assertEqual(job['status'],'done',job)
  self.assertEqual(''.join(seen),text)
  chat=self.store.chat(self.pid,self.cid);self.assertIn('END-987',chat['messages'][-1]['content']);self.assertIn('START-123',chat['messages'][-1]['content']);self.assertIn('MIDDLE-456',chat['messages'][-1]['content'])
  self.assertEqual(chat['messages'][0]['content'],text);self.assertLess(len(self.store.prepare_messages(self.pid,self.cid)[1]['content']),4096)
  coverage=list((self.store.root/'projects'/self.pid/'files').glob('analysis-*/coverage.json'))[0];self.assertEqual(json.loads(coverage.read_text())['processedCharacters'],len(text))
 def test_cancellation_no_false_complete(self):
  self.store.update_settings({'model':'fixture','contextLimit':4096,'toolsEnabled':False})
  def stream(s,m,stop,cb,tools_enabled=True):
   stop.set();raise InterruptedError('Остановлено')
  self.store.stream_model=stream;jid=self.store.start(self.pid,self.cid,'a'*70000)
  for _ in range(100):
   if self.store.jobs[jid]['status']!='running':break
   time.sleep(.01)
  self.assertEqual(self.store.jobs[jid]['status'],'stopped');self.assertFalse(list(self.store.root.rglob('coverage.json')))
if __name__=='__main__':unittest.main()
