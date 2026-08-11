#!/usr/bin/env python3
"""End-to-end HTTP checks against the M3 server.

Usage: bench/http-check.py <port>

Verifies, over real TCP connections:
- GET returns 200 with correct framing
- POST body is echoed byte-for-byte with correct Content-Length
- keep-alive: 10 requests on one connection
- pipelined requests in a single write
- error paths: 400 (malformed), 501 (unknown method), 413 (oversized body)
- Connection: close terminates the connection
Exits non-zero on any mismatch.
"""
import http.client
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
HOST = "127.0.0.1"

failures = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if not ok:
        failures.append(f"{name}: {detail}")
    else:
        print(f"  ok: {name}")


def raw_request(data: bytes, timeout: float = 5.0) -> bytes:
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(data)
    chunks = []
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        chunks.append(chunk)
        if b"\r\n\r\n" in b"".join(chunks) and len(b"".join(chunks)) > 0:
            pass
    s.close()
    return b"".join(chunks)


def main() -> int:
    # 1. GET via http.client (parses the response properly).
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    conn.request("GET", "/")
    r = conn.getresponse()
    check("GET / -> 200", r.status == 200)
    body = r.read()
    check("GET / -> empty body", body == b"")
    r.close()

    # 2. POST body echo.
    conn.request("POST", "/echo", body=b"hello-http-echo")
    r = conn.getresponse()
    check("POST -> 200", r.status == 200)
    check("POST -> body echoed", r.read() == b"hello-http-echo")

    # 3. Keep-alive: 10 sequential requests on one connection.
    ok_ka = True
    for i in range(10):
        conn.request("POST", "/x", body=f"msg-{i}".encode())
        r = conn.getresponse()
        if r.status != 200 or r.read() != f"msg-{i}".encode():
            ok_ka = False
            break
    check("keep-alive: 10 requests on one connection", ok_ka)
    conn.close()

    # 4. Pipelined requests in a single write.
    pipeline = (
        b"POST /a HTTP/1.1\r\nContent-Length: 1\r\n\r\nA"
        b"POST /b HTTP/1.1\r\nContent-Length: 1\r\n\r\nB"
    )
    got = raw_request(pipeline)
    ok_p = got.count(b"HTTP/1.1 200 OK") == 2 and got.endswith(b"B")
    check("pipelined requests answered in order", ok_p, got[:80])

    # 5. Error paths.
    got = raw_request(b"BREW / HTTP/1.1\r\n\r\n")
    check("501 unknown method", b"501 Not Implemented" in got)
    got = raw_request(b"GET / HTTP/1.1\r\nBadHeaderNoColon\r\n\r\n")
    check("400 malformed header", b"400 Bad Request" in got)

    # 6. Connection: close -> server closes after the response.
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.settimeout(5)
    s.sendall(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    check("Connection: close -> EOF after response", data.startswith(b"HTTP/1.1 200 OK") and data.endswith(b"\r\n\r\n"))

    # 7. Oversized body -> 413 (body completes in the buffer but exceeds the
    #    echo cap).
    body = b"x" * 15900
    got = raw_request(
        f"POST / HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body
    )
    check("413 oversized body", b"413 Payload Too Large" in got)

    # 8. Body larger than the read buffer can never complete -> 431, clean FIN.
    body = b"x" * 20000
    got = raw_request(
        f"POST / HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body
    )
    check("431 body overflow", b"431 Request Header Fields Too Large" in got)

    print(f"\nhttp-check: {len(failures)} failures")
    for f in failures[:10]:
        print("  " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
