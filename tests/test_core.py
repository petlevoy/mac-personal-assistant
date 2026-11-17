import json, pathlib, sys, tempfile, threading, time, unittest, urllib.request, urllib.error, zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store, validate_endpoint, safe_path, extract_text, parse_skill, estimate_tokens, offline_shell_available
from server import serve

class FakeModel(BaseHTTPRequestHandler):
    bodies=[]
    response_mode='text'
    def log_message(self,*args): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"models":[{"name":"mock"}]}')
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); type(self).bodies.append(body)
        if type(self).response_mode=='http_error':
            self.send_response(400); self.end_headers()
            self.wfile.write(json.dumps({'error':{'message':'Template does not support tools key-test-secret'}}).encode()); return
        self.send_response(200); self.end_headers()
        if type(self).response_mode=='tool' and not any(m['role']=='tool' for m in body['messages']):
            chunks=[{'message':{'content':'','tool_calls':[{'function':{'name':'list_files','arguments':{'path':'.'}}}]}}]
        else: chunks=[{'message':{'content':'При'}},{'message':{'content':'вет'}},{'done':True}]
        if self.path.endswith('chat/completions'):
            if type(self).response_mode=='empty':
                self.wfile.write(b'data: [DONE]\n\n'); return
            for part in ['При','вет']:
                self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{'content':part}}]})+'\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        else:
            for chunk in chunks:
                try:
                    self.wfile.write((json.dumps(chunk)+'\n').encode()); self.wfile.flush()
                    if type(self).response_mode=='slow': time.sleep(3)
                except (BrokenPipeError,ConnectionResetError): break

class CoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=pathlib.Path(self.tmp.name); self.store=Store(self.root/'data')
        self.pid=self.store.data['projects'][0]['id']; self.cid=self.store.project(self.pid)['chats'][0]['id']
        FakeModel.bodies=[]; FakeModel.response_mode='text'
        self.model=ThreadingHTTPServer(('127.0.0.1',0),FakeModel)
        self.thread=threading.Thread(target=self.model.serve_forever,daemon=True); self.thread.start()
        self.store.update_settings({'provider':'ollama','toolsEnabled':True,'baseURL':f'http://127.0.0.1:{self.model.server_address[1]}','model':'mock'})
    def tearDown(self): self.model.shutdown(); self.model.server_close(); self.tmp.cleanup()
    def wait(self,jid):
        deadline=time.monotonic()+5
        while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(self.store.jobs[jid]['status'],'done',self.store.jobs[jid])
    def job(self): return {'id':'test','projectID':self.pid,'stop':threading.Event()}
    def test_offline_rejects_remote(self):
        for base in ['https://example.com','http://localhost.evil','http://user:pass@localhost','file:///etc/passwd']:
            with self.assertRaises(ValueError): validate_endpoint(base,'offline','ollama')
        with self.assertRaises(ValueError): validate_endpoint('http://example.com','cloud','openai')
        self.assertEqual(validate_endpoint('https://example.com/v1','cloud','openai'),'https://example.com/v1')
    def test_paths_and_symlinks(self):
        folder=self.root/'inside'; folder.mkdir(); (folder/'link').symlink_to(self.root)
        for relative in ['../secret','link/secret','/etc/passwd']:
            with self.assertRaises(ValueError): safe_path(folder,relative)
    def test_stream_ollama_and_persistence(self):
        jid=self.store.start(self.pid,self.cid,'Привет'); self.wait(jid)
        self.assertEqual(self.store.chat(self.pid,self.cid)['messages'][-1]['content'],'Привет')
        self.assertEqual(Store(self.root/'data').chat(self.pid,self.cid)['messages'][-1]['content'],'Привет')
        self.assertNotIn('web_search',[t['function']['name'] for t in FakeModel.bodies[0]['tools']])
        self.assertEqual('run_command' in [t['function']['name'] for t in FakeModel.bodies[0]['tools']],offline_shell_available())
    def test_openai_sse(self):
        self.store.update_settings({'provider':'openai'})
        jid=self.store.start(self.pid,self.cid,'hi'); self.wait(jid)
        self.assertEqual(self.store.chat(self.pid,self.cid)['messages'][-1]['content'],'Привет')
    def test_empty_model_response_fails_with_persistent_reason(self):
        FakeModel.response_mode='empty'
        self.store.update_settings({'provider':'openai'})
        jid=self.store.start(self.pid,self.cid,'hi')
        deadline=time.monotonic()+5
        while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(self.store.jobs[jid]['status'],'failed')
        self.assertIn('без текста',self.store.jobs[jid]['error'])
        again=Store(self.root/'data')
        self.assertIn('Ошибка ответа:',again.chat(self.pid,self.cid)['messages'][-1]['content'])
        self.assertIn('без текста',again.chat(self.pid,self.cid)['messages'][-1]['content'])
        again.local.close()
    def test_connection_failure_reason_survives_restart(self):
        self.model.shutdown(); self.model.server_close()
        jid=self.store.start(self.pid,self.cid,'hi')
        deadline=time.monotonic()+5
        while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(self.store.jobs[jid]['status'],'failed')
        again=Store(self.root/'data')
        message=again.chat(self.pid,self.cid)['messages'][-1]['content']
        self.assertIn(self.store.jobs[jid]['error'],message)
        self.assertNotIn('[Ответ не завершен]',message)
        again.local.close()
    def test_local_http_error_explains_template_and_redacts_key(self):
        from unittest.mock import patch
        FakeModel.response_mode='http_error'
        self.store.update_settings({'provider':'local','model':'test.gguf'})
        endpoint=f'http://127.0.0.1:{self.model.server_address[1]}'
        with patch.object(self.store.local,'endpoint',return_value=(endpoint,'key-test-secret')):
            jid=self.store.start(self.pid,self.cid,'hi')
            deadline=time.monotonic()+5
            while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(self.store.jobs[jid]['status'],'failed')
        error=self.store.jobs[jid]['error']
        self.assertIn('Template does not support tools',error)
        self.assertNotIn('key-test-secret',error)
    def test_cloud_http_error_does_not_echo_body(self):
        FakeModel.response_mode='http_error'
        self.store.update_settings({'provider':'openai'})
        jid=self.store.start(self.pid,self.cid,'hi')
        deadline=time.monotonic()+5
        while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.01)
        error=self.store.jobs[jid]['error']
        self.assertIn('HTTP 400',error)
        self.assertNotIn('key-test-secret',error)
    def test_agent_tool_loop(self):
        FakeModel.response_mode='tool'; jid=self.store.start(self.pid,self.cid,'list'); self.wait(jid)
        messages=self.store.chat(self.pid,self.cid)['messages']
        self.assertEqual([m['role'] for m in messages],['user','assistant','tool','assistant'])
        self.assertEqual(messages[2]['name'],'list_files')
        # Ollama arguments must be object, not OpenAI JSON-string.
        self.assertIsInstance(FakeModel.bodies[1]['messages'][2]['tool_calls'][0]['function']['arguments'],dict)
    def test_secrets_not_persisted_export(self):
        self.store.secrets['model']='SECRET_SENTINEL'; self.store.save()
        archive=self.root/'out.zip'; self.store.export(archive)
        with zipfile.ZipFile(archive) as z:
            self.assertIsNone(z.testzip())
            self.assertNotIn(b'SECRET_SENTINEL',b''.join(z.read(n) for n in z.namelist()))
    def test_selected_skill_only_and_isolation(self):
        folder=self.root/'skill'; folder.mkdir(); (folder/'SKILL.md').write_text('---\nname: Example\ndescription: A test\n---\nSPECIAL_RULE python3 BRAVE_API_KEY')
        id=self.store.import_skill(self.pid,str(folder)); self.assertEqual(self.store.project(self.pid)['skills'][0]['requiredKeys'],['BRAVE_API_KEY'])
        self.assertNotIn('SPECIAL_RULE',self.store.prepare_messages(self.pid,self.cid)[0]['content'])
        self.store.chat(self.pid,self.cid)['skillIDs']=[id]
        self.assertIn('SPECIAL_RULE',self.store.prepare_messages(self.pid,self.cid)[0]['content'])
        other=self.store.create_project('other'); chat=self.store.project(other)['chats'][0]['id']
        self.assertNotIn('SPECIAL_RULE',self.store.prepare_messages(other,chat)[0]['content'])
    def test_skill_reference_access_is_scoped(self):
        folder=self.root/'skill'; folder.mkdir(); (folder/'SKILL.md').write_text('Reference')
        (folder/'note.txt').write_text('skill reference')
        id=self.store.import_skill(self.pid,str(folder)); job={**self.job(),'chatID':self.cid}
        with self.assertRaises(ValueError): self.store.execute(job,'read_skill_file',{'skillID':id,'path':'note.txt'},self.store.data['settings'])
        self.store.chat(self.pid,self.cid)['skillIDs']=[id]
        self.assertEqual(self.store.execute(job,'read_skill_file',{'skillID':id,'path':'note.txt'},self.store.data['settings'])['text'],'skill reference')
        with self.assertRaises(ValueError): self.store.execute(job,'read_skill_file',{'skillID':id,'path':'../../state.json'},self.store.data['settings'])
    def test_import_skill_does_not_execute(self):
        folder=self.root/'skill'; folder.mkdir(); (folder/'SKILL.md').write_text('Instructions')
        (folder/'danger.sh').write_text('touch '+str(self.root/'bad'))
        self.store.import_skill(self.pid,str(folder)); self.assertFalse((self.root/'bad').exists())
    def test_docx_xlsx(self):
        path=self.root/'test.docx'
        with zipfile.ZipFile(path,'w') as z: z.writestr('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Привет</w:t></w:r></w:p></w:document>')
        self.assertEqual(extract_text(path),('Привет',False))
        path=self.root/'test.xlsx'
        with zipfile.ZipFile(path,'w') as z:
            z.writestr('xl/sharedStrings.xml','<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Hello</t></si></sst>')
            z.writestr('xl/worksheets/sheet1.xml','<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>')
        self.assertIn('A1=Hello\tB1=42',extract_text(path)[0])
    def test_write_requires_approval_then_backup(self):
        job=self.job(); self.store.await_action=lambda *a: {'approved':False}
        result=self.store.execute(job,'write_file',{'path':'a.txt','text':'first'},self.store.data['settings'])
        self.assertEqual(result['status'],'rejected')
        self.assertFalse((pathlib.Path(self.store.project(self.pid)['workspace'])/'a.txt').exists())
        self.store.await_action=lambda *a: {'approved':True}
        self.store.execute(job,'write_file',{'path':'a.txt','text':'first'},self.store.data['settings'])
        self.store.execute(job,'write_file',{'path':'a.txt','text':'second'},self.store.data['settings'])
        backups=list((self.store.root/'projects'/self.pid/'backups').iterdir()); self.assertEqual(backups[0].read_text(),'first')
    def test_offline_blocks_network_tools_and_shell(self):
        for name in ['web_search','browser_open','browser_read'] + ([] if offline_shell_available() else ['run_command']):
            with self.assertRaises(ValueError): self.store.execute(self.job(),name,{},self.store.data['settings'])
    def test_command_and_reject(self):
        settings={**self.store.data['settings'],'mode':'internet'}
        self.store.await_action=lambda *a: {'approved':True}
        result=self.store.execute(self.job(),'run_command',{'command':'printf command_ok'},settings)
        self.assertEqual(result['output'],'command_ok'); self.assertEqual(result['exitCode'],0)
    def test_background_command_does_not_hold_pipe(self):
        settings={**self.store.data['settings'],'mode':'internet'}
        self.store.await_action=lambda *a: {'approved':True}
        started=time.monotonic()
        result=self.store.execute(self.job(),'run_command',{'command':'sleep 10 & printf done'},settings)
        self.assertLess(time.monotonic()-started,3)
        self.assertEqual(result['output'],'done')
    def test_summary_preserves_original(self):
        jid=self.store.start(self.pid,self.cid,'Original'); self.wait(jid)
        old=json.dumps(self.store.chat(self.pid,self.cid))
        jid=self.store.start(self.pid,self.cid,'',True); self.wait(jid)
        self.assertEqual(json.dumps(self.store.chat(self.pid,self.cid)),old)
        self.assertEqual(len(self.store.project(self.pid)['chats']),2)
    def test_context_overflow_is_explicit(self):
        self.store.update_settings({'contextLimit':1024})
        with self.assertRaises(ValueError): self.store.start(self.pid,self.cid,'x'*10000)
        self.assertEqual(self.store.chat(self.pid,self.cid)['messages'][-1]['role'],'user')
    def test_stop_interrupts_stream(self):
        FakeModel.response_mode='slow'; jid=self.store.start(self.pid,self.cid,'slow')
        deadline=time.monotonic()+3
        while not self.store.chat(self.pid,self.cid)['messages'][-1].get('content') and time.monotonic()<deadline: time.sleep(.02)
        time.sleep(.1); self.store.stop(); deadline=time.monotonic()+2
        while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.02)
        self.assertEqual(self.store.jobs[jid]['status'],'stopped')
    def test_tools_can_be_disabled(self):
        self.store.update_settings({'toolsEnabled':False})
        jid=self.store.start(self.pid,self.cid,'plain chat'); self.wait(jid)
        self.assertNotIn('tools',FakeModel.bodies[-1])
    def test_server_auth_and_origin(self):
        srv=serve(self.root/'http','a'*32); thread=threading.Thread(target=srv.serve_forever,daemon=True); thread.start()
        base=f'http://127.0.0.1:{srv.server_address[1]}'
        try:
            for headers in [{},{'X-App-Token':'a'*32,'Origin':'https://evil.example'}]:
                with self.assertRaises(urllib.error.HTTPError) as cm: urllib.request.urlopen(urllib.request.Request(base+'/state',headers=headers))
                self.assertEqual(cm.exception.code,401)
            with urllib.request.urlopen(urllib.request.Request(base+'/state',headers={'X-App-Token':'a'*32})) as r:
                self.assertIn('projects',json.load(r))
        finally: srv.shutdown(); srv.server_close()

if __name__=='__main__': unittest.main(verbosity=2)
