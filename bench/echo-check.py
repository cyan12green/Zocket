#!/usr/bin/env python3
"""Verify byte-exact echo correctness under concurrent load.

Opens `connections` concurrent clients; each sends `messages` payloads of
random sizes and asserts the server echoes each payload back byte-for-byte.
Exits non-zero on any mismatch, as a correctness gate for benchmark runs.
"""
import os
import random
import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
CONNECTIONS = int(os.environ.get("ECHO_CONNECTIONS", "50"))
MESSAGES = int(os.environ.get("ECHO_MESSAGES", "40"))
MAX_PAYLOAD = int(os.environ.get("ECHO_MAX_PAYLOAD", "8192"))


def client(cid: int, failures: list) -> None:
    rng = random.Random(cid)
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    except OSError as e:
        failures.append(f"client {cid}: connect failed: {e}")
        return
    s.settimeout(5)
    try:
        for m in range(MESSAGES):
            size = rng.randint(1, MAX_PAYLOAD)
            payload = bytes(rng.getrandbits(8) for _ in range(size))
            s.sendall(payload)
            got = b""
            while len(got) < size:
                chunk = s.recv(size - len(got))
                if not chunk:
                    failures.append(f"client {cid} msg {m}: closed, got {len(got)}/{size}")
                    return
                got += chunk
            if got != payload:
                failures.append(f"client {cid} msg {m}: mismatch (len {len(got)} vs {size})")
                return
    except OSError as e:
        failures.append(f"client {cid}: io error: {e}")
    finally:
        s.close()


def main() -> int:
    failures: list = []
    threads = [threading.Thread(target=client, args=(i, failures)) for i in range(CONNECTIONS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    total = CONNECTIONS * MESSAGES
    if failures:
        print(f"echo-check FAILED: {len(failures)} errors out of {total} messages")
        for f in failures[:10]:
            print("  " + f)
        return 1
    print(f"echo-check OK: {total} byte-exact echoes across {CONNECTIONS} connections")
    return 0


if __name__ == "__main__":
    sys.exit(main())
