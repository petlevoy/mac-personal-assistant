"""Read-only, bounded diagnostics of this installation; never guess OS or paths."""
import json, os, pathlib, platform, re, shutil, time, urllib.parse

def redact(value, secrets=()):
    text=str(value)
    for secret in secrets:
        if secret: text=text.replace(str(secret),'[redacted]')
    text=re.sub(r'(?i)(bearer\s+)[^\s"\']+',r'\1[redacted]',text)
    text=re.sub(r'(?i)((?:api[_-]?key|token|password|secret)\s*[=:]\s*)[^\s,;]+',r'\1[redacted]',text)
    return text

def report(store, pid, probe=False):
    from telemetry import temperatures
    from local_images import model_file, runtime_binary
    from context_budget import budget
    settings=store.data['settings']; project=store.project(pid)
    secrets=list(store.secrets.values())+[store.local.key]
    def path_info(path):
        p=pathlib.Path(path).expanduser()
        return {'path':str(p),'exists':p.exists(),'readable':os.access(p,os.R_OK),'writable':os.access(p,os.W_OK)}
    temps=temperatures()
    result={'app':'inij','version':'0.4.2','os':platform.platform(),'checkedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
      'paths':{'data':path_info(store.root),'projects':path_info(store.root/'projects'),'workspace':path_info(project['workspace']),'models':path_info(store.local.folder)},
      'context':budget(settings),'textEngine':store.engine.snapshot(),'models':store.model_library(),
      'image':{'provider':settings.get('imageProvider'),'enabled':settings.get('imageEnabled',False),'runtime':path_info(runtime_binary()),'selectedModel':settings.get('imageLocalModel',''),'lastRun':store.data.get('imageLastRun')},
      'mcp':[{'id':s['id'],'name':s['name'],'enabled':s['enabled'],'executableFound':bool(shutil.which(s['command']) or pathlib.Path(s['command']).is_file()),'sandbox':'macOS sandbox-exec' if pathlib.Path('/usr/bin/sandbox-exec').exists() else 'unavailable; execution denied','networkAllowed':s.get('allowNetwork',False),'readRoots':s.get('readRoots',[]),'writeRoots':s.get('writeRoots',[])} for s in store.data.get('mcp',[])],
      'skills':[{'id':s['id'],'name':s['name'],'folderExists':pathlib.Path(s['folder']).is_dir(),'dependencies':s.get('dependencies',[])} for s in project['skills']],
      'sensors':{**temps,'reason':None if any(v is not None for v in temps.values()) else 'No accessible CPU/GPU temperature sensors; hardware/VM support is not available'},
      'resources':{'freeDiskBytes':shutil.disk_usage(store.root).free},
      'connections':{'mode':settings['mode'],'provider':settings['provider'],'endpoint':settings.get('baseURL'),'modelKeyPresent':bool(store.secrets.get('model')),'searchProvider':settings.get('searchProvider'),'searchKeyPresent':bool(store.secrets.get(settings.get('searchProvider','brave'))),'probe':'not_run; no network requests made'},
      'recentLog':project.get('log',[])[-12:]}
    if settings.get('imageLocalModel'):
        try: result['image']['modelValidation']={'validHeader':True,'path':str(model_file(settings['imageLocalModel'])),'notice':'Header check does not prove model completeness or successful inference'}
        except (OSError,ValueError) as e: result['image']['modelValidation']={'validHeader':False,'error':str(e)}
    if probe:
        from core import validate_endpoint,request_json
        import urllib.error
        if settings['provider']=='local': result['connections']['probe']='local engine state inspected; no remote provider'
        else:
            try:
                base=validate_endpoint(settings['baseURL'],settings['mode'],settings['provider'])
                endpoint='/api/tags' if settings['provider']=='ollama' else '/models'
                with request_json(base+endpoint,key=store.secrets.get('model',''),timeout=3) as response:
                    response.read(1024); result['connections']['probe']={'reachable':True,'httpStatus':response.status}
            except urllib.error.HTTPError as e: result['connections']['probe']={'reachable':True,'httpStatus':e.code}
            except Exception as e: result['connections']['probe']={'reachable':False,'error':redact(str(e),secrets)}
    runtime_log=store.root/'model-runtime.log'
    if runtime_log.exists():
        with runtime_log.open('rb') as f:
            f.seek(max(0,runtime_log.stat().st_size-4000)); result['textRuntimeLog']=f.read(4000).decode(errors='replace')
    def scrub(value):
        if isinstance(value,str): return redact(value,secrets)
        if isinstance(value,list): return [scrub(v) for v in value]
        if isinstance(value,dict): return {k:scrub(v) for k,v in value.items()}
        return value
    return scrub(result)
