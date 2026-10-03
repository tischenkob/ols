#!/usr/bin/env python3
"""usage: lsp_one.py ROOT FILE METHOD [startline endline | line char] ; prints result/time. lines 1-based."""
import json, os, subprocess, sys, threading, time, queue
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
ROOT, FILE, METHOD = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), sys.argv[3]
args = [int(x) for x in sys.argv[4:]]
TO = float(os.environ.get("REQ_TIMEOUT", "15"))
env = dict(os.environ, OLS_BUILTIN_FOLDER=os.path.join(REPO, "builtin"))
proc = subprocess.Popen([os.path.join(REPO, "ols")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=ROOT)
q = queue.Queue()
def reader():
    f = proc.stdout
    while True:
        n = None
        while True:
            line = f.readline()
            if not line: q.put(None); return
            if line in (b"\r\n", b"\n"): break
            k, _, v = line.decode().partition(":")
            if k.lower() == "content-length": n = int(v)
        q.put(json.loads(f.read(n)))
threading.Thread(target=reader, daemon=True).start()
def send(m):
    d = json.dumps(m).encode(); proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(d) + d); proc.stdin.flush()
i = 0
def req(method, params):
    global i
    i += 1; send({"jsonrpc": "2.0", "id": i, "method": method, "params": params}); t = time.time()
    while True:
        try: m = q.get(timeout=TO)
        except queue.Empty: return "TIMEOUT", time.time() - t
        if m is None: return "EXITED rc=%s %s" % (proc.poll(), proc.stderr.read()[-2000:].decode(errors="replace")), time.time() - t
        if "method" in m and "id" in m: send({"jsonrpc": "2.0", "id": m["id"], "result": None}); continue
        if m.get("id") == i: return m.get("result", m.get("error")), time.time() - t
req("initialize", {"processId": os.getpid(), "rootUri": "file://" + ROOT, "capabilities": {}, "initializationOptions": json.loads(os.environ.get("INIT_OPTS", "{}"))})
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
text = open(FILE).read(); lines = text.split("\n"); uri = "file://" + FILE
send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "odin", "version": 1, "text": text}}})
td = {"textDocument": {"uri": uri}}
if METHOD == "inlayHint":
    s, e = (args + [1, len(lines)])[:2] if args else (1, len(lines))
    p = {**td, "range": {"start": {"line": s - 1, "character": 0}, "end": {"line": e - 1, "character": len(lines[e - 1])}}}
elif METHOD in ("hover", "definition", "codeAction"):
    pos = {"line": args[0] - 1, "character": args[1] - 1}
    p = {**td, "position": pos} if METHOD != "codeAction" else {**td, "range": {"start": pos, "end": pos}, "context": {"diagnostics": []}}
elif METHOD == "formatting":
    p = {**td, "options": {"tabSize": 4, "insertSpaces": False}}
else:
    p = td
r, dt = req("textDocument/" + METHOD, p)
out = json.dumps(r)
print(f"{METHOD} {dt:.2f}s {out[:int(os.environ.get('OUTN', '600'))]}")
proc.kill()
