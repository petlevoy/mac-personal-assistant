"""Protocol adapters and observable engine lifecycle. No inferred token/RAM metrics."""
import json, subprocess, time, uuid

class OpenAIAdapter:
    def request(self, s, messages, tools):
        body={'model':s['model'],'messages':messages,'stream':True,'stream_options':{'include_usage':True},'temperature':s['temperature']}
        if tools is not None: body['tools']=tools
        if '_maxOutputTokens' in s: body['max_tokens']=s['_maxOutputTokens']
        return '/chat/completions',body
    def chunk(self, line, calls):
        if not line.startswith('data:'): return None
        line=line[5:].strip()
        if line=='[DONE]': return {'done':True}
        data=json.loads(line)
        if data.get('error'): raise ValueError('Ошибка сервера модели')
        choices=data.get('choices',[]); choice=choices[0] if choices else {}
        delta=choice.get('delta',{})
        for t in delta.get('tool_calls',[]):
            c=calls.setdefault(t.get('index',0),{'id':t.get('id') or str(uuid.uuid4()),'type':'function','function':{'name':'','arguments':''}})
            f=t.get('function',{}); c['function']['name']+=f.get('name',''); c['function']['arguments']+=f.get('arguments','')
        return {'text':delta.get('content') or '', 'reasoning':delta.get('reasoning_content') or delta.get('thinking') or '', 'usage':data.get('usage'),'length':choice.get('finish_reason')=='length'}

class LlamaAdapter(OpenAIAdapter):
    def request(self,s,messages,tools):
        path,body=super().request(s,messages,tools)
        body['chat_template_kwargs']={'enable_thinking':False}
        return path,body

class OllamaAdapter:
    def request(self,s,messages,tools):
        body={'model':s['model'],'messages':messages,'stream':True,'options':{'temperature':s['temperature'],'num_ctx':s['contextLimit']}}
        if tools is not None: body['tools']=tools
        if '_maxOutputTokens' in s: body['options']['num_predict']=s['_maxOutputTokens']
        return '/api/chat',body
    def chunk(self,line,calls):
        data=json.loads(line)
        if data.get('error'): raise ValueError('Ошибка сервера Ollama')
        delta=data.get('message',{})
        for t in delta.get('tool_calls',[]):
            f=t.get('function',{})
            calls[len(calls)]={'id':str(uuid.uuid4()),'type':'function','function':{'name':f.get('name',''),'arguments':json.dumps(f.get('arguments',{}),ensure_ascii=False)}}
        usage=None
        if data.get('done') and 'prompt_eval_count' in data and 'eval_count' in data:
            usage={'prompt_tokens':data['prompt_eval_count'],'completion_tokens':data['eval_count']}
        return {'text':delta.get('content') or '', 'reasoning':delta.get('reasoning_content') or delta.get('thinking') or '', 'usage':usage,'length':data.get('done_reason')=='length', 'evalSeconds':data.get('eval_duration',0)/1e9 if isinstance(data.get('eval_duration'),(int,float)) else None}

ADAPTERS={'local':LlamaAdapter(),'openai':OpenAIAdapter(),'ollama':OllamaAdapter()}

def rss_bytes(process):
    if process is None or process.poll() is not None: return None
    try:
        value=subprocess.check_output(['/bin/ps','-o','rss=','-p',str(process.pid)],timeout=1,text=True).strip()
        return int(value)*1024
    except (OSError,ValueError,subprocess.SubprocessError): return None

class EngineManager:
    def __init__(self,store):
        self.store=store; self.last={}; self.external={'status':'idle','error':'','loadSeconds':None}
    def snapshot(self):
        s=self.store.data['settings']; local=s['provider']=='local'
        state=self.store.local.snapshot()[0] if local else dict(self.external)
        return {'provider':s['provider'],'model':s['model'],'state':state,'metrics':dict(self.last),
                'rssBytes':rss_bytes(self.store.local.process) if local else None,
                'canLoad':s['provider']!='openai','canUnload':s['provider']!='openai'}
    def lifecycle(self,action):
        from core import validate_endpoint,request_json
        s=self.store.data['settings']
        if action not in ('load','unload'): raise ValueError('Неизвестное действие движка')
        if s['provider']=='openai': raise ValueError('Совместимый API не задаёт управление загрузкой. Моделью управляет сервер.')
        if s['provider']=='local':
            if action=='load': self.store.local.load(s['model'],s['contextLimit'])
            else: self.store.local.close()
            return
        base=validate_endpoint(s['baseURL'],s['mode'],s['provider']); start=time.monotonic()
        self.external={'status':'loading' if action=='load' else 'unloading','error':'','loadSeconds':None}
        try:
            with request_json(base+'/api/generate',{'model':s['model'],'stream':False,'keep_alive':'5m' if action=='load' else 0},self.store.secrets.get('model',''),timeout=120) as response:
                data=json.load(response)
                if data.get('error'): raise ValueError('Ollama не выполнила управление моделью')
            self.external={'status':'ready' if action=='load' else 'idle','error':'','loadSeconds':time.monotonic()-start if action=='load' else None}
        except Exception:
            self.external={'status':'error','error':'Не удалось изменить состояние Ollama. Проверь сервер и модель.','loadSeconds':None}
            raise ValueError(self.external['error']) from None
