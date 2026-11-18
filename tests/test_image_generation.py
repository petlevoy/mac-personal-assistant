import base64, io, json, pathlib, tempfile, threading, unittest
from unittest.mock import patch
from test_core import Store
from core import available_tools

class ImageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store=Store(pathlib.Path(self.temp.name)/'data')
        self.pid=self.store.data['projects'][0]['id']
        self.job={'projectID':self.pid,'stop':threading.Event()}
        self.settings={**self.store.data['settings'],'mode':'internet','imageEnabled':True,'imageProvider':'cloud','imageBaseURL':'https://example.com/v1','imageModel':'gpt-image-test'}
        self.store.await_action=lambda *args: {'approved':True}
    def test_independent_key_attachment_and_persistence(self):
        self.store.secrets={'image':'image-secret','model':'chat-secret'}
        payload=b'\x89PNG\r\n\x1a\nmock'
        with patch('image_generation.request_json',return_value=io.BytesIO(json.dumps({'data':[{'b64_json':base64.b64encode(payload).decode()}]}).encode())) as request:
            result=self.store.execute(self.job,'generate_image',{'prompt':'A tree'},self.settings)
        self.assertEqual(request.call_args.kwargs['key'],'image-secret')
        self.assertNotIn('response_format',request.call_args.args[1])
        path=pathlib.Path(self.store.artifact_path(self.pid,result['path']))
        self.assertEqual(path.read_bytes(),payload)
        self.store.project(self.pid)['chats'][0]['messages'].append({'role':'tool','name':'generate_image','content':json.dumps(result)})
        self.assertEqual(self.store.snapshot()['projects'][0]['chats'][0]['messages'][0]['artifacts'][0]['path'],result['path'])
        self.store.update_settings(self.settings)
        restored=Store(self.store.root)
        self.assertEqual(restored.data['settings']['imageModel'],'gpt-image-test')
        self.assertEqual(restored.secrets,{})
        self.assertNotIn('image-secret',self.store.path.read_text())
    def test_offline_rejection_and_cancellation_never_call_provider(self):
        with patch('image_generation.request_json') as request:
            with self.assertRaises(ValueError): self.store.execute(self.job,'generate_image',{'prompt':'x'},{**self.settings,'mode':'offline'})
            self.store.await_action=lambda *a: {'approved':False}
            self.assertEqual(self.store.execute(self.job,'generate_image',{'prompt':'x'},self.settings)['status'],'rejected')
            self.store.await_action=lambda *a: {'approved':True}
            self.job['stop'].set()
            with self.assertRaises(InterruptedError): self.store.execute(self.job,'generate_image',{'prompt':'x'},self.settings)
            request.assert_not_called()
        self.assertNotIn('generate_image',[t['function']['name'] for t in available_tools({'mode':'offline'})])
    def test_bad_output_no_file_and_no_secret_echo(self):
        with patch('image_generation.request_json',side_effect=ValueError('image-secret')):
            with self.assertRaises(ValueError) as error: self.store.execute(self.job,'generate_image',{'prompt':'x'},self.settings)
        self.assertNotIn('image-secret',str(error.exception))
        self.assertFalse(list(pathlib.Path(self.store.project(self.pid)['workspace']).glob('generated-*')))
