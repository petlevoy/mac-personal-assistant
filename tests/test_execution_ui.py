import json, pathlib, subprocess, sys, threading, unittest
from unittest.mock import patch
from test_core import CoreTests, FakeModel
from core import available_tools, offline_shell_available

class ExecutionTests(CoreTests):
    def test_command_tool_roundtrip(self):
        self.store.update_settings({'mode':'internet'})
        self.store.await_action=lambda *a: {'approved':True}
        original=FakeModel.do_POST
        def response(handler):
            body=json.loads(handler.rfile.read(int(handler.headers['Content-Length'])))
            FakeModel.bodies.append(body)
            handler.send_response(200);handler.end_headers()
            if any(m['role']=='tool' for m in body['messages']):
                result={'message':{'content':'Команда выполнена'},'done':True}
            else:
                result={'message':{'tool_calls':[{'function':{'name':'run_command','arguments':{'command':'printf actual_execution'}}}]},'done':True}
            handler.wfile.write((json.dumps(result)+'\n').encode())
        with patch.object(FakeModel,'do_POST',response):
            jid=self.store.start(self.pid,self.cid,'Выполни команду');self.wait(jid)
        history=self.store.chat(self.pid,self.cid)['messages']
        outputs=[json.loads(m['content']) for m in history if m['role']=='tool']
        self.assertEqual(outputs[-1]['output'],'actual_execution')
        self.assertEqual(outputs[-1]['exitCode'],0)
        self.assertIn('run_command',[x['function']['name'] for x in FakeModel.bodies[0]['tools']])
    def test_rejected_command_has_no_side_effect(self):
        self.store.await_action=lambda *a: {'approved':False}
        target=pathlib.Path(self.store.project(self.pid)['workspace'])/'should-not-exist'
        result=self.store.execute(self.job(),'run_command',{'command':'touch should-not-exist'},{**self.store.data['settings'],'mode':'internet'})
        self.assertEqual(result['status'],'rejected');self.assertFalse(target.exists())
    def test_offline_kernel_network_denial(self):
        if not offline_shell_available(): self.skipTest('macOS sandbox-exec only')
        self.store.await_action=lambda *a: {'approved':True}
        result=self.store.execute(self.job(),'run_command',{'command':'printf local_ok'},self.store.data['settings'])
        self.assertEqual(result['output'],'local_ok');self.assertEqual(result['exitCode'],0)
        command=f'"{sys.executable}" -I -B -c "import socket; socket.create_connection((\'127.0.0.1\',{self.model.server_address[1]}),timeout=2)"'
        result=self.store.execute(self.job(),'run_command',{'command':command},self.store.data['settings'])
        self.assertNotEqual(result['exitCode'],0)
        self.assertTrue('Operation not permitted' in result['output'] or 'PermissionError' in result['output'],result)
    def test_prompts_explain_current_capability(self):
        content=self.store.prepare_messages(self.pid,self.cid)[0]['content']
        self.assertIn('вызови run_command',content)
        self.assertIn('Интернет выключен',content)
        self.store.update_settings({'toolsEnabled':False})
        self.assertIn('Инструменты выключены',self.store.prepare_messages(self.pid,self.cid)[0]['content'])
