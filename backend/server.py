#!/usr/bin/env python3
import argparse, json, os, pathlib, secrets, shutil, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
from core import Store, MAX_FILE, extract_text, context_size, uid

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send_json(self,value,status=200):
        data=json.dumps(value,ensure_ascii=False).encode()
        self.send_response(status); self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(data))); self.send_header('Cache-Control','no-store'); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError): pass
    def authorized(self):
        return not self.headers.get('Origin') and secrets.compare_digest(self.headers.get('X-App-Token',''),self.server.token)
    def do_GET(self):
        if not self.authorized(): return self.send_json({'error':'Unauthorized'},401)
        try:
            if self.path=='/state': return self.send_json(self.server.store.snapshot())
            if self.path=='/local/library': return self.send_json({'models':self.server.store.model_library()})
            if self.path=='/models': return self.send_json({'models':self.server.store.models()})
            self.send_json({'error':'Not found'},404)
        except Exception as e: self.send_json({'error':str(e)[:600]},400)
    def do_POST(self):
        if not self.authorized(): return self.send_json({'error':'Unauthorized'},401)
        try:
            n=int(self.headers.get('Content-Length','0'))
            if n<0 or n>16*1024*1024: raise ValueError('Request too large')
            data=json.loads(self.rfile.read(n) or b'{}'); s=self.server.store
            if self.path=='/local/load':
                s.idle(); s.local.load(data['path'],s.data['settings']['contextLimit'])
                s.update_settings({'provider':'local','model':str(pathlib.Path(data['path']).expanduser().resolve()),'mode':'internet' if s.data['settings']['mode']=='cloud' else s.data['settings']['mode']})
            elif self.path=='/models/delete-preview':
                from model_deletion import preview
                return self.send_json(preview(s,data['path']))
            elif self.path=='/models/delete':
                from model_deletion import delete
                return self.send_json(delete(s,data['token']))
            elif self.path=='/local/unload': s.idle(); s.local.close()
            elif self.path=='/explore/search': return self.send_json({'models':s.local.search(str(data.get('query','')))})
            elif self.path=='/explore/files': return self.send_json({'files':s.local.files(data['repo']),'repo':data['repo']})
            elif self.path=='/downloads/start': return self.send_json({'id':s.local.start_download(data['repo'],data['file'])})
            elif self.path=='/downloads/control': s.local.control(data['id'],data['action'])
            elif self.path=='/settings': s.update_settings(data)
            elif self.path=='/keys':
                for key in ('model','brave','tavily','serper','image'):
                    if key in data: s.secrets[key]=str(data[key])
            elif self.path=='/project': return self.send_json({'id':s.create_project(data['name'])})
            elif self.path=='/chat': return self.send_json({'id':s.create_chat(data['projectID'])})
            elif self.path=='/project/update':
                with s.lock:
                    p=s.project(data['projectID'])
                    if 'memory' in data: p['memory']=str(data['memory'])[:60000]
                    if 'workspace' in data:
                        folder=pathlib.Path(data['workspace']).resolve()
                        if not folder.is_dir(): raise ValueError('Папка не существует')
                        p['workspace']=str(folder)
                    s.save()
            elif self.path=='/profile': return self.send_json(s.profile_save(data))
            elif self.path=='/profile/delete': return self.send_json(s.profile_delete(data['id']))
            elif self.path=='/thermal':
                s.thermal['state']=max(0,min(int(data.get('state',0)),3))
            elif self.path=='/profile/restore': return self.send_json(s.profile_restore(data['id'],data['versionID']))
            elif self.path=='/chat/change': return self.send_json(s.change_chat(data))
            elif self.path=='/restore': return self.send_json(s.restore_backup(data['path']))
            elif self.path=='/mcp/save': return self.send_json(s.mcp_save(data))
            elif self.path=='/mcp/remove':
                s.idle(); s.data['mcp']=[v for v in s.data.get('mcp',[]) if v['id']!=data['id']]; s.save()
            elif self.path=='/chat/config':
                with s.lock:
                    c=s.chat(data['projectID'],data['chatID'])
                    if 'skillIDs' in data: c['skillIDs']=data['skillIDs']
                    if 'profileID' in data: c['profileID']=data['profileID']
                    s.save()
            elif self.path=='/skill': return self.send_json({'id':s.import_skill(data['projectID'],data['path'])})
            elif self.path=='/skill/remove':
                with s.lock:
                    p=s.project(data['projectID']); p['skills']=[x for x in p['skills'] if x['id']!=data['id']]
                    for c in p['chats']: c['skillIDs']=[v for v in c['skillIDs'] if v!=data['id']]
                    s.save() # Files kept for backup; no silent destructive delete.
            elif self.path=='/context':
                m=s.prepare_messages(data['projectID'],data['chatID'])
                return self.send_json({'estimatedTokens':context_size(m,s.data['settings']),'method':'UTF-8 bytes / 4; approximate','messages':m})
            elif self.path=='/image/generate': return self.send_json({'id':s.start_image(data['projectID'],data['chatID'],data['text'])})
            elif self.path=='/send': return self.send_json({'id':s.start(data['projectID'],data['chatID'],data['text'])})
            elif self.path=='/compact': return self.send_json({'id':s.start(data['projectID'],data['chatID'],'',True)})
            elif self.path=='/stop': s.stop()
            elif self.path=='/permissions/reset': s.reset_permissions()
            elif self.path=='/resolve': s.resolve(data['id'],data['response'])
            elif self.path=='/artifact/path': return self.send_json({'path':s.artifact_path(data['projectID'],data['path'])})
            elif self.path=='/attachment':
                source=pathlib.Path(data['path']).resolve()
                if not source.is_file() or source.stat().st_size>MAX_FILE: raise ValueError('Выбери файл до 12 МБ')
                s.project(data['projectID']) # validate project before any write
                folder=s.root/'projects'/data['projectID']/'files'; folder.mkdir(parents=True,exist_ok=True)
                target=folder/(uid()[:8]+'-'+source.name); shutil.copy2(source,target)
                if 'extractedText' in data:
                    text=str(data['extractedText']); truncated=False
                    if len(text)>2_000_000: raise ValueError('Документ больше 2 000 000 символов. Текст не был обрезан.')
                else: text,truncated=extract_text(target)
                return self.send_json({'text':text,'truncated':truncated,'name':source.name,'storedPath':str(target)})
            elif self.path=='/chat/export':
                with s.lock:
                    c=s.chat(data['projectID'],data['chatID'])
                    content=json.dumps(c,ensure_ascii=False,indent=2)
                target=pathlib.Path(data['path']).expanduser()
                target.write_text(content,encoding='utf-8')
                return self.send_json({'path':str(target),'chatID':c['id']})
            elif self.path=='/export': return self.send_json({'path':s.export(data['path'])})
            else: return self.send_json({'error':'Not found'},404)
            self.send_json({'ok':True})
        except Exception as e: self.send_json({'error':str(e)[:600]},400)

def serve(root,token,port=0):
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler)
    server.daemon_threads=True; server.token=token; server.store=Store(root)
    return server
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--data',required=True); parser.add_argument('--ready-file'); args=parser.parse_args()
    token=os.environ.get('MAC_ASSISTANT_TOKEN','')
    if len(token)<24: sys.exit('Missing session authentication token')
    server=serve(args.data,token)
    if args.ready_file:
        from core import atomic_json
        atomic_json(args.ready_file,{'port':server.server_address[1]})
    print(json.dumps({'port':server.server_address[1]}),flush=True)
    import signal, time
    def terminate(signum, frame):
        server.store.stop()
        server.store.local.close()
        time.sleep(.4)
        raise SystemExit(0)
    signal.signal(signal.SIGTERM,terminate)
    server.serve_forever()
