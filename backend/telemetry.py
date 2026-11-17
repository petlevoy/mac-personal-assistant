"""Best-effort read-only Apple HID sensors; never synthesize temperatures.
Only the app-owned local inference process is duty-cycle limited. Kernel thermal
protection is untouched. VM/unsupported hardware reports unavailable sensors.
"""
import ctypes as C
import os, signal, sys, time, threading

class Sensors:
    def __init__(self):
        self.available=False; self.client=None
        if sys.platform!='darwin': return
        try:
            self.cf=C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
            self.io=C.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
            def bind(lib,name,restype,args):
                f=getattr(lib,name); f.restype=restype; f.argtypes=args; return f
            ptr=C.c_void_p; lng=C.c_long
            self.release=bind(self.cf,'CFRelease',None,[ptr])
            self.string=bind(self.cf,'CFStringCreateWithCString',ptr,[ptr,C.c_char_p,C.c_uint32])
            self.getstr=bind(self.cf,'CFStringGetCString',C.c_bool,[ptr,C.c_char_p,lng,C.c_uint32])
            self.count=bind(self.cf,'CFArrayGetCount',lng,[ptr])
            self.at=bind(self.cf,'CFArrayGetValueAtIndex',ptr,[ptr,lng])
            self.services=bind(self.io,'IOHIDEventSystemClientCopyServices',ptr,[ptr])
            self.prop=bind(self.io,'IOHIDServiceClientCopyProperty',ptr,[ptr,ptr])
            self.event=bind(self.io,'IOHIDServiceClientCopyEvent',ptr,[ptr,C.c_int,C.c_longlong,C.c_int])
            self.value=bind(self.io,'IOHIDEventGetFloatValue',C.c_double,[ptr,C.c_uint32])
            self.client=bind(self.io,'IOHIDEventSystemClientCreate',ptr,[ptr])(None)
            # Apple temperature services use vendor usage page 0xff00, usage 5.
            # Explicit matching is required to enumerate these sensor services.
            self.matching=[]
            if self.client:
                create_dict=bind(self.cf,'CFDictionaryCreateMutable',ptr,[ptr,lng,ptr,ptr])
                set_value=bind(self.cf,'CFDictionarySetValue',None,[ptr,ptr,ptr])
                number=bind(self.cf,'CFNumberCreate',ptr,[ptr,C.c_int,ptr])
                matching=create_dict(None,0,None,None)
                self.matching.append(matching)
                for label,value in ((b'PrimaryUsagePage',0xff00),(b'PrimaryUsage',5)):
                    key=self.string(None,label,0x08000100)
                    raw=C.c_int(value); val=number(None,3,C.byref(raw))
                    self.matching.extend((key,val)); set_value(matching,key,val)
                bind(self.io,'IOHIDEventSystemClientSetMatching',None,[ptr,ptr])(self.client,matching)
            self.available=bool(self.client)
        except (OSError,AttributeError): self.available=False
    def read(self):
        out={'cpu':None,'gpu':None}
        if not self.available: return out
        services=self.services(self.client)
        if not services: return out
        key=self.string(None,b'Product',0x08000100)
        try:
            for i in range(self.count(services)):
                service=self.at(services,i); name=self.prop(service,key)
                if not name: continue
                buf=C.create_string_buffer(256)
                try: ok=self.getstr(name,buf,256,0x08000100)
                finally: self.release(name)
                if not ok: continue
                label=buf.value.decode(errors='replace').lower()
                kind='cpu' if any(name in label for name in ('cpu','pacc','eacc')) else 'gpu' if 'gpu' in label else None
                if not kind: continue
                event=self.event(service,15,0,0)
                if not event: continue
                try: value=self.value(event,15<<16)
                finally: self.release(event)
                if 0<value<130: out[kind]=max(out[kind] or value,value)
        finally:
            self.release(key); self.release(services)
        return out

_sensor_lock=threading.Lock()
_sensor=None; _last=0.; _cached={'cpu':None,'gpu':None}
def temperatures():
    global _sensor,_last,_cached
    with _sensor_lock:
        if time.monotonic()-_last>2:
            if _sensor is None: _sensor=Sensors()
            _cached=_sensor.read(); _last=time.monotonic()
        return dict(_cached)

def thermal_guard(store,done,limit):
    """At/above threshold run 50% duty cycle; serious OS state is a fallback.
    Hysteresis 3 C. Always resume the exact child before returning.
    """
    proc=store.local.process; paused=False; hot=False
    try:
        while not done.is_set() and proc is not None and proc.poll() is None:
            values=temperatures(); store.thermal.update(values)
            known=[v for v in values.values() if v is not None]
            if known: hot=max(known)>=(limit-3 if hot else limit)
            else: hot=store.thermal.get('state',0)>=2
            store.thermal['limited']=hot
            if hot:
                os.kill(proc.pid,signal.SIGSTOP); paused=True
                done.wait(.25)
                os.kill(proc.pid,signal.SIGCONT); paused=False
                done.wait(.25)
            else: done.wait(.5)
    except ProcessLookupError: pass
    finally:
        if paused and proc is not None and proc.poll() is None:
            try: os.kill(proc.pid,signal.SIGCONT)
            except ProcessLookupError: pass
        store.thermal['limited']=False
