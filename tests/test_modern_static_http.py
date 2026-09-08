"""Exercise production static locations with an isolated loopback-only nginx.

Uses a private fixture document root and an intentionally old MIME table (js,
but no mjs). No installed nginx configuration, service, or device is modified.
"""

import base64
import hashlib
import http.client
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
NGINX = shutil.which("nginx")
SOURCE = REPO / "teslausb-www" / "teslausb.nginx"
MODULE_LOCATION = "location ~ ^/modern/.*\\.mjs$ {"


class StaticConfigurationTests(unittest.TestCase):
    def test_module_location_keeps_server_auth_and_headers(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(source.count(MODULE_LOCATION), 1)
        # Both closing braces are needed because the location contains types.
        location = source.split(MODULE_LOCATION, 1)[1].split("\n    }", 1)[0]
        self.assertIn("try_files $uri =404;", location)
        self.assertIn("types { application/javascript mjs; }", location)
        for directive in ("auth_basic", "add_header", "alias", "root", "fastcgi", "proxy_pass"):
            self.assertNotIn(directive, location)


@unittest.skipUnless(os.name == "posix" and NGINX, "requires Linux nginx (including fancyindex)")
class ModernStaticHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="teslausb-static-http-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.web = cls.base / "html"
        cls.web.mkdir()
        cls.modules = {}
        for name in ("app.mjs", "player.mjs", "model.mjs", "connection.mjs"):
            content = (REPO / "teslausb-www" / "html" / "modern" / name).read_bytes()
            cls.modules[name] = content
            cls.fixture("modern/" + name, content)
        cls.fixture("modern/connection.css", b".connection-banner { display: flex; }\n")
        cls.fixture("outside.mjs", b"export const outside = true;\n")
        for prefix in ("fs/Music", "TeslaCam/SavedClips/event"):
            for extension in ("mjs", "MJS", "js"):
                cls.fixture(prefix + "/upload." + extension, b"export const upload = true;\n")
        cls.fixture("TeslaCam/EncryptedClips/secret.mjs", b"not for the web\n")

        cls.authorization = "Basic " + base64.b64encode(b"fixture:local-test-only").decode("ascii")
        digest = base64.b64encode(hashlib.sha1(b"local-test-only").digest()).decode("ascii")
        credentials = cls.base / "htpasswd"
        credentials.write_text("fixture:{SHA}" + digest + "\n", encoding="ascii")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]

        site = SOURCE.read_text(encoding="utf-8")
        site = site.replace("listen 80 default_server;", f"listen 127.0.0.1:{cls.port} default_server;")
        site = site.replace("listen [::]:80 default_server;", "")
        site = site.replace("/var/www/html", str(cls.web))
        site = site.replace("auth_basic off;", 'auth_basic "Static fixture";')
        site = site.replace("/etc/nginx/.htpasswd", str(credentials))
        cls.config = cls.base / "nginx.conf"
        # Load packaged dynamic modules (including fancyindex), but never the
        # installed http/server config. All runtime writes stay in this fixture.
        runtime = "\n".join(f'{kind}_temp_path "{cls.base / kind}";' for kind in
                            ("client_body", "proxy", "fastcgi", "uwsgi", "scgi"))
        cls.config.write_text(
            'include /etc/nginx/modules-enabled/*.conf;\n'
            f'pid "{cls.base / "nginx.pid"}";\nerror_log stderr warn;\n'
            'events { worker_connections 32; }\nhttp {\n'
            'types { text/html html; text/css css; application/javascript js; }\n'
            'default_type application/octet-stream;\naccess_log off;\n' + runtime + "\n" + site + "\n}\n",
            encoding="utf-8")
        command = [NGINX, "-p", str(cls.base) + "/", "-c", str(cls.config)]
        checked = subprocess.run(command + ["-t"], capture_output=True, text=True, timeout=10)
        if checked.returncode:
            raise AssertionError("Isolated nginx configuration failed: " + checked.stderr)
        cls.log = (cls.base / "process.log").open("w+b")
        cls.addClassCleanup(cls.log.close)
        cls.process = subprocess.Popen(command + ["-g", "daemon off; master_process off;"],
                                       stdout=subprocess.DEVNULL, stderr=cls.log)
        cls.addClassCleanup(cls.stop_nginx)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                cls.log.seek(0)
                raise AssertionError("Isolated nginx exited: " + cls.log.read().decode("utf-8", "replace"))
            try:
                connection = socket.create_connection(("127.0.0.1", cls.port), timeout=.2)
                connection.close()
                return
            except OSError:
                time.sleep(.05)
        raise AssertionError("Isolated nginx did not start")

    @classmethod
    def fixture(cls, path, content):
        target = cls.web / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    @classmethod
    def stop_nginx(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait(timeout=5)

    def request(self, path, *, authorized=True, host="localhost"):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            headers = {"Host": host}
            if authorized:
                headers["Authorization"] = self.authorization
            connection.request("GET", path, headers=headers)
            response = connection.getresponse()
            return response.status, dict((key.lower(), value) for key, value in response.getheaders()), response.read()
        finally:
            connection.close()

    def security_headers(self, headers):
        self.assertEqual(headers.get("x-content-type-options"), "nosniff")
        self.assertEqual(headers.get("referrer-policy"), "same-origin")
        self.assertEqual(headers.get("x-frame-options"), "SAMEORIGIN")
        self.assertEqual(headers.get("cross-origin-resource-policy"), "same-origin")
        self.assertEqual(headers.get("content-security-policy"), "frame-ancestors 'self'; object-src 'none'; base-uri 'self'")

    def test_actual_modules_are_javascript_with_old_os_mime_table(self):
        for name, original in self.modules.items():
            with self.subTest(module=name):
                status, headers, content = self.request("/modern/" + name + "?v=fixture")
                self.assertEqual(status, 200)
                self.assertEqual(headers.get("content-type"), "application/javascript")
                self.assertEqual(content, original)
                self.assertNotIn("content-disposition", headers)
                self.security_headers(headers)

    def test_mapping_does_not_change_css_or_unrelated_module_types(self):
        for path, mime in (("/modern/connection.css", "text/css"), ("/outside.mjs", "application/octet-stream")):
            with self.subTest(path=path):
                status, headers, _ = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(headers.get("content-type"), mime)
                self.security_headers(headers)

    def test_missing_module_is_404_with_security_headers(self):
        status, headers, _ = self.request("/modern/missing.mjs")
        self.assertEqual(status, 404)
        self.security_headers(headers)

    def test_module_inherits_basic_auth(self):
        status, headers, content = self.request("/modern/connection.mjs", authorized=False)
        self.assertEqual(status, 401)
        self.assertIn("Basic", headers.get("www-authenticate", ""))
        self.assertNotEqual(content, self.modules["connection.mjs"])
        self.security_headers(headers)

    def test_module_inherits_host_gate_even_with_valid_auth(self):
        status, headers, _ = self.request("/modern/connection.mjs", host="fd-attacker.example")
        self.assertEqual(status, 421)
        self.security_headers(headers)

    def test_uploaded_modules_remain_authenticated_downloads(self):
        for prefix in ("/fs/Music", "/TeslaCam/SavedClips/event"):
            for extension in ("mjs", "MJS", "js"):
                with self.subTest(prefix=prefix, extension=extension):
                    path = prefix + "/upload." + extension
                    status, headers, _ = self.request(path)
                    self.assertEqual(status, 200)
                    self.assertEqual(headers.get("content-type"), "application/octet-stream")
                    self.assertEqual(headers.get("content-disposition"), "attachment")
                    self.security_headers(headers)
                    self.assertEqual(self.request(path, authorized=False)[0], 401)

    def test_normalized_path_cannot_apply_trusted_mime_to_uploads(self):
        for path in ("/modern/../fs/Music/upload.mjs", "/modern/%2e%2e/fs/Music/upload.mjs"):
            with self.subTest(path=path):
                status, headers, _ = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(headers.get("content-type"), "application/octet-stream")
                self.assertEqual(headers.get("content-disposition"), "attachment")

    def test_encrypted_modules_remain_unavailable(self):
        self.assertEqual(self.request("/TeslaCam/EncryptedClips/secret.mjs")[0], 404)


if __name__ == "__main__":
    unittest.main()
