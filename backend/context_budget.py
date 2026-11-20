"""Model metadata, configured server cap, and user budget are distinct values."""
import pathlib, struct
from functools import lru_cache

def gguf_context(path):
    try:
        p=pathlib.Path(path).expanduser().resolve(); stat=p.stat()
        if not p.is_file():return None
        return _gguf_context(str(p),stat.st_size,stat.st_mtime_ns)
    except (OSError,ValueError):return None

@lru_cache(maxsize=16)
def _gguf_context(path,size,mtime):
    # Read metadata only, with strict allocation/iteration bounds; tensors are never read.
    p=pathlib.Path(path).expanduser()
    if not p.is_file(): return None
    try:
        with p.open('rb') as f:
            def read(n):
                if n<0 or n>16*1024*1024: raise ValueError('Metadata too large')
                b=f.read(n)
                if len(b)!=n: raise ValueError('Truncated metadata')
                return b
            def number(fmt): return struct.unpack('<'+fmt,read(struct.calcsize('<'+fmt)))[0]
            def string(): return read(number('Q')).decode('utf-8')
            formats={0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
            def value(t,depth=0):
                if t in formats:return number(formats[t])
                if t==8:return string()
                if t==9 and depth<2:
                    subtype=number('I'); count=number('Q')
                    if count>1000000:raise ValueError('Metadata array too large')
                    for _ in range(count):value(subtype,depth+1)
                    return None
                raise ValueError('Invalid metadata')
            if read(4)!=b'GGUF' or number('I') not in (2,3):return None
            number('Q'); count=number('Q')
            if count>100000:return None
            for _ in range(count):
                key=string(); val=value(number('I'))
                if key.endswith('.context_length') and isinstance(val,int) and 0<val<100000000:return val
    except (OSError,ValueError,UnicodeError,struct.error):pass
    return None

def budget(settings):
    declared=gguf_context(settings.get('model','')) if settings.get('provider')=='local' else None
    server=settings.get('serverContextLimit') or None
    requested=int(settings.get('contextLimit',8192))
    caps=[x for x in (declared,server) if isinstance(x,int) and x>0]
    return {'requested':requested,'modelWindow':declared,'serverLimit':server,'effective':min([requested]+caps),
      'modelWindowSource':'GGUF metadata' if declared else 'unknown','memoryNotice':'Larger local context increases KV-cache memory; successful engine load is required. No memory guarantee.'}
