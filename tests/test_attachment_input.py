"""Exercise the actual authenticated import/send API through the model boundary."""
import json,pathlib,sys,tempfile,threading,time,unittest,urllib.request,urllib.error,zipfile
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from server import serve
from core import extract_text

class AttachmentInput(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name)
  self.server=serve(self.root/'data','test-token-for-local-http-fixture');self.thread=threading.Thread(target=self.server.serve_forever);self.thread.start()
  self.store=self.server.store;self.pid=self.store.data['projects'][0]['id'];self.cid=self.store.data['projects'][0]['chats'][0]['id']
 def tearDown(self):
  self.server.shutdown();self.thread.join();self.server.server_close();self.store.local.close();self.tmp.cleanup()
 def post(self,path,data):
  req=urllib.request.Request('http://127.0.0.1:'+str(self.server.server_port)+path,data=json.dumps(data).encode(),headers={'X-App-Token':self.server.token,'Content-Type':'application/json'})
  with urllib.request.urlopen(req,timeout=5) as r:return json.load(r)
 def test_two_files_reach_model_and_originals_persist(self):
  self.store.update_settings({'model':'fixture','contextLimit':32768,'toolsEnabled':False})
  contents=['Первый файл: Маркер-А 123','Второй файл: Маркер-Б 456']
  imported=[]
  for i,value in enumerate(contents):
   p=self.root/f'file{i}.txt';p.write_text(value)
   r=self.post('/attachment',{'projectID':self.pid,'path':str(p)})
   self.assertEqual(r['text'],value);self.assertFalse(r['truncated']);self.assertEqual(pathlib.Path(r['storedPath']).read_text(),value);imported.append(r)
  requests=[]
  def model(settings,messages,stop,callback,tools_enabled=True):
   requests.append(messages);callback('Оба файла прочитаны');return 'Оба файла прочитаны',[]
  self.store.stream_model=model
  text='Сравни файлы'+''.join('\n\n[Файл: '+r['name']+']\n'+r['text']+'\n[Конец файла]' for r in imported)
  job=self.post('/send',{'projectID':self.pid,'chatID':self.cid,'text':text})['id']
  for _ in range(200):
   if self.store.jobs[job]['status']!='running':break
   time.sleep(.01)
  self.assertEqual(self.store.jobs[job]['status'],'done',self.store.jobs[job])
  all_input=json.dumps(requests,ensure_ascii=False)
  for value in contents:self.assertIn(value,all_input)
 def test_empty_unsupported_and_oversize_rejected_without_copy(self):
  for name,content in [('empty.txt',b''),('unsupported.bin',b'abc'),('oversize.txt',b'a'*(12*1024*1024+1))]:
   p=self.root/name;p.write_bytes(content)
   with self.assertRaises(urllib.error.HTTPError) as err:self.post('/attachment',{'projectID':self.pid,'path':str(p)})
   self.assertEqual(err.exception.code,400)
  folder=self.store.root/'projects'/self.pid/'files';self.assertFalse(list(folder.glob('*')))
 def test_sheet_names_order_sparse_cells_and_uncalculated_formula(self):
  p=self.root/'book.xlsx'
  with zipfile.ZipFile(p,'w') as z:
   z.writestr('xl/workbook.xml','<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Итоги" r:id="r1"/><sheet name="Детали" r:id="r2"/></sheets></workbook>')
   z.writestr('xl/_rels/workbook.xml.rels','<Relationships><Relationship Id="r1" Target="worksheets/sheet10.xml"/><Relationship Id="r2" Target="worksheets/sheet2.xml"/></Relationships>')
   z.writestr('xl/worksheets/sheet10.xml','<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c r="A1" t="inlineStr"><is><t>Доход</t></is></c><c r="D1"><f>SUM(A2:A5)</f></c></row></sheetData></worksheet>')
   z.writestr('xl/worksheets/sheet2.xml','<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c r="B42"><v>987</v></c></row></sheetData></worksheet>')
  text,truncated=extract_text(p)
  self.assertLess(text.index('Итоги'),text.index('Детали'));self.assertIn('A1=Доход',text);self.assertIn('D1= [формула: =SUM(A2:A5); сохранённого значения нет]',text);self.assertIn('B42=987',text);self.assertFalse(truncated)
if __name__=='__main__':unittest.main()
