"""Two-phase, identity-checked deletion to Trash. Only registered model files."""
import os, pathlib, secrets, time

def path_info(store,path):
    p=pathlib.Path(path).expanduser().absolute()
    if any(x.is_symlink() for x in [p,*p.parents]): raise ValueError('Удаление через симлинк запрещено')
    p=p.resolve()
    allowed={m['path'] for m in store.model_library()}
    if str(p) not in allowed or p.suffix.lower() not in ('.gguf','.safetensors') or not p.is_file():
        raise ValueError('Можно удалить только модель из библиотеки')
    if any(d.get('_active') or d['status'] in ('downloading','verifying','cancelling') for d in store.local.downloads.values() if pathlib.Path(d['path']).resolve()==p):
        raise ValueError('Сначала останови загрузку этой модели')
    if store.local.state['status']=='loading': raise ValueError('Дождись загрузки модели в память')
    st=p.stat()
    return p,(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns)

def preview(store,path):
    with store.lock,store.local.lock:
        store.idle();p,identity=path_info(store,path)
        token=secrets.token_hex(24)
        if not hasattr(store,'deletion_previews'): store.deletion_previews={}
        store.deletion_previews={k:v for k,v in store.deletion_previews.items() if v[2]>time.monotonic()}
        store.deletion_previews[token]=(str(p),identity,time.monotonic()+300)
        return {'token':token,'path':str(p),'name':p.name,'size':identity[2],'external':store.local.folder.resolve() not in p.parents}

def delete(store,token,trash=None):
    with store.lock,store.local.lock:
        store.idle()
        record=getattr(store,'deletion_previews',{}).pop(token,None)
        if not record or record[2]<time.monotonic(): raise ValueError('Подтверждение истекло; выбери модель заново')
        p,identity=path_info(store,record[0])
        if identity!=record[1]: raise ValueError('Файл изменился после подтверждения. Удаление отменено.')
        if store.local.state.get('path')==str(p): store.local.close()
        dest_root=pathlib.Path(trash) if trash is not None else pathlib.Path.home()/'.Trash'
        if dest_root.is_symlink(): raise ValueError('Некорректная папка Корзины')
        dest_root.mkdir(exist_ok=True,mode=0o700)
        target=dest_root/(secrets.token_hex(6)+'-'+p.name)
        # Atomic rename; external volumes fail safely instead of copy/delete races.
        try: os.rename(p,target)
        except OSError as e: raise ValueError('Не удалось переместить в Корзину. Для внешнего диска удали файл через Finder: '+str(e))
        store.local.known=[v for v in store.local.known if pathlib.Path(v).expanduser().resolve()!=p]
        store.local.downloads={k:v for k,v in store.local.downloads.items() if pathlib.Path(v['path']).resolve()!=p}
        store.data['imageLibrary']=[v for v in store.data.get('imageLibrary',[]) if pathlib.Path(v).expanduser().resolve()!=p]
        for key in ('model','imageLocalModel'):
            value=store.data['settings'].get(key,'')
            if value and pathlib.Path(value).expanduser().resolve()==p: store.data['settings'][key]=''
        store.local.persist();store.save()
        return {'ok':True,'trashedPath':str(target),'size':identity[2]}
