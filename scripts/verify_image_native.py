"""Native chat -> mock chat provider -> image tool -> native artifact preview/save.
No external provider call or paid image generation. Uses isolated smoke data.
"""
import base64, http.server, json, pathlib, subprocess, sys, threading, zlib, struct

def chunk(kind,data):
    return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',32,32,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\x00'+b'\x22\x88\xee'*32)*32))+chunk(b'IEND',b'')
calls=[]
class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append({'path':self.path,'body':body,'auth':self.headers.get('Authorization')})
        self.send_response(200)
        if self.path=='/v1/images/generations':
            self.send_header('Content-Type','application/json');self.end_headers()
            self.wfile.write(json.dumps({'data':[{'b64_json':base64.b64encode(png).decode()}]}).encode())
        else:
            self.send_header('Content-Type','text/event-stream');self.end_headers()
            if any(m['role']=='tool' for m in body['messages']): delta={'content':'Fixture image created.'}
            else: delta={'tool_calls':[{'index':0,'id':'fixture-call','type':'function','function':{'name':'generate_image','arguments':json.dumps({'prompt':'A blue square'})}}]}
            self.wfile.write(('data: '+json.dumps({'choices':[{'delta':delta}]})+'\n\ndata: [DONE]\n\n').encode())
app=pathlib.Path(sys.argv[1]).resolve();report=pathlib.Path(sys.argv[2]).resolve()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Mock)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
    subprocess.run(['/usr/bin/open','-n','-F','-W','-a',str(app),'--args','-ApplePersistenceIgnoreState','YES','--smoke-test',str(report),'--skip-capture','--skip-keychain','--image-smoke-base',f'http://127.0.0.1:{server.server_port}/v1'],check=True,timeout=90)
finally: server.shutdown();server.server_close();thread.join()
r=json.loads(report.read_text());assert r['status']=='passed',r
assert pathlib.Path(str(report)+'-saved.png').read_bytes()==png
images=[c for c in calls if c['path'].endswith('/images/generations')]
chats=[c for c in calls if c['path'].endswith('/chat/completions')]
assert len(images)==1 and len(chats)==2,[(c['path']) for c in calls]
assert images[0]['auth']=='Bearer fixture-image-key'
assert all(c['auth']=='Bearer fixture-chat-key' for c in chats)
assert images[0]['body']['model']=='gpt-image-fixture'
assert any(t['function']['name']=='generate_image' for t in chats[0]['body']['tools'])
print(json.dumps(r,indent=2))
print('PASS: native send -> tool approval -> separate-key Images API -> artifact preview + byte-exact Save As; mock only')
