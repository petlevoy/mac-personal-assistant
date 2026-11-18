"""One-shot bundled stable-diffusion.cpp. No cloud or executable/model downloads."""
import atexit, json, os, pathlib, platform, signal, struct, subprocess, tempfile, threading, time
from core import MAX_FILE, safe_path, uid

TIMEOUT = 1800
_ACTIVE = set()
_LOCK = threading.Lock()

def terminate(process):
    if process.poll() is not None: return
    try: os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError: return
    try: process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait(timeout=3)

def shutdown():
    with _LOCK: children = list(_ACTIVE)
    for child in children: terminate(child)
atexit.register(shutdown)

def model_file(value):
    if not str(value).strip(): raise ValueError('Выбери локальный checkpoint изображений в настройках')
    path = pathlib.Path(str(value)).expanduser().resolve()
    if not path.is_file() or path.suffix.lower() not in ('.gguf', '.safetensors'):
        raise ValueError('Нужен существующий полный checkpoint SD 1.x / SD 2.x / SDXL: .gguf или .safetensors')
    with path.open('rb') as f:
        prefix = f.read(8)
        if path.suffix.lower() == '.gguf':
            if len(prefix) != 8 or prefix[:4] != b'GGUF' or struct.unpack('<I',prefix[4:])[0] not in (2,3):
                raise ValueError('Некорректный GGUF v2/v3')
            header = f.read(min(path.stat().st_size, 2*1024*1024))
            if b'token_embd.weight' in header or b'blk.0.attn_q.weight' in header:
                raise ValueError('Это текстовая GGUF-модель. Выбери checkpoint Stable Diffusion, не LLM.')
        else:
            if len(prefix) != 8: raise ValueError('Повреждённый safetensors')
            length = struct.unpack('<Q',prefix)[0]
            if length > 16*1024*1024 or length < 2: raise ValueError('Некорректный заголовок safetensors')
            try: header = json.loads(f.read(length))
            except (ValueError, UnicodeError): raise ValueError('Некорректный заголовок safetensors') from None
            if not isinstance(header,dict) or not any(k.startswith('model.diffusion_model.') for k in header):
                raise ValueError('Нужен полный SD checkpoint, не отдельный UNet/LoRA/текстовая модель. FLUX и SD3 с отдельными компонентами пока не поддержаны.')
    return path

def runtime_binary():
    return pathlib.Path(__file__).resolve().parent.parent/'stable-diffusion'/'sd-cli'

def generate(store, job, args, settings):
    prompt = str(args.get('prompt','')).strip()
    if not prompt or len(prompt) > 16000: raise ValueError('Нужен запрос длиной от 1 до 16000 символов')
    model = model_file(settings.get('imageLocalModel',''))
    binary = runtime_binary()
    if not binary.is_file(): raise ValueError('Встроенный движок изображений отсутствует. Установи полный DMG Inij.')
    if platform.system() != 'Darwin' or int(platform.mac_ver()[0].split('.')[0] or 0) < 26:
        raise ValueError('Встроенный движок изображений этой сборки требует macOS 26 или новее')
    if not pathlib.Path('/usr/bin/sandbox-exec').is_file(): raise ValueError('Недоступен защищённый локальный запуск без сети')
    width = int(settings.get('imageWidth',512)); height = int(settings.get('imageHeight',512))
    steps = int(settings.get('imageSteps',20)); cfg = float(settings.get('imageCFG',7))
    if width not in (256,512,768,1024) or height not in (256,512,768,1024) or not 1 <= steps <= 50 or not 1 <= cfg <= 15:
        raise ValueError('Проверь размер, шаги и CFG в настройках изображений')
    root = store.project(job['projectID'])['workspace']
    if not job.get('directImage'):
        approval=store.await_action(job,'approval',{'tool':'generate_image','arguments':{'prompt':prompt,'model':str(model),'provider':'Локально · без сети'},'workspace':root})
        if not approval.get('approved'): return {'status':'rejected'}
    if job['stop'].is_set(): raise InterruptedError('Остановлено')
    # This is only this Store's owned llama process, never another app/user process.
    # The text model reloads automatically on the next chat inference.
    store.local.close()
    with tempfile.TemporaryDirectory(prefix='.inij-image-',dir=root) as temp:
        output = pathlib.Path(temp)/'result.png'
        prompt_file = pathlib.Path(temp)/'prompt.txt'; prompt_file.write_text(prompt,encoding='utf-8'); os.chmod(prompt_file,0o600)
        command = ['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),
                   '-m',str(model),'--prompt-file',str(prompt_file),'-o',str(output),'-W',str(width),'-H',str(height),
                   '--steps',str(steps),'--cfg-scale',str(cfg),'--sampling-method','euler','--seed','-1',
                   '--vae-tiling','--mmap','--log-level','warn']
        compute=settings.get('imageCompute','auto')
        if compute=='auto':
            # Parallels Metal advertises a device but cannot execute this SD graph.
            # Select CPU explicitly on VirtualMac; physical Macs keep Metal auto.
            try:
                if subprocess.check_output(['/usr/sbin/sysctl','-n','hw.model'],timeout=3).decode().strip().startswith('VirtualMac'): compute='cpu'
            except (OSError,subprocess.SubprocessError): pass
        if compute=='cpu': command += ['--backend','cpu']
        env={k:v for k,v in os.environ.items() if k in ('HOME','TMPDIR','LANG','LC_ALL','PATH')}
        job['detail']='Локальная генерация ('+('CPU' if compute=='cpu' else 'авто / Metal')+'): загрузка модели и создание изображения…'
        tail=bytearray()
        process=subprocess.Popen(command,cwd=temp,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
        with _LOCK: _ACTIVE.add(process)
        def consume():
            while True:
                data=process.stdout.read(1024)
                if not data: break
                tail.extend(data)
                if len(tail)>16000: del tail[:-16000]
        reader=threading.Thread(target=consume,daemon=True); reader.start()
        try:
            deadline=time.monotonic()+TIMEOUT
            while process.poll() is None:
                if job['stop'].wait(.2): raise InterruptedError('Остановлено')
                if time.monotonic()>deadline: raise TimeoutError('Генерация превысила 30 минут. Попробуй меньше шагов/размер или другую модель.')
            reader.join(timeout=3)
            if job['stop'].is_set(): raise InterruptedError('Остановлено')
            if process.returncode != 0 or not output.is_file():
                detail=tail.decode('utf-8',errors='replace')[-1500:]
                store.log(job['projectID'],'Локальный генератор: ошибка',detail)
                raise ValueError('Локальная генерация не завершилась (код '+str(process.returncode)+'). Проверь полный SD checkpoint, память и режим CPU. Подробности — в журнале проекта.')
            if output.is_symlink() or not 0 < output.stat().st_size <= MAX_FILE: raise ValueError('Генератор вернул недопустимый размер изображения')
            image=output.read_bytes()
            if not image.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError('Генератор не вернул PNG')
            relative='generated-'+uid()+'.png'; destination=safe_path(root,relative)
            with destination.open('xb') as f: f.write(image)
            os.chmod(destination,0o600)
            return {'path':relative,'model':model.name,'bytes':len(image),'provider':'local','compute':compute}
        finally:
            terminate(process); reader.join(timeout=3)
            if process.stdout: process.stdout.close()
            with _LOCK: _ACTIVE.discard(process)
            job.pop('detail',None)
