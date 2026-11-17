"""Bounded MCP stdio client; a fresh approved session per invocation."""
import json,os,queue,signal,subprocess,threading,time,pathlib

def request(server,method,params,stop):
    env={'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin','HOME':str(pathlib.Path.home()),'LANG':'en_US.UTF-8'}
    proc=subprocess.Popen([server['command'],*server['args']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,start_new_session=True)
    incoming=queue.Queue(maxsize=200); deadline=time.monotonic()+45
    def reader():
        try:
            while True:
                line=proc.stdout.readline(1024*1024+1)
                if not line: break
                if len(line)>1024*1024: incoming.put_nowait({'fatal':'MCP ответ больше 1 МБ'}); break
                incoming.put_nowait(json.loads(line))
        except Exception: pass
        finally:
            try: incoming.put_nowait({'fatal':'MCP процесс завершился или нарушил протокол'})
            except queue.Full: pass
    threading.Thread(target=reader,daemon=True).start()
    def send(obj):
        proc.stdin.write((json.dumps(obj)+'\n').encode());proc.stdin.flush()
    def receive(id):
        while time.monotonic()<deadline:
            if stop.is_set(): raise InterruptedError('Остановлено')
            try: value=incoming.get(timeout=.1)
            except queue.Empty: continue
            if 'fatal' in value: raise ValueError(value['fatal'])
            if value.get('id')==id:
                if 'error' in value: raise ValueError('MCP вернул ошибку '+str(value['error'].get('code','')))
                return value.get('result',{})
            if 'id' in value and 'method' in value:
                # No sampling, roots or elicitation implicitly granted to external server.
                send({'jsonrpc':'2.0','id':value['id'],'error':{'code':-32601,'message':'Client method unavailable'}})
        raise TimeoutError('MCP: тайм-аут 45 секунд')
    try:
        send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'PersonalAssistant','version':'0.2'}}})
        receive(1);send({'jsonrpc':'2.0','method':'notifications/initialized'})
        send({'jsonrpc':'2.0','id':2,'method':method,'params':params});return receive(2)
    finally:
        try: os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        proc.wait(timeout=5)
        proc.stdin.close();proc.stdout.close()
