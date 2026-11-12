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
            httpd.shutdown()
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME", None)
            else:
                os.environ["XDG_CONFIG_HOME"] = old
            shutil.rmtree(cfgdir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
