#!/usr/bin/env python3
"""Tests for the Python LocalSend backend.

`python3 -m unittest discover -s python/tests -v` from the repo root.

The daemon runs as a subprocess with throwaway HOME/XDG dirs and discovery switched off, so the
suite never announces itself to the real network or touches the user's config.
"""

from __future__ import annotations

import http.client
import importlib.util
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DAEMON = ROOT / "python" / "localsendd"
CTL = ROOT / "python" / "localsendctl"


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "localsendd_mod",
        importlib.machinery.SourceFileLoader("localsendd_mod", str(DAEMON)),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load_daemon()


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class HermeticDirs(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="lsd-py-"))
        self.env = {
            "HOME": str(self.tmp / "home"),
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
            "XDG_RUNTIME_DIR": str(self.tmp / "run"),
            "XDG_CACHE_HOME": str(self.tmp / "cache"),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LOCALSENDD_DISCOVERY": "0",
            # The suite shares the network namespace with the real daemon, which holds the
            # production abstract-socket name.
            "LOCALSENDD_GUARD_NAME": f"lsd-py-test-{os.getpid()}-{id(self)}",
        }
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "XDG_CACHE_HOME"):
            Path(self.env[key]).mkdir(parents=True, exist_ok=True)
        self.procs: list[subprocess.Popen] = []

    def tearDown(self) -> None:
        for proc in self.procs:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ctl(self, *args: str) -> dict:
        out = subprocess.run(
            [sys.executable, str(CTL), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        return json.loads(out.stdout.strip().splitlines()[-1] or "{}")

    def start_daemon(self, port: int, *extra: str) -> subprocess.Popen:
        proc = subprocess.Popen(
            [sys.executable, str(DAEMON), "--port", str(port), "--alias", "py-test", *extra],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.procs.append(proc)
        deadline = time.time() + 15
        while time.time() < deadline:
            if proc.poll() is not None:
                raise AssertionError(f"daemon exited early: {proc.stdout.read() if proc.stdout else ''}")
            if self.ctl("ping").get("ok") is True:
                # Control answers only after the HTTPS listener is bound; wait for it anyway so a
                # slow first TLS handshake cannot race the test client.
                deadline_tls = time.time() + 15
                while time.time() < deadline_tls:
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0:
                            return proc
                    time.sleep(0.05)
            time.sleep(0.1)
        raise AssertionError("daemon never answered on its control socket")

    def client_context(self, cert) -> ssl.SSLContext:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.load_cert_chain(str(cert.cert_path), str(cert.key_path))
        return ctx


class UnitTests(unittest.TestCase):
    def test_sanitize_blocks_traversal(self):
        self.assertEqual(mod.sanitize_file_name("../../etc/passwd"), "passwd")
        self.assertEqual(mod.sanitize_file_name("/abs/x.txt"), "x.txt")
        self.assertEqual(mod.sanitize_file_name("..."), "file")

    def test_unique_path_avoids_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "a.txt").write_text("1")
            self.assertEqual(mod.unique_path(directory, "a.txt").name, "a (1).txt")
            (directory / "a (1).txt").write_text("2")
            self.assertEqual(mod.unique_path(directory, "a.txt").name, "a (2).txt")

    def test_certificate_fingerprint_is_stable(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["XDG_CONFIG_HOME"] = tmp
            first = mod.ensure_cert()
            self.assertEqual(len(first.fingerprint), 64)
            int(first.fingerprint, 16)
            second = mod.ensure_cert()
            self.assertEqual(first.fingerprint, second.fingerprint)

    def test_pick_port_skips_busy_port(self):
        busy = socket.socket()
        busy.bind(("0.0.0.0", 0))
        port = busy.getsockname()[1]
        busy.listen(1)
        try:
            self.assertNotEqual(mod.pick_port(port), port)
        finally:
            busy.close()


class HistoryRetentionTests(unittest.TestCase):
    """The ledger stays bounded by count and by age, on read as well as on write."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="lsd-hist-"))
        self.saved = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(self.tmp)
        self.day = 86400 * 1000

    def tearDown(self) -> None:
        if self.saved is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = self.saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_load_drops_entries_past_the_window(self):
        history = mod.History()
        now = mod.now_ms()
        history.entries = [
            {"id": "fresh", "finishedMs": now - self.day},
            {"id": "edge", "finishedMs": now - mod.HISTORY_DAYS * self.day + 60000},
            {"id": "stale", "finishedMs": now - (mod.HISTORY_DAYS + 1) * self.day},
            {"id": "legacy"},
        ]
        history.save()

        reloaded = mod.History()
        ids = [entry["id"] for entry in reloaded.entries]
        self.assertEqual(ids, ["fresh", "edge", "legacy"])
        on_disk = json.loads(reloaded.path().read_text())["entries"]
        self.assertEqual([entry["id"] for entry in on_disk], ids)

    def test_push_applies_the_window_and_the_cap(self):
        history = mod.History()
        now = mod.now_ms()
        history.push({"id": "stale", "finishedMs": now - (mod.HISTORY_DAYS + 2) * self.day})
        self.assertEqual(history.entries, [])

        for index in range(mod.HISTORY_MAX + 25):
            history.push({"id": f"e{index}", "finishedMs": now})
        self.assertEqual(len(history.entries), mod.HISTORY_MAX)
        self.assertEqual(history.entries[0]["id"], f"e{mod.HISTORY_MAX + 24}")
        self.assertEqual(history.entries[-1]["id"], "e25")

    def test_received_paths_survive_pruning(self):
        history = mod.History()
        now = mod.now_ms()
        history.entries = [
            {"id": "kept", "direction": "receive", "finishedMs": now, "files": [{"name": "a.jpg", "path": "/x/a.jpg"}]},
            {"id": "dropped", "direction": "receive", "finishedMs": now - 200 * self.day, "files": [{"name": "b.jpg", "path": "/x/b.jpg"}]},
        ]
        history.save()
        reloaded = mod.History()
        self.assertEqual([entry["id"] for entry in reloaded.entries], ["kept"])
        self.assertEqual(reloaded.entries[0]["files"][0]["path"], "/x/a.jpg")

class ReceiveFlowTests(HermeticDirs):
    def test_accept_upload_lands_in_download_dir(self):
        port = free_port()
        self.start_daemon(port)
        cert = mod.ensure_cert()
        payload = {
            "info": {
                "alias": "phone",
                "version": "2.1",
                "deviceModel": "Pixel",
                "deviceType": "mobile",
                "fingerprint": "f" * 64,
                "port": 12345,
                "protocol": "https",
                "download": False,
            },
            "files": {
                "file-1": {
                    "id": "file-1",
                    "fileName": "hello.bin",
                    "size": 4096,
                    "fileType": "application/octet-stream",
                }
            },
        }
        conn = http.client.HTTPSConnection(
            "127.0.0.1", port, timeout=20, context=self.client_context(cert)
        )
        result: dict = {}

        def do_prepare():
            body = json.dumps(payload).encode()
            conn.request(
                "POST",
                "/api/localsend/v2/prepare-upload",
                body=body,
                headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
            )
            resp = conn.getresponse()
            result["status"] = resp.status
            result["body"] = json.loads(resp.read() or b"{}")

        thread = threading.Thread(target=do_prepare)
        thread.start()

        prompt = None
        deadline = time.time() + 10
        while time.time() < deadline and prompt is None:
            prompts = self.ctl("state").get("prompts") or []
            prompt = prompts[0] if prompts else None
            if prompt is None:
                time.sleep(0.1)
        self.assertIsNotNone(prompt, "daemon never asked for confirmation")
        self.assertEqual(prompt["fileCount"], 1)
        self.assertEqual(self.ctl("respond", prompt["id"], "accept")["accepted"], True)

        thread.join(10)
        self.assertEqual(result["status"], 200)
        token = result["body"]["files"]["file-1"]
        session_id = result["body"]["sessionId"]

        blob = bytes(range(256)) * 16
        conn = http.client.HTTPSConnection(
            "127.0.0.1", port, timeout=20, context=self.client_context(cert)
        )
        conn.request(
            "POST",
            f"/api/localsend/v2/upload?sessionId={session_id}&fileId=file-1&token={token}",
            body=blob,
            headers={"Content-Type": "application/octet-stream", "Content-Length": str(len(blob))},
        )
        upload = conn.getresponse()
        self.assertEqual(upload.status, 200)
        saved_to = Path(json.loads(upload.read())["savedTo"])
        self.assertTrue(saved_to.exists())
        self.assertEqual(saved_to.read_bytes(), blob)

        state = self.ctl("state")
        self.assertTrue(state["ok"])
        self.assertEqual(state["sessions"][0]["status"], "done")
        self.assertEqual(state["sessions"][0]["bytesDone"], len(blob))

        deadline = time.time() + 10
        history: list = []
        while time.time() < deadline and not history:
            history = self.ctl("history")["entries"]
            time.sleep(0.2)
        self.assertEqual(history[0]["status"], "done")
        self.assertEqual(history[0]["files"][0]["name"], "hello.bin")
        # The widget opens entries from history, so the recorded path must be the real one.
        self.assertEqual(Path(history[0]["files"][0]["path"]), saved_to.resolve())
        # The temp name is only an implementation detail: nothing may survive under it.
        self.assertEqual(list(saved_to.parent.glob("*" + mod.PART_SUFFIX)), [])

    def _prepare(self, port: int, cert, files: dict, fingerprint: str = "e" * 64):
        payload = {
            "info": {"alias": "phone", "fingerprint": fingerprint, "port": 1234},
            "files": files,
        }
        conn = http.client.HTTPSConnection(
            "127.0.0.1", port, timeout=20, context=self.client_context(cert)
        )
        result: dict = {}

        def do_prepare():
            body = json.dumps(payload).encode()
            conn.request(
                "POST",
                "/api/localsend/v2/prepare-upload",
                body=body,
                headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
            )
            resp = conn.getresponse()
            result["status"] = resp.status
            result["body"] = json.loads(resp.read() or b"{}")

        thread = threading.Thread(target=do_prepare)
        thread.start()
        prompt = None
        deadline = time.time() + 10
        while time.time() < deadline and prompt is None:
            prompts = self.ctl("state").get("prompts") or []
            prompt = prompts[0] if prompts else None
            time.sleep(0.1)
        self.assertIsNotNone(prompt, "daemon never asked for confirmation")
        self.assertEqual(self.ctl("respond", prompt["id"], "accept")["accepted"], True)
        thread.join(10)
        self.assertEqual(result["status"], 200)
        return result["body"]["sessionId"], result["body"]["files"]

    def _upload_socket(self, port: int, cert, session_id: str, file_id: str, token: str, size: int):
        ctx = self.client_context(cert)
        raw = ctx.wrap_socket(
            socket.create_connection(("127.0.0.1", port), timeout=20), server_hostname="127.0.0.1"
        )
        target = f"/api/localsend/v2/upload?sessionId={session_id}&fileId={file_id}&token={token}"
        raw.sendall(
            (
                f"POST {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                f"Content-Type: application/octet-stream\r\nContent-Length: {size}\r\n"
                "Connection: close\r\n\r\n"
            ).encode()
        )
        return raw

    def _wait_terminal(self, seconds: float = 15) -> dict:
        deadline = time.time() + seconds
        session: dict = {}
        while time.time() < deadline:
            sessions = self.ctl("state").get("sessions") or []
            if sessions:
                session = sessions[0]
                if session["status"] in ("done", "error", "cancelled", "declined", "timed out"):
                    return session
            time.sleep(0.1)
        self.fail(f"session never finished: {session}")

    def test_truncated_body_leaves_no_file(self):
        port = free_port()
        downloads = self.tmp / "downloads"
        self.start_daemon(port, "--download-dir", str(downloads))
        cert = mod.ensure_cert()
        session_id, tokens = self._prepare(
            port,
            cert,
            {"file-1": {"id": "file-1", "fileName": "cut.bin", "size": 8192}},
        )
        raw = self._upload_socket(port, cert, session_id, "file-1", tokens["file-1"], 8192)
        raw.sendall(b"x" * 1024)
        # Let the daemon consume those bytes, then end the body cleanly: a FIN after a short body
        # must be reported as a short transfer, not as a transport error.
        time.sleep(0.3)
        raw.shutdown(socket.SHUT_WR)

        session = self._wait_terminal()
        raw.close()
        self.assertEqual(session["status"], "error")
        self.assertIn("short transfer", session["error"] or "")
        self.assertEqual(session["files"][0]["status"], "error")
        self.assertEqual(session["files"][0]["bytes"], 1024)
        self.assertNotIn("path", session["files"][0])
        self.assertEqual(list(downloads.iterdir()), [], "partial download left behind")

    def test_reset_connection_leaves_no_file(self):
        port = free_port()
        downloads = self.tmp / "downloads"
        self.start_daemon(port, "--download-dir", str(downloads))
        cert = mod.ensure_cert()
        session_id, tokens = self._prepare(
            port,
            cert,
            {"file-1": {"id": "file-1", "fileName": "rst.bin", "size": 4096}},
        )
        raw = self._upload_socket(port, cert, session_id, "file-1", tokens["file-1"], 4096)
        raw.sendall(b"z" * 512)
        time.sleep(0.2)
        # Reset instead of a clean FIN: the peer vanishes without closing the body politely.
        raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        raw.close()

        session = self._wait_terminal()
        self.assertEqual(session["status"], "error", session["error"])
        self.assertEqual(session["files"][0]["status"], "error")
        self.assertLess(session["files"][0]["bytes"], 4096)
        self.assertEqual(list(downloads.iterdir()), [], "aborted download left behind")

    def test_cancel_mid_upload_discards_partial(self):
        port = free_port()
        downloads = self.tmp / "downloads"
        self.start_daemon(port, "--download-dir", str(downloads))
        cert = mod.ensure_cert()
        session_id, tokens = self._prepare(
            port,
            cert,
            {"file-1": {"id": "file-1", "fileName": "cut.bin", "size": 65536}},
        )
        raw = self._upload_socket(port, cert, session_id, "file-1", tokens["file-1"], 65536)
        raw.sendall(b"y" * 4096)
        self.assertTrue(self.ctl("cancel", session_id)["ok"])
        raw.close()

        session = self._wait_terminal()
        self.assertEqual(session["status"], "cancelled", session["error"])
        self.assertEqual(list(downloads.iterdir()), [], "cancelled download left behind")

    def test_decline_answers_403(self):
        port = free_port()
        self.start_daemon(port)
        cert = mod.ensure_cert()
        payload = {
            "info": {"alias": "phone", "fingerprint": "a" * 64, "port": 1234},
            "files": {"f": {"id": "f", "fileName": "x.txt", "size": 3}},
        }
        conn = http.client.HTTPSConnection(
            "127.0.0.1", port, timeout=20, context=self.client_context(cert)
        )
        result: dict = {}

        def do_prepare():
            body = json.dumps(payload).encode()
            conn.request(
                "POST",
                "/api/localsend/v2/prepare-upload",
                body=body,
                headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
            )
            resp = conn.getresponse()
            result["status"] = resp.status
            resp.read()

        thread = threading.Thread(target=do_prepare)
        thread.start()
        prompt = None
        deadline = time.time() + 10
        while time.time() < deadline and prompt is None:
            prompts = self.ctl("state").get("prompts") or []
            prompt = prompts[0] if prompts else None
            time.sleep(0.1)
        self.assertIsNotNone(prompt)
        self.ctl("respond", prompt["id"], "reject")
        thread.join(10)
        self.assertEqual(result["status"], 403)
        self.assertEqual(self.ctl("state")["sessions"][0]["status"], "declined")

    def test_pin_is_enforced(self):
        port = free_port()
        self.start_daemon(port, "--pin", "4242")
        cert = mod.ensure_cert()
        payload = {
            "info": {"alias": "phone", "fingerprint": "b" * 64, "port": 1234},
            "files": {"f": {"id": "f", "fileName": "x.txt", "size": 3}},
        }
        body = json.dumps(payload).encode()
        conn = http.client.HTTPSConnection(
            "127.0.0.1", port, timeout=10, context=self.client_context(cert)
        )
        conn.request(
            "POST",
            "/api/localsend/v2/prepare-upload",
            body=body,
            headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
        )
        resp = conn.getresponse()
        resp.read()
        self.assertEqual(resp.status, 401)

    def test_second_instance_refuses(self):
        port = free_port()
        self.start_daemon(port)
        second = subprocess.run(
            [sys.executable, str(DAEMON), "--port", str(port + 1)],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertIn("another instance", second.stderr)
        self.assertEqual(len(self.ctl("state")["peers"]), 0)


class SettingsPersistenceTests(HermeticDirs):
    """Starred devices and the trust checkbox must survive a daemon restart."""

    def test_favorite_and_auto_accept_survive_restart(self):
        port = free_port()
        proc = self.start_daemon(port)
        fingerprint = "a" * 64
        self.assertTrue(self.ctl("favorite", fingerprint, "on")["ok"])
        self.assertTrue(self.ctl("auto-accept", "on")["ok"])
        self.ctl("shutdown")
        proc.wait(timeout=10)

        self.start_daemon(port)
        snapshot = self.ctl("state")
        self.assertEqual(snapshot["favorites"], [fingerprint])
        self.assertTrue(snapshot["autoAcceptFavorites"])

        self.ctl("favorite", fingerprint, "off")
        self.ctl("auto-accept", "off")
        self.ctl("shutdown")
        self.procs[-1].wait(timeout=10)
        self.start_daemon(port)
        snapshot = self.ctl("state")
        self.assertEqual(snapshot["favorites"], [])
        self.assertFalse(snapshot["autoAcceptFavorites"])

    def test_scan_answers_when_discovery_is_off(self):
        self.start_daemon(free_port())
        result = self.ctl("scan")
        self.assertTrue(result["ok"])
        self.assertFalse(result["scanning"])
        self.assertIn("peers", result)

class FakeReceiver(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class SendFlowTests(unittest.TestCase):
    """The daemon-side sender, exercised against a stand-in receiver, no discovery involved."""

    def test_send_streams_file(self):
        cfgdir = tempfile.mkdtemp(prefix="lsd-send-")
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = cfgdir
        try:
            cert = mod.ensure_cert()
            received: dict = {}
            port = free_port()

            class Handler(BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_POST(self):
                    length = int(self.headers.get("Content-Length") or 0)
                    body = self.rfile.read(length)
                    if self.path.startswith("/api/localsend/v2/prepare-upload"):
                        payload = json.loads(body)
                        files = {fid: "tok-" + fid for fid in payload["files"]}
                        received["prepare"] = True
                        reply = json.dumps({"sessionId": "remote-1", "files": files}).encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(reply)))
                        self.end_headers()
                        self.wfile.write(reply)
                        return
                    if self.path.startswith("/api/localsend/v2/upload"):
                        received.setdefault("data", b"")
                        received["data"] += body
                        received["query"] = self.path
                        reply = b'{"savedTo":"/tmp/x"}'
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(reply)))
                        self.end_headers()
                        self.wfile.write(reply)
                        return
                    self.send_response(404)
                    self.end_headers()

            httpd = FakeReceiver(("127.0.0.1", port), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(str(cert.cert_path), str(cert.key_path))
            httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
            threading.Thread(target=httpd.serve_forever, daemon=True).start()

            workdir = Path(cfgdir) / "files"
            workdir.mkdir()
            source = workdir / "payload.txt"
            blob = b"localsend python backend\n" * 5000
            source.write_bytes(blob)

            state = mod.AppState(
                {
                    "alias": "sender",
                    "port": 1,
                    "download_dir": str(workdir),
                    "pin": None,
                    "fingerprint": cert.fingerprint,
                    "favorites": [],
                    "auto_accept_favorites": False,
                },
                {
                    "alias": "sender",
                    "version": mod.APP_VERSION,
                    "deviceModel": "Linux",
                    "deviceType": "desktop",
                    "fingerprint": cert.fingerprint,
                    "port": 1,
                    "protocol": "https",
                    "download": False,
                },
            )
            peer = {
                "fingerprint": "c" * 64,
                "alias": "receiver",
                "ip": "127.0.0.1",
                "port": port,
                "protocol": "https",
            }
            session_id = mod.start_send(state, peer, [str(source)], cert)
            deadline = time.time() + 30
            while time.time() < deadline:
                session = state.sessions[session_id]
                if session.status in ("done", "error"):
                    break
                time.sleep(0.05)
            session = state.sessions[session_id]
            self.assertEqual(session.status, "done", session.error)
            self.assertEqual(session.files[0]["bytes"], len(blob))
            self.assertEqual(received["data"], blob)
            self.assertIn("token=tok-", received["query"])

            # History keeps the source path so the widget can open or reveal the sent file.
            state.sync_history()
            self.assertEqual(Path(state.history.entries[0]["files"][0]["path"]), source.resolve())
            httpd.shutdown()
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME", None)
            else:
                os.environ["XDG_CONFIG_HOME"] = old
            shutil.rmtree(cfgdir, ignore_errors=True)

    def test_cancel_stops_sender(self):
        cfgdir = tempfile.mkdtemp(prefix="lsd-cancel-")
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = cfgdir
        try:
            cert = mod.ensure_cert()
            received: dict = {"bytes": 0}
            port = free_port()

            class SlowHandler(BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_POST(self):
                    if self.path.startswith("/api/localsend/v2/prepare-upload"):
                        length = int(self.headers.get("Content-Length") or 0)
                        payload = json.loads(self.rfile.read(length))
                        files = {fid: "tok-" + fid for fid in payload["files"]}
                        reply = json.dumps({"sessionId": "remote-2", "files": files}).encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(reply)))
                        self.end_headers()
                        self.wfile.write(reply)
                        return
                    if self.path.startswith("/api/localsend/v2/upload"):
                        length = int(self.headers.get("Content-Length") or 0)
                        total = 0
                        # Read slowly so the sender is still streaming when the test cancels.
                        while total < length:
                            chunk = self.rfile.read(min(64 * 1024, length - total))
                            if not chunk:
                                break
                            total += len(chunk)
                            received["bytes"] = total
                            time.sleep(0.01)
                        received["complete"] = total == length
                        try:
                            reply = b'{"savedTo":"/tmp/x"}'
                            self.send_response(200)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(reply)))
                            self.end_headers()
                            self.wfile.write(reply)
                        except OSError:
                            pass
                        return
                    self.send_response(404)
                    self.end_headers()

            httpd = FakeReceiver(("127.0.0.1", port), SlowHandler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(str(cert.cert_path), str(cert.key_path))
            httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
            threading.Thread(target=httpd.serve_forever, daemon=True).start()

            workdir = Path(cfgdir) / "files"
            workdir.mkdir()
            source = workdir / "big.bin"
            blob = os.urandom(8 * 1024 * 1024)
            source.write_bytes(blob)

            state = mod.AppState(
                {
                    "alias": "sender",
                    "port": 1,
                    "download_dir": str(workdir),
                    "pin": None,
                    "fingerprint": cert.fingerprint,
                    "favorites": [],
                    "auto_accept_favorites": False,
                },
                {
                    "alias": "sender",
                    "version": mod.APP_VERSION,
                    "deviceModel": "Linux",
                    "deviceType": "desktop",
                    "fingerprint": cert.fingerprint,
                    "port": 1,
                    "protocol": "https",
                    "download": False,
                },
            )
            peer = {
                "fingerprint": "c" * 64,
                "alias": "receiver",
                "ip": "127.0.0.1",
                "port": port,
                "protocol": "https",
            }
            session_id = mod.start_send(state, peer, [str(source)], cert)

            deadline = time.time() + 20
            while time.time() < deadline:
                if state.sessions[session_id].bytes_done > 0:
                    break
                time.sleep(0.01)
            with state.lock:
                state.sessions[session_id].status = "cancelled"

            # "cancelled" is already terminal, so wait for the worker to act on it rather than
            # for the status the test itself just wrote.
            deadline = time.time() + 20
            while time.time() < deadline:
                session = state.sessions[session_id]
                if session.error == "cancelled by user" or session.status in ("done", "error"):
                    break
                time.sleep(0.02)
            session = state.sessions[session_id]
            self.assertEqual(session.status, "cancelled", session.error)
            self.assertEqual(session.error, "cancelled by user")
            self.assertFalse(any(f["status"] == "done" for f in session.files))
            self.assertLess(received["bytes"], len(blob), "receiver got the whole file anyway")
            httpd.shutdown()
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME", None)
            else:
                os.environ["XDG_CONFIG_HOME"] = old
            shutil.rmtree(cfgdir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
