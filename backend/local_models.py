"""Bundled llama.cpp lifecycle and resumable Hugging Face GGUF library.
No shell commands, remote code, or externally installed inference application.
"""
import atexit, hashlib, json, os, pathlib, re, secrets, shutil, socket, struct
import subprocess, threading, time, urllib.parse, urllib.request

HF='https://huggingface.co'

def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'PersonalAssistant/0.3'}),timeout=30) as r:
        return json.load(r)

def repo_id(value):
    if not re.fullmatch(r'[\w.-]+/[\w.-]+',value): raise ValueError('Нужен идентификатор author/model из Hugging Face')
    return value

def gguf_info(path):
    p=pathlib.Path(path).expanduser().resolve()
    if not p.is_file() or p.suffix.lower()!='.gguf': raise ValueError('Выбери существующий файл .gguf')
    with p.open('rb') as f:
        header=f.read(8)
    if len(header)!=8 or header[:4]!=b'GGUF' or struct.unpack('<I',header[4:])[0] not in (2,3):
        raise ValueError('Файл не является поддерживаемым GGUF v2/v3')
    size=p.stat().st_size
    return {'path':str(p),'name':p.stem,'size':size}

class LocalModels:
    def __init__(self,root):
        self.root=pathlib.Path(root); self.folder=self.root/'models'; self.folder.mkdir(exist_ok=True)
        self.lock=threading.RLock(); self.process=None; self.log=None; self.port=0
        self.key=secrets.token_hex(32); self.generation=0; self.loaded_context=0
        self.state={'status':'idle','path':'','error':''}; self.downloads={}; self.known=[]
        self.index=self.root/'model-library.json'
        try:
            saved=json.loads(self.index.read_text()); self.known=saved.get('known',[])
            for d in saved.get('downloads',[]):
                d.pop('_active',None)
                if d['status'] in ('downloading','verifying'): d['status']='paused'
                self.downloads[d['id']]=d
        except (OSError,ValueError): pass
        atexit.register(self.close)
    def persist(self):
        with self.lock:
            tmp=self.index.with_suffix('.tmp')
            tmp.write_text(json.dumps({'known':self.known,'downloads':list(self.downloads.values())},ensure_ascii=False))
            os.replace(tmp,self.index)
    def snapshot(self):
        with self.lock: return dict(self.state),[dict(d) for d in self.downloads.values()]
    def library(self):
        paths=set(self.known)|{str(p) for p in self.folder.rglob('*.gguf')}
        out=[]
        for path in sorted(paths):
            try: out.append(gguf_info(path))
            except ValueError: pass
        return out
    def close(self):
        with self.lock:
            self.generation+=1
            if self.process is not None:
                self.process.terminate()
                try: self.process.wait(timeout=5)
                except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
                self.process=None
            if self.log: self.log.close(); self.log=None
            self.state={'status':'idle','path':'','error':''}; self.port=0
    def load(self,path,context=8192):
        info=gguf_info(path); path=info['path']
        try: memory=os.sysconf('SC_PAGE_SIZE')*os.sysconf('SC_PHYS_PAGES')
        except (ValueError,OSError): memory=0
        # macOS sysconf may not expose PHYS_PAGES; sysctl provides physical RAM.
        if not memory and os.uname().sysname=='Darwin':
            memory=int(subprocess.check_output(['/usr/sbin/sysctl','-n','hw.memsize']))
        if memory and info['size']>memory*.85: raise ValueError('Файл модели слишком велик для памяти Mac. Выбери меньшую модель или квантизацию.')
        with self.lock:
            if self.state['status'] in ('loading','ready') and self.state['path']==path and self.loaded_context==context:
                if self.state['status']=='loading' or (self.process is not None and self.process.poll() is None): return
            self.close(); self.loaded_context=context; token=self.generation
            if path not in self.known: self.known.append(path)
            self.load_started=time.monotonic()
            self.persist(); self.state={'status':'loading','path':path,'error':'','size':info['size']}
            threading.Thread(target=self._load,args=(path,context,token),daemon=True).start()
    def _load(self,path,context,token):
        try:
            binary=pathlib.Path(__file__).resolve().parent.parent/'llama'/'llama-server'
            if not binary.is_file(): raise ValueError('Встроенный движок отсутствует. Переустанови полный дистрибутив приложения.')
            with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
            with self.lock:
                if token!=self.generation:return
                self.log=(self.root/'model-runtime.log').open('wb')
                args=[str(binary),'-m',path,'--host','127.0.0.1','--port',str(port),'--api-key',self.key,
                      '-c',str(context),'-ngl','99','--parallel','1','--jinja','--alias','local-model','--no-webui']
                self.process=subprocess.Popen(args,stdout=self.log,stderr=subprocess.STDOUT,cwd=str(self.root))
                proc=self.process; self.port=port
            for _ in range(900):
                with self.lock:
                    if token!=self.generation:return
                if proc.poll() is not None:
                    tail=(self.root/'model-runtime.log').read_text(errors='replace')[-1800:]
                    raise ValueError('Не удалось загрузить модель: архитектура/файл не поддержаны или недостаточно памяти. '+tail[-700:])
                try:
                    req=urllib.request.Request(f'http://127.0.0.1:{port}/health',headers={'Authorization':'Bearer '+self.key})
                    with urllib.request.urlopen(req,timeout=1) as r:
                        if r.status==200:
                            with self.lock:
                                if token==self.generation:self.state.update(status='ready',error='',loadSeconds=time.monotonic()-self.load_started)
                            return
                except (OSError,ValueError):pass
                time.sleep(.5)
            raise ValueError('Загрузка модели превысила 450 секунд. Попробуй меньшую модель/контекст.')
        except Exception as e:
            with self.lock:
                if token==self.generation:
                    self.close(); self.state={'status':'error','path':path,'error':str(e)[:1000]}
    def endpoint(self,path,context,stop):
        self.load(path,context)
        for _ in range(4600):
            if stop.is_set(): raise InterruptedError('Остановлено')
            with self.lock:
                if self.state['status']=='ready':
                    if self.process.poll() is not None: raise ValueError('Движок модели завершился; загрузи модель заново.')
                    return f'http://127.0.0.1:{self.port}/v1',self.key
                if self.state['status']=='error': raise ValueError(self.state['error'])
                if self.state['status']=='idle': raise ValueError('Модель выгружена')
            time.sleep(.1)
        raise ValueError('Модель не готова')
    def search(self,query):
        args=urllib.parse.urlencode({'search':query[:200],'filter':'gguf','sort':'downloads','direction':-1,'limit':30})
        data=fetch(HF+'/api/models?'+args)
        return [{'id':v['id'],'downloads':v.get('downloads',0),'likes':v.get('likes',0)} for v in data]
    def files(self,repo):
        repo=repo_id(repo); data=fetch(HF+'/api/models/'+repo+'?blobs=true')
        return [{'name':v['rfilename'],'size':v.get('size') or v.get('lfs',{}).get('size',0),
                 'sha256':v.get('lfs',{}).get('sha256','')} for v in data.get('siblings',[]) if v['rfilename'].lower().endswith('.gguf')]
    def start_download(self,repo,file):
        repo=repo_id(repo)
        if not file.lower().endswith('.gguf') or any(v in ('','..','.') for v in file.split('/')) or file.startswith('/') or '\\' in file:
            raise ValueError('Некорректное имя GGUF')
        options=self.files(repo); item=next((v for v in options if v['name']==file),None)
        if not item: raise ValueError('Файл не найден в репозитории')
        # Split GGUF must be downloaded as a complete set, not a deceptively usable first shard.
        if re.search(r'-\d{5}-of-\d{5}\.gguf$',file): raise ValueError('Разделённые GGUF пока выбирай через «Обзор…» после загрузки всех частей в одну папку. В Explore выбери цельный GGUF.')
        ident=hashlib.sha256((repo+'/'+file).encode()).hexdigest()[:20]
        with self.lock:
            if ident in self.downloads:
                if self.downloads[ident]['status']=='complete':return ident
                self.control(ident,'resume');return ident
            if item['size'] and shutil.disk_usage(self.folder).free<item['size']+1024**3: raise ValueError('Недостаточно свободного места для модели')
            dest=self.folder/ident/pathlib.Path(file).name; dest.parent.mkdir(exist_ok=True)
            self.downloads[ident]={'id':ident,'repo':repo,'file':file,'status':'paused','bytes':0,'total':item['size'],'path':str(dest),'error':'','sha256':item['sha256']}
            self.control(ident,'resume')
        return ident
    def control(self,ident,action):
        with self.lock:
            d=self.downloads[ident]
            if action=='pause':
                if d['status']=='downloading':d['status']='paused'
            elif action=='cancel':
                if d['status']=='downloading': d['status']='cancelling'
                else:
                    pathlib.Path(d['path']+'.part').unlink(missing_ok=True);d.update(status='cancelled',bytes=0)
            elif action=='resume':
                if d['status'] in ('complete','downloading','verifying','cancelling'):return
                if d.get('_active'):return
                d.update(status='downloading',error='',_active=True)
                threading.Thread(target=self._download,args=(ident,),daemon=True).start()
            else: raise ValueError('Неизвестное действие загрузки')
            self.persist()
    def _download(self,ident):
        d=self.downloads[ident]; part=pathlib.Path(d['path']+'.part')
        try:
            offset=part.stat().st_size if part.exists() else 0
            url=HF+'/'+d['repo']+'/resolve/main/'+urllib.parse.quote(d['file'],safe='/')
            headers={'User-Agent':'PersonalAssistant/0.3'}
            if offset:headers['Range']=f'bytes={offset}-'
            with urllib.request.urlopen(urllib.request.Request(url,headers=headers),timeout=30) as r:
                if offset and r.status!=206:offset=0
                length=int(r.headers.get('Content-Length',0));d['total']=d['total'] or length+offset
                d['bytes']=offset
                with part.open('ab' if offset else 'wb') as out:
                    while d['status']=='downloading':
                        chunk=r.read1(256*1024)
                        if not chunk:break
                        out.write(chunk);d['bytes']+=len(chunk)
            if d['status']=='cancelling':part.unlink(missing_ok=True);d.update(status='cancelled',bytes=0);return
            if d['status']!='downloading':return
            if d['total'] and part.stat().st_size!=d['total']:raise ValueError('Загрузка неполная; нажми «Продолжить»')
            d['status']='verifying'
            if d['sha256']:
                h=hashlib.sha256()
                with part.open('rb') as f:
                    for chunk in iter(lambda:f.read(4*1024*1024),b''):h.update(chunk)
                if h.hexdigest()!=d['sha256']:
                    part.unlink(missing_ok=True);raise ValueError('Контрольная сумма не совпала. Загрузи файл снова.')
            with part.open('rb') as f:
                if f.read(4)!=b'GGUF':raise ValueError('Скачан не GGUF')
            os.replace(part,d['path']);gguf_info(d['path']);d['status']='complete'
        except Exception as e:d.update(status='error',error=str(e)[:500])
        finally:
            d.pop('_active',None);self.persist()
