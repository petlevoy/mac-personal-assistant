"""Application features; standard library only. No persisted credentials."""
import copy, html, json, os, pathlib, re, shutil, tempfile, time, urllib.parse, zipfile
import xml.etree.ElementTree as ET

class Features:
    def idle(self):
        if getattr(self,'queue',[]) or any(j['status'] in ('running','queued') for j in self.jobs.values()):
            raise ValueError('Сначала останови генерацию')
    def profile_save(self,data):
        from core import uid
        self.idle()
        with self.lock:
            p=next((p for p in self.data['profiles'] if p['id']==data.get('id')),None)
            if p:
                p.setdefault('versions',[]).append({'id':uid(),'time':time.strftime('%Y-%m-%d %H:%M:%S'),'name':p['name'],'prompt':p['prompt']})
                p['versions']=p['versions'][-100:]
                p.update(name=str(data['name'])[:100],prompt=str(data['prompt'])[:30000])
            else:
                p={'id':uid(),'name':str(data['name'])[:100],'prompt':str(data['prompt'])[:30000],'versions':[]}
                self.data['profiles'].append(p)
            self.save(); return {'id':p['id']}
    def profile_delete(self,id):
        from core import atomic_json,uid
        self.idle()
        with self.lock:
            p=next((p for p in self.data['profiles'] if p['id']==id),None)
            if p is None: raise ValueError('Профиль не найден')
            atomic_json(self.root/'archives'/('profile-'+uid()+'.json'),p)
            self.data['profiles']=[v for v in self.data['profiles'] if v['id']!=id]
            if not self.data['profiles']: self.data['profiles']=[{'id':uid(),'name':'Без промпта','prompt':'','versions':[]}]
            replacement=self.data['profiles'][0]['id']
            for project in self.data['projects']:
                for chat in project['chats']:
                    if chat['profileID']==id: chat['profileID']=replacement
            self.save()
            return {'id':replacement}
    def profile_restore(self,id,version):
        p=next(p for p in self.data['profiles'] if p['id']==id)
        v=next(v for v in p.get('versions',[]) if v['id']==version)
        return self.profile_save({'id':id,'name':v['name'],'prompt':v['prompt']})
    def change_chat(self,data):
        self.idle(); pid=data['projectID']; cid=data['chatID']; action=data['action']
        with self.lock:
            c=self.chat(pid,cid)
            # Keep deleted/edited history in local archives, never silently lose it.
            from core import atomic_json,uid
            archive=self.root/'archives'/(uid()+'.json'); atomic_json(archive,c)
            if action=='delete':
                self.project(pid)['chats']=[v for v in self.project(pid)['chats'] if v['id']!=cid]
                if not self.project(pid)['chats']: self.create_chat(pid)
            elif action in ('edit','retry'):
                index=int(data.get('index',-1))
                if action=='retry':
                    index=next((i for i in range(len(c['messages'])-1,-1,-1) if c['messages'][i]['role']=='user'),-1)
                if index<0 or index>=len(c['messages']) or c['messages'][index]['role']!='user': raise ValueError('Выбери сообщение пользователя')
                original=c['messages'][index]
                text=str(data.get('text',original.get('displayText',original['content'])))
                attachments=original.get('attachments')
                if not text.strip() and not attachments: raise ValueError('Пустое сообщение')
                c['messages']=c['messages'][:index]; self.save()
                return {'id':self.start(pid,cid,text,attachments=attachments)}
            else: raise ValueError('Неизвестное действие')
            self.save(); return {'ok':True}
    def restore_backup(self,source):
        from core import uid,atomic_json
        self.idle(); source=pathlib.Path(source)
        if any(d.get('_active') for d in self.local.downloads.values()): raise ValueError('Сначала приостанови загрузки моделей и дождись паузы')
        if source.stat().st_size>256*1024*1024: raise ValueError('Архив больше 256 МБ')
        with tempfile.TemporaryDirectory(dir=self.root.parent,prefix='assistant-restore-') as tmp:
            stage=pathlib.Path(tmp)/'data'; stage.mkdir()
            with zipfile.ZipFile(source) as z:
                items=z.infolist()
                if len(items)>20000 or sum(i.file_size for i in items)>512*1024*1024: raise ValueError('Слишком большой распакованный архив')
                seen=set()
                for info in items:
                    p=pathlib.PurePosixPath(info.filename)
                    if p.is_absolute() or '..' in p.parts or '\\' in info.filename or ':' in info.filename or info.filename in seen:
                        raise ValueError('Небезопасный путь в архиве')
                    seen.add(info.filename)
                    if (info.external_attr>>16)&0o170000==0o120000: raise ValueError('Симлинк в архиве')
                    out=stage.joinpath(*p.parts)
                    if info.is_dir(): out.mkdir(parents=True,exist_ok=True)
                    else:
                        out.parent.mkdir(parents=True,exist_ok=True)
                        with z.open(info) as src, out.open('wb') as dst: shutil.copyfileobj(src,dst)
            data=json.loads((stage/'state.json').read_text())
            if data.get('version')!=1 or not data.get('projects') or not data.get('profiles'): raise ValueError('Неизвестный формат бэкапа')
            from core import validate_endpoint
            s=data['settings']
            if s['provider']!='local': validate_endpoint(s['baseURL'],s['mode'],s['provider'])
            # Validate identifiers before constructing paths. External workspaces are not restored.
            for project in data['projects']:
                pid=project['id']
                if not re.fullmatch(r'[a-zA-Z0-9-]{1,80}',pid): raise ValueError('Неверный ID проекта')
                project['workspace']=str(self.root/'projects'/pid/'files')
                (stage/'projects'/pid/'files').mkdir(parents=True,exist_ok=True)
                for skill in project['skills']:
                    sid=skill['id']
                    if not re.fullmatch(r'[a-zA-Z0-9-]{1,80}',sid): raise ValueError('Неверный ID скилла')
                    skill['folder']=str(self.root/'projects'/pid/'skills'/sid)
                    if not (stage/'projects'/pid/'skills'/sid/'SKILL.md').is_file(): raise ValueError('Нет файла скилла')
                for c in project['chats']:
                    if not isinstance(c.get('messages'),list): raise ValueError('Поврежденная история')
            data['permissions']={'all':False,'tools':[]}
            # MCP servers imported disabled: restore is not permission to run commands.
            for config in data.get('mcp',[]): config['enabled']=False
            atomic_json(stage/'state.json',data)
            backup=self.root.parent/('PersonalAssistant-before-restore-'+uid()+'.zip')
            self.export(backup)
            old=self.root.parent/('assistant-previous-'+uid())
            with self.lock:
                os.replace(self.root,old)
                try: shutil.copytree(stage,self.root)
                except Exception:
                    if self.root.exists(): shutil.rmtree(self.root)
                    os.replace(old,self.root); raise
                # Weights are not in chat backups. Preserve this Mac's existing library without copying GBs.
                self.local.close()
                if (old/'models').exists() and not (self.root/'models').exists(): os.replace(old/'models',self.root/'models')
                if (old/'model-library.json').exists(): shutil.copy2(old/'model-library.json',self.root/'model-library.json')
                from local_models import LocalModels
                self.local=LocalModels(self.root)
                self.data=data; self.jobs={}; self.pending={}; self.responses={}; self.save()
            return {'backup':str(backup),'previousData':str(old),'notice':'Внешние папки отключены; выбери их снова. MCP выключены до явного включения.'}
    def search_web(self,query):
        from core import request_json
        provider=self.data['settings'].get('searchProvider','brave')
        key=self.secrets.get(provider,'')
        if not key: raise ValueError('Добавь ключ '+provider+' в настройках')
        if provider=='brave':
            url='https://api.search.brave.com/res/v1/web/search?'+urllib.parse.urlencode({'q':query,'count':5})
            with request_json(url,headers={'X-Subscription-Token':key}) as r: d=json.load(r)
            return [{'title':v.get('title'),'url':v.get('url'),'description':v.get('description')} for v in d.get('web',{}).get('results',[])]
        if provider=='tavily':
            with request_json('https://api.tavily.com/search',{'query':query,'max_results':5},key=key) as r: d=json.load(r)
            return [{'title':v.get('title'),'url':v.get('url'),'description':v.get('content')} for v in d.get('results',[])]
        if provider=='serper':
            with request_json('https://google.serper.dev/search',{'q':query,'num':5},headers={'X-API-KEY':key}) as r: d=json.load(r)
            return [{'title':v.get('title'),'url':v.get('link'),'description':v.get('snippet')} for v in d.get('organic',[])]
        raise ValueError('Неизвестный поиск')
    def mcp_save(self,config):
        from core import uid
        self.idle()
        name=str(config.get('name','')).strip()
        command=str(config.get('command','')).strip()
        args=config.get('args',[])
        if not name or not command or not isinstance(args,list) or not all(isinstance(a,str) for a in args): raise ValueError('Нужны имя, исполняемый файл и массив аргументов')
        item={'id':config.get('id') or uid(),'name':name[:80],'command':command,'args':args,'enabled':bool(config.get('enabled',True))}
        with self.lock:
            self.data.setdefault('mcp',[])
            self.data['mcp']=[v for v in self.data['mcp'] if v['id']!=item['id']]+[item]; self.save()
        return item
    def mcp_request(self,server,method,params,stop):
        from mcp_client import request
        return request(server,method,params,stop)
    def template_document(self,root,source,destination,values):
        from core import safe_path,MAX_FILE,uid
        source=safe_path(root,source); target=safe_path(root,destination)
        if source.suffix.lower() not in ('.docx','.xlsx') or target.suffix.lower()!=source.suffix.lower(): raise ValueError('Шаблон и результат должны быть DOCX либо XLSX одного типа')
        if source==target: raise ValueError('Сохрани результат отдельно от шаблона')
        if not isinstance(values,dict) or not all(isinstance(k,str) and isinstance(v,str) for k,v in values.items()): raise ValueError('Нужен словарь текстовых значений')
        if source.stat().st_size>MAX_FILE: raise ValueError('Шаблон больше 12 МБ')
        missing=set(values); replaced=0
        target.parent.mkdir(parents=True,exist_ok=True)
        temporary=target.with_name('.'+target.name+'.'+uid()+'.tmp')
        try:
            with zipfile.ZipFile(source) as src,zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED) as dst:
                if sum(i.file_size for i in src.infolist())>100*1024*1024: raise ValueError('Слишком большой шаблон')
                for info in src.infolist():
                    content=src.read(info)
                    if info.filename.endswith('.xml') and (info.filename.startswith('word/') or info.filename.startswith('xl/')):
                        xml=content.decode('utf-8')
                        def replace_text(match):
                            nonlocal replaced
                            text=html.unescape(match.group(2))
                            for key,value in values.items():
                                marker='{{'+key+'}}'
                                if marker in text:
                                    replaced+=text.count(marker); missing.discard(key); text=text.replace(marker,value)
                            return match.group(1)+html.escape(text,quote=False)+match.group(3)
                        xml=re.sub(r'(<(?:[\w]+:)?t(?:\s[^>]*)?>)(.*?)(</(?:[\w]+:)?t>)',replace_text,xml,flags=re.S)
                        content=xml.encode('utf-8')
                    dst.writestr(info,content)
            if missing: raise ValueError('Метки не найдены или разбиты форматированием: '+', '.join(sorted(missing)))
            if target.exists():
                backup=self.root/'document-backups'/uid(); backup.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(target,backup)
            os.replace(temporary,target)
            return {'path':str(target),'replacements':replaced}
        finally:
            if temporary.exists(): temporary.unlink()
