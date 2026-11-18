import json, os, pathlib, struct, subprocess, sys, tempfile, threading, time, unittest
from unittest.mock import patch
from test_core import Store
from core import available_tools
import local_images

class LocalImageTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)
        self.store=Store(self.root/'data'); self.addCleanup(self.store.local.close)
        self.pid=self.store.data['projects'][0]['id']; self.cid=self.store.project(self.pid)['chats'][0]['id']
        self.model=self.root/'image.gguf'; self.model.write_bytes(b'GGUF'+struct.pack('<I',3)+b'fixture')
        self.settings={**self.store.data['settings'],'imageEnabled':True,'imageProvider':'local','imageLocalModel':str(self.model),'mode':'offline'}
        self.script=self.root/'engine.py'; self.script.write_text('import sys,pathlib\np=pathlib.Path(sys.argv[sys.argv.index("-o")+1]); p.write_bytes(b"\\x89PNG\\r\\n\\x1a\\nfixture")\n')
        self.job={'id':'test','projectID':self.pid,'stop':threading.Event(),'directImage':True}
        self.commands=[]; self.children=[]
    def runner(self):
        import contextlib
        stack=contextlib.ExitStack()
        stack.enter_context(patch('local_images.runtime_binary',return_value=self.script))
        stack.enter_context(patch('local_images.platform.system',return_value='Darwin'))
        stack.enter_context(patch('local_images.platform.mac_ver',return_value=('26.6',(),'')))
        original=pathlib.Path.is_file
        stack.enter_context(patch.object(pathlib.Path,'is_file',lambda p: True if str(p)=='/usr/bin/sandbox-exec' else original(p)))
        stack.enter_context(patch('local_images.subprocess.check_output',return_value=b'VirtualMac2,1'))
        launch=subprocess.Popen
        def invoke(command,**kwargs):
            self.commands.append(command)
            child=launch([sys.executable,str(self.script)]+command[4:],**kwargs)
            self.children.append(child); return child
        stack.enter_context(patch('local_images.subprocess.Popen',side_effect=invoke))
        return stack
    def test_offline_dispatch_artifact_no_network_and_sandbox(self):
        self.assertIn('generate_image',[t['function']['name'] for t in available_tools(self.settings)])
        with self.runner(), patch('image_generation.request_json') as network, patch.object(self.store.local,'close') as close:
            result=self.store.execute(self.job,'generate_image',{'prompt':'a tree'},self.settings)
            network.assert_not_called(); close.assert_called_once()
        self.assertEqual(result['provider'],'local')
        self.assertTrue(pathlib.Path(self.store.artifact_path(self.pid,result['path'])).is_file())
        self.assertIn('(deny network*)',self.commands[0][2])
        self.assertFalse(list(pathlib.Path(self.store.project(self.pid)['workspace']).glob('.inij-image-*')))
    def test_cancel_terminates_real_process_and_cleans_partial(self):
        self.script.write_text('import time\ntime.sleep(60)\n')
        with self.runner(), patch('image_generation.request_json') as network:
            timer=threading.Timer(.3,self.job['stop'].set); timer.start()
            try:
                with self.assertRaises(InterruptedError): self.store.execute(self.job,'generate_image',{'prompt':'a tree'},self.settings)
            finally: timer.cancel()
            network.assert_not_called()
        self.assertIsNotNone(self.children[0].poll())
        self.assertFalse(list(pathlib.Path(self.store.project(self.pid)['workspace']).iterdir()))
    def test_timeout_and_failure_are_not_success(self):
        self.script.write_text('import time\ntime.sleep(60)\n')
        with self.runner(), patch('local_images.TIMEOUT',.1):
            with self.assertRaises(TimeoutError): self.store.execute(self.job,'generate_image',{'prompt':'a tree'},self.settings)
        self.assertIsNotNone(self.children[0].poll())
        self.script.write_text('import sys\nprint("incompatible checkpoint")\nsys.exit(2)\n')
        with self.runner():
            with self.assertRaisesRegex(ValueError,'код 2'): self.store.execute(self.job,'generate_image',{'prompt':'a tree'},self.settings)
        self.assertFalse(list(pathlib.Path(self.store.project(self.pid)['workspace']).iterdir()))
    def test_settings_persist_and_bad_values_rejected(self):
        self.store.update_settings({**self.settings,'imageSteps':1,'imageCFG':1,'imageCompute':'cpu'})
        restored=Store(self.store.root); self.addCleanup(restored.local.close)
        self.assertEqual(restored.data['settings']['imageLocalModel'],str(self.model))
        for values in ({'imageWidth':999},{'imageSteps':0},{'imageCFG':99},{'imageProvider':'anything'},{'imageCompute':'remote'}):
            with self.assertRaises(ValueError): self.store.update_settings(values)
    def test_reject_text_gguf_and_split_safetensors(self):
        self.model.write_bytes(b'GGUF'+struct.pack('<I',3)+b'token_embd.weight')
        with self.assertRaisesRegex(ValueError,'текстовая'): local_images.model_file(str(self.model))
        safefile=self.root/'unet.safetensors'; header=json.dumps({'conv_in.weight':{}}).encode()
        safefile.write_bytes(struct.pack('<Q',len(header))+header)
        with self.assertRaisesRegex(ValueError,'полный SD'): local_images.model_file(str(safefile))
        with self.assertRaises(ValueError): local_images.model_file('')
    def test_direct_job_does_not_require_text_model_and_survives_restore(self):
        self.store.update_settings(self.settings)
        with self.runner(), patch('image_generation.request_json') as network:
            jid=self.store.start_image(self.pid,self.cid,'a tree')
            deadline=time.monotonic()+5
            while self.store.jobs[jid]['status']=='running' and time.monotonic()<deadline: time.sleep(.05)
            self.assertEqual(self.store.jobs[jid]['status'],'done',self.store.jobs[jid])
            network.assert_not_called()
        restored=Store(self.store.root); self.addCleanup(restored.local.close)
        messages=restored.snapshot()['projects'][0]['chats'][0]['messages']
        artifacts=[a for m in messages for a in m.get('artifacts',[])]
        self.assertEqual(len(artifacts),1)
        self.assertEqual(messages[-1]['name'],'generate_image')
        self.assertEqual(json.loads(messages[-1]['content'])['provider'],'local')
        self.assertFalse(restored.data['settings']['model'])
    def test_restart_repairs_interrupted_image_tool_chain(self):
        self.store.chat(self.pid,self.cid)['messages'].append({'role':'assistant','content':'','tool_calls':[{'id':'interrupted','type':'function','function':{'name':'generate_image','arguments':'{}'}}]})
        self.store.save()
        restored=Store(self.store.root); self.addCleanup(restored.local.close)
        last=restored.chat(self.pid,self.cid)['messages'][-1]
        self.assertEqual(last['tool_call_id'],'interrupted')
        self.assertIn('error',json.loads(last['content']))
        self.assertNotIn('artifacts',restored.snapshot()['projects'][0]['chats'][0]['messages'][-1])
    def test_cloud_offline_remains_denied(self):
        with patch('image_generation.request_json') as network:
            with self.assertRaises(ValueError): self.store.execute(self.job,'generate_image',{'prompt':'x'},{**self.settings,'imageProvider':'cloud'})
            network.assert_not_called()
    def test_approval_rejection_never_starts_engine(self):
        self.job.pop('directImage')
        self.store.await_action=lambda *args:{'approved':False}
        with self.runner():
            self.assertEqual(self.store.execute(self.job,'generate_image',{'prompt':'x'},self.settings),{'status':'rejected'})
        self.assertEqual(self.children,[])

if __name__=='__main__': unittest.main()
