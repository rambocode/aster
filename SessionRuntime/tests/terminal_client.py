"""Focused terminal CLI transport checks; builds isolated harness unless binary supplied."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HARNESS = 'const std = @import("std");\nconst client = @import("client");\npub fn main() !void {\n    const a = std.heap.page_allocator;\n    const args = try std.process.argsAlloc(a);\n    const command: client.Command = if (std.mem.eql(u8, args[2], "create")) .{ .create = .{ .cwd = "/remote path", .argv = &.{ "tool", "$(literal); a" }, .environment = &.{"TOKEN=secret=value"} } } else if (std.mem.eql(u8, args[2], "terminate")) .{ .terminate = "12345678-1234-1234-1234-123456789abc" } else .list;\n    const result = try client.execute(a, args[1], "session", command, 200);\n    try std.fs.File.stdout().writeAll(result.bytes);\n}\n'
ROOT = Path(__file__).resolve().parents[1]

def packet(value):
    body = json.dumps(value).encode()
    return struct.pack(">BI", 1, len(body)) + body

def read(peer):
    def exact(n):
        data = b""
        while len(data) < n:
            part = peer.recv(n-len(data))
            if not part: raise EOFError()
            data += part
        return data
    kind, size = struct.unpack(">BI", exact(5))
    assert kind == 1 and size <= 1048576
    return json.loads(exact(size))

def exercise(binary, command, mode="ok"):
    with tempfile.TemporaryDirectory(prefix="ast-tc-", dir="/tmp") as parent:
        state = Path(parent)/"session"
        state.mkdir(mode=0o700)
        listener = socket.socket(socket.AF_UNIX)
        path = state/"control.sock"
        listener.bind(str(path)); path.chmod(0o600); listener.listen(1)
        listener.settimeout(2)
        failures = []
        observed = []
        done = threading.Event()
        uid = "12345678-1234-1234-1234-123456789abc"
        def serve():
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(2)
                    if mode == "silent": done.wait(1); return
                    hello = dict(type="hello",protocolMajor=1,protocolMinor=0,serverID=uid,serverEpoch=uid,sessionID=uid,platform="linux-x86_64",capabilities=["terminal_control"])
                    if mode == "capability": hello["capabilities"] = []
                    peer.sendall(packet(hello))
                    if mode == "capability":
                        assert peer.recv(1) == b""; return
                    value = read(peer); observed.append(value)
                    assert value["operation"] == "terminal."+command
                    if command == "list": assert "createdAtUnixMs" not in value
                    else: assert abs(value["createdAtUnixMs"]-int(time.time()*1000)) < 3000
                    if command == "create":
                        assert value["params"]["argv"] == ["tool", "$(literal); a"]
                        assert value["params"]["environment"] == {"TOKEN":"secret=value"}
                    if mode == "disconnect": return
                    terminal = dict(terminalID=uid,cwd="/remote path",state="running",pid=123)
                    result = {"terminals":[terminal]} if command == "list" else terminal
                    response = dict(type="response",requestID=value["requestID"],operation=value["operation"],scope="session",target=value["target"],revision=0,result=result)
                    if mode == "wrong_id": response["requestID"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                    if mode == "wrong_terminal": terminal["terminalID"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                    if mode == "bad_result": terminal["pid"] = 0
                    if mode == "wrong_epoch": response["target"]["serverEpoch"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                    peer.sendall(packet(response))
            except BaseException as exc: failures.append(exc)
        thread=threading.Thread(target=serve);thread.start()
        started=time.monotonic()
        run=subprocess.run([binary,parent,command],capture_output=True,text=True,timeout=3)
        elapsed=time.monotonic()-started;done.set();thread.join();listener.close()
        assert not failures, failures
        assert run.returncode == 0, run.stderr
        output=json.loads(run.stdout)
        assert output["type"] == ("response" if mode == "ok" else "client_error"), output
        assert "secret" not in run.stdout and "secret" not in run.stderr
        if mode == "silent": assert elapsed < 1, elapsed
        assert len(observed) <= 1

with tempfile.TemporaryDirectory(prefix="aster-terminal-build-") as build:
    if len(sys.argv)>1: binary=str(Path(sys.argv[1]).resolve())
    else:
        source=Path(build)/"main.zig";source.write_text(HARNESS)
        binary=str(Path(build)/"client")
        subprocess.run(["zig","build-exe","-lc","--dep","client","-Mroot="+str(source),"-I","src/platform","-cflags","-std=c11","-D_DEFAULT_SOURCE","--","src/platform/pty.c","-Mclient=src/terminal_client.zig","-femit-bin="+binary],cwd=ROOT,check=True)
    for command in ("create","list","terminate"): exercise(binary,command)
    for mode in ("capability","silent","disconnect","wrong_id","bad_result","wrong_epoch"): exercise(binary,"create",mode)
    exercise(binary,"terminate","wrong_terminal")
print("PASS: 10 terminal client transport cases")
