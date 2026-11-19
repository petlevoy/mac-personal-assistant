import json, pathlib, sys, tempfile, threading, time, unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'backend'))
from core import Store
from engines import ADAPTERS, rss_bytes

class EngineTests(unittest.TestCase):
    def test_protocols_and_tool_fragments(self):
        s={'model':'m','temperature':.4,'contextLimit':1024,'_maxOutputTokens':20}
        path,b=ADAPTERS['local'].request(s,[],[])
        self.assertEqual(path,'/chat/completions'); self.assertFalse(b['chat_template_kwargs']['enable_thinking'])
        self.assertEqual(b['max_tokens'],20)
        path,b=ADAPTERS['ollama'].request(s,[],None)
        self.assertEqual(path,'/api/chat'); self.assertEqual(b['options']['num_predict'],20); self.assertNotIn('tools',b)
        calls={}
        for args in ('{"x":','1}'):
            ADAPTERS['openai'].chunk('data: '+json.dumps({'choices':[{'delta':{'tool_calls':[{'index':0,'function':{'arguments':args}}]}}]}),calls)
        self.assertEqual(calls[0]['function']['arguments'],'{"x":1}')
        c=ADAPTERS['ollama'].chunk(json.dumps({'done':True,'eval_count':10,'prompt_eval_count':3,'eval_duration':2000000000}),{})
        self.assertEqual(c['evalSeconds'],2); self.assertEqual(c['usage']['completion_tokens'],10)
        self.assertIsNone(ADAPTERS['openai'].chunk(': ping',{}))
        self.assertTrue(ADAPTERS['openai'].chunk('data: [DONE]',{})['done'])
    def test_queue_fifo_cancel_and_settings_guard(self):
        with tempfile.TemporaryDirectory() as tmp:
            st=Store(tmp); st.update_settings({'provider':'ollama','model':'mock'})
            pid=st.data['projects'][0]['id']; chats=[st.create_chat(pid) for _ in range(4)]
            gate=threading.Event(); entered=threading.Event(); order=[]
            def fake(s,m,stop,callback,tools_enabled=True):
                order.append(m[-1]['content']); entered.set()
                while not gate.wait(.01):
                    if stop.is_set(): raise InterruptedError()
                callback('answer'); return 'answer',[]
            st.stream_model=fake
            first=st.start(pid,chats[0],'one'); self.assertTrue(entered.wait(2))
            second=st.start(pid,chats[1],'two'); third=st.start(pid,chats[2],'three')
            self.assertEqual(st.jobs[second]['status'],'queued')
            with self.assertRaises(ValueError): st.start(pid,chats[0],'duplicate')
            with self.assertRaises(ValueError): st.update_settings({'temperature':1})
            with self.assertRaises(ValueError): st.engine_action('unload')
            st.stop(second)
            fourth=st.start(pid,chats[3],'four')
            gate.set(); worker=st.worker; worker.join(5)
            self.assertFalse(worker.is_alive()); self.assertEqual(order,['one','three','four'])
            self.assertEqual(st.jobs[second]['status'],'stopped')
            self.assertEqual(st.jobs[fourth]['status'],'done')
    def test_remote_memory_unavailable_and_api_lifecycle(self):
        with tempfile.TemporaryDirectory() as tmp:
            st=Store(tmp); st.update_settings({'provider':'openai','baseURL':'http://127.0.0.1:8000/v1','model':'m'})
            self.assertIsNone(st.engine.snapshot()['rssBytes'])
            self.assertFalse(st.engine.snapshot()['canUnload'])
            with self.assertRaisesRegex(ValueError,'сервер'): st.engine_action('unload')
        self.assertIsNone(rss_bytes(None))
    def test_stream_metrics_actual_usage_only(self):
        class Response:
            def __init__(self,usage): self.usage=usage
            def __enter__(self): return self
            def __exit__(self,*a): pass
            def __iter__(self):
                time.sleep(.01)
                yield b'data: {"choices":[{"delta":{"content":"abc"}}]}\n'
                if self.usage: yield b'data: {"usage":{"prompt_tokens":3,"completion_tokens":2},"choices":[]}\n'
                yield b'data: [DONE]\n'
        with tempfile.TemporaryDirectory() as tmp:
            st=Store(tmp); st.update_settings({'provider':'openai','baseURL':'http://127.0.0.1:8000/v1','model':'m'})
            for usage in (True,False):
                with patch('core.request_json',return_value=Response(usage)):
                    text,calls=st.stream_model(st.data['settings'],[],threading.Event(),lambda _:None)
                metrics=st.engine.snapshot()['metrics']
                self.assertEqual(text,'abc'); self.assertGreater(metrics['firstTextSeconds'],0)
                self.assertEqual(metrics['rateBasis'],'whole_request')
                if usage:
                    self.assertEqual(metrics['outputTokens'],2); self.assertGreater(metrics['tokensPerSecond'],0)
                else:
                    self.assertIsNone(metrics['outputTokens']); self.assertIsNone(metrics['tokensPerSecond'])
    def test_ollama_lifecycle_and_active_cancel(self):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            st=Store(tmp); st.update_settings({'provider':'ollama','model':'mock'})
            for action,keep in (('load','5m'),('unload',0)):
                with patch('core.request_json',return_value=io.BytesIO(b'{"done":true}')) as req:
                    st.engine_action(action)
                    self.assertEqual(req.call_args.args[1]['keep_alive'],keep)
                self.assertEqual(st.engine.external['status'],'ready' if action=='load' else 'idle')
            pid=st.data['projects'][0]['id']; cid=st.create_chat(pid)
            entered=threading.Event()
            def wait(s,m,stop,callback,tools_enabled=True):
                entered.set(); stop.wait(3); raise InterruptedError()
            st.stream_model=wait
            jid=st.start(pid,cid,'cancel me'); self.assertTrue(entered.wait(2))
            st.stop(jid); worker=st.worker; worker.join(4)
            self.assertEqual(st.jobs[jid]['status'],'stopped')
