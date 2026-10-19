#!/usr/bin/env python3
"""obsws.py HOST CMD [ARGS] - a minimal obs-websocket v5 client (no auth), for
   scripts/board/osd.sh: the screen as OBS captures it, the OSD included.
  list                       scenes and inputs
  shot SOURCE OUT.png [W]    a screenshot of SOURCE (an input or a scene)"""
import base64, hashlib, json, os, socket, struct, sys

def connect(host, port=4455):
    s = socket.create_connection((host, port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: obswebsocket.json\r\n\r\n").encode())
    hdr = b""
    while b"\r\n\r\n" not in hdr:
        hdr += s.recv(1)
    if b" 101 " not in hdr.split(b"\r\n")[0]:
        raise SystemExit("handshake failed: " + hdr.decode(errors="replace"))
    return s

def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise SystemExit("closed")
        b += c
    return b

def recv(s):
    data = b""
    while True:
        h = recvn(s, 2)
        fin, op, ln = h[0] & 0x80, h[0] & 0x0f, h[1] & 0x7f
        if ln == 126: ln = struct.unpack(">H", recvn(s, 2))[0]
        elif ln == 127: ln = struct.unpack(">Q", recvn(s, 8))[0]
        if h[1] & 0x80: mask = recvn(s, 4)
        p = recvn(s, ln)
        if op == 9:  # ping -> pong
            send_frame(s, p, 10); continue
        data += p
        if fin: return json.loads(data)

def send_frame(s, payload, op=1):
    m = os.urandom(4)
    n = len(payload)
    h = bytes([0x80 | op])
    if n < 126: h += bytes([0x80 | n])
    elif n < 65536: h += bytes([0x80 | 126]) + struct.pack(">H", n)
    else: h += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(h + m + bytes(b ^ m[i % 4] for i, b in enumerate(payload)))

def send(s, obj): send_frame(s, json.dumps(obj).encode())

def session(host):
    s = connect(host)
    hello = recv(s)
    if hello.get("d", {}).get("authentication"):
        raise SystemExit("OBS asks for authentication")
    send(s, {"op": 1, "d": {"rpcVersion": 1}})
    recv(s)  # Identified
    return s

def req(s, rtype, data=None):
    rid = os.urandom(4).hex()
    send(s, {"op": 6, "d": {"requestType": rtype, "requestId": rid, "requestData": data or {}}})
    while True:
        m = recv(s)
        if m.get("op") == 7 and m["d"].get("requestId") == rid:
            st = m["d"]["requestStatus"]
            if not st.get("result"): raise SystemExit(f"{rtype}: {st}")
            return m["d"].get("responseData", {})

host, cmd = sys.argv[1], sys.argv[2]
s = session(host)
if cmd == "list":
    sc = req(s, "GetSceneList")
    print("current scene:", sc.get("currentProgramSceneName"))
    for x in sc.get("scenes", []): print("scene:", x["sceneName"])
    for x in req(s, "GetInputList").get("inputs", []): print("input:", x["inputName"], "(", x["inputKind"], ")")
elif cmd == "shot":
    src, out = sys.argv[3], sys.argv[4]
    w = int(sys.argv[5]) if len(sys.argv) > 5 else 1280
    r = req(s, "GetSourceScreenshot", {"sourceName": src, "imageFormat": "png", "imageWidth": w})
    open(out, "wb").write(base64.b64decode(r["imageData"].split(",", 1)[1]))
    print("wrote", out)
