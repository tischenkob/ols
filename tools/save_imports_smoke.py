#!/usr/bin/env python3
"""Smoke test for organize imports on save: drives ./ols over stdio and checks the
workspace/applyEdit request it sends after didSave."""
import json
import os
import subprocess
import sys
import tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ols = os.path.join(root, "ols")

SOURCE = """package smoke

import "core:fmt"

main :: proc() {
\t_ = strings.trim_space(" world ")
}
"""

EXPECTED = """package smoke

import "core:strings"

main :: proc() {
\t_ = strings.trim_space(" world ")
}
"""


def apply_edits(text, edits):
    lines = text.split("\n")
    offsets = [0]
    for line in lines[:-1]:
        offsets.append(offsets[-1] + len(line) + 1)

    def offset(pos):
        return offsets[pos["line"]] + pos["character"]

    for edit in sorted(edits, key=lambda e: offset(e["range"]["start"]), reverse=True):
        start, end = offset(edit["range"]["start"]), offset(edit["range"]["end"])
        text = text[:start] + edit["newText"] + text[end:]
    return text


def main():
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "ols.json"), "w") as f:
            f.write("{}")
        path = os.path.join(tmp, "main.odin")
        with open(path, "w") as f:
            f.write(SOURCE)
        uri = "file://" + path
        root_uri = "file://" + tmp

        env = dict(os.environ, OLS_BUILTIN_FOLDER=os.path.join(root, "builtin"))
        proc = subprocess.Popen(
            [ols],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )

        def send(msg):
            data = json.dumps(msg).encode()
            proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
            proc.stdin.flush()

        def recv():
            length = None
            while True:
                line = proc.stdout.readline()
                if not line:
                    raise SystemExit("server closed stdout\n" + proc.stderr.read().decode())
                if line == b"\r\n":
                    break
                key, _, value = line.decode().partition(":")
                if key.lower() == "content-length":
                    length = int(value)
            return json.loads(proc.stdout.read(length))

        send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "rootUri": root_uri,
                "workspaceFolders": [{"uri": root_uri, "name": "smoke"}],
                "capabilities": {"workspace": {"applyEdit": True}},
            },
        })
        send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        send({
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": uri, "languageId": "odin", "version": 1, "text": SOURCE}},
        })
        send({
            "jsonrpc": "2.0", "method": "textDocument/didSave",
            "params": {"textDocument": {"uri": uri}, "text": SOURCE},
        })

        while True:
            msg = recv()
            if msg.get("method") == "workspace/applyEdit":
                break

        print(json.dumps(msg, indent=1))
        params = msg["params"]
        assert params["label"] == "organize imports", params
        edits = params["edit"]["changes"][uri]
        got = apply_edits(SOURCE, edits)
        assert got == EXPECTED, got

        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"applied": True}})
        send({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None})
        while recv().get("id") != 2:
            pass
        send({"jsonrpc": "2.0", "method": "exit", "params": None})
        proc.wait(timeout=10)

        stderr = proc.stderr.read().decode()
        errors = [l for l in stderr.splitlines() if "[ERROR" in l]
        assert not errors, "\n".join(errors)
        print("ok")


if __name__ == "__main__":
    main()
