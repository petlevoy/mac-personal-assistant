"""Real bundled model: load latency, first text, provider tokens, RSS, unload."""
import json,pathlib,sys,tempfile,threading
app=pathlib.Path(sys.argv[1]); model=sys.argv[2]
sys.path.insert(0,str(app/'Contents/Resources/backend'))
from core import Store
with tempfile.TemporaryDirectory() as tmp:
    store=Store(tmp)
    try:
        store.update_settings({'provider':'local','model':model,'contextLimit':1024,'toolsEnabled':False,'temperature':0})
        text,calls=store.stream_model(store.data['settings'],[{'role':'user','content':'Reply only with Hello. /no_think'}],threading.Event(),lambda _:None,False)
        state=store.engine.snapshot()
        assert text.strip(),text
        assert state['state']['status']=='ready',state
        assert state['state']['loadSeconds']>0,state
        assert state['rssBytes']>0,state
        assert state['metrics']['firstTextSeconds']>0,state
        assert state['metrics']['outputTokens']>0,state
        assert state['metrics']['tokensPerSecond']>0,state
        store.engine_action('unload')
        assert store.local.process is None
        assert store.engine.snapshot()['rssBytes'] is None
        print(json.dumps({'status':'passed','checks':7,'engine':state,'response':text,'unloaded':True},ensure_ascii=False,indent=2))
    finally: store.stop();store.local.close()
