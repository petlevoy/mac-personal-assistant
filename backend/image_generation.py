"""Independent OpenAI-compatible image provider; credentials stay memory-only."""
import base64
import json
import os
from core import MAX_FILE, request_json, safe_path, uid, validate_endpoint


def generate(store, job, args, settings):
    if not settings.get('imageEnabled'):
        raise ValueError('Включи генератор изображений в настройках')
    if settings.get('imageProvider','cloud') == 'local':
        from local_images import generate as local_generate
        return local_generate(store, job, args, settings)
    if settings['mode'] == 'offline':
        raise ValueError('Для генерации изображений включи интернет')
    if not settings.get('imageEnabled'):
        raise ValueError('Включи генератор изображений в настройках')
    base = validate_endpoint(settings.get('imageBaseURL',''), 'cloud', 'openai')
    model = str(settings.get('imageModel','')).strip()
    prompt = str(args.get('prompt','')).strip()
    if not model or not prompt or len(prompt) > 16000:
        raise ValueError('Нужны модель и запрос длиной до 16000 символов')
    root = store.project(job['projectID'])['workspace']
    approval = store.await_action(job,'approval',{'tool':'generate_image','arguments':{'prompt':prompt,'model':model,'provider':base},'workspace':root})
    if not approval.get('approved'): return {'status':'rejected'}
    if job['stop'].is_set(): raise InterruptedError('Остановлено')
    # GPT image models always return base64 and reject response_format.
    body = {'model':model,'prompt':prompt,'n':1}
    if not model.startswith('gpt-image'): body['response_format']='b64_json'
    try:
        with request_json(base+'/images/generations', body, key=store.secrets.get('image',''),timeout=180) as response:
            raw=response.read(MAX_FILE*2+1)
        if len(raw)>MAX_FILE*2: raise ValueError('Ответ генератора слишком большой')
        data=json.loads(raw)
        encoded=data['data'][0]['b64_json']
        image=base64.b64decode(encoded,validate=True)
    except Exception:
        raise ValueError('Генератор не вернул изображение b64_json. Проверь адрес, ключ, модель и поддержку Images API.') from None
    if job['stop'].is_set(): raise InterruptedError('Остановлено')
    if not image or len(image)>MAX_FILE: raise ValueError('Изображение пустое или больше 12 МБ')
    if image.startswith(b'\x89PNG\r\n\x1a\n'): ext='png'
    elif image.startswith(b'\xff\xd8\xff'): ext='jpg'
    elif image[:4]==b'RIFF' and image[8:12]==b'WEBP': ext='webp'
    else: raise ValueError('Генератор вернул неизвестный формат изображения')
    relative='generated-'+uid()+'.'+ext
    path=safe_path(root,relative)
    with path.open('xb') as output: output.write(image)
    os.chmod(path,0o600)
    return {'path':relative,'model':model,'bytes':len(image)}
