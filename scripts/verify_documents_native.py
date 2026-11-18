"""Deterministic full native file/OCR/deletion coverage, no user data or paid API."""
import http.server,json,pathlib,subprocess,sys,threading,re
class Fixture(http.server.BaseHTTPRequestHandler):
 parts=[]
 def log_message(self,*args):pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  text=data['messages'][-1]['content']
  if 'Чтение файла,' in text:
   Fixture.parts.append(text.split('<данные>\n',1)[1].rsplit('\n</данные>',1)[0])
  markers=[x for x in ['START-123','MIDDLE-456','END-987'] if x in text]
  answer=' '.join(markers) or 'Нет маркеров.'
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{'content':answer},'finish_reason':'stop'}]})+'\n\ndata: [DONE]\n\n').encode())
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
threading.Thread(target=server.serve_forever,daemon=True).start()
app=pathlib.Path(sys.argv[1]).resolve();report=pathlib.Path(sys.argv[2]).resolve()
try:
 r=subprocess.run([str(app/'Contents/MacOS/PersonalAssistant'),'-ApplePersistenceIgnoreState','YES','--smoke-test',str(report),'--skip-keychain','--documents-smoke-base',f'http://127.0.0.1:{server.server_port}'],capture_output=True,timeout=240)
 assert r.returncode==0,r.stderr.decode(errors='replace')[-3000:]
 data=json.loads(report.read_text());print(json.dumps(data,ensure_ascii=False,indent=2));assert data['status']=='passed',data
 combined=''.join(Fixture.parts);assert len(combined)>60000 and all(v in combined for v in ['START-123','MIDDLE-456','END-987'])
 print('PASS: native OCR/mixed PDF, >60k full file coverage, chat results, confirmed/cancelled model deletion')
finally:server.shutdown();server.server_close()
