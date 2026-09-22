#!/usr/bin/env python3
"""FileHub 端到端集成测试，仅依赖 Python 标准库。"""
import hashlib
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parents[1]
BINARY = PROJECT / os.environ.get("FILEHUB_BIN", "filehub")


def unused_port():
    """让内核分配一个当前空闲的回环端口。"""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def response(stream, head=False):
    """从已连接的二进制流中读取一条完整 HTTP/1.1 响应。"""
    status_line = stream.readline()
    if not status_line:
        raise AssertionError("connection closed before response")
    status = int(status_line.split()[1])
    headers = {}
    while (line := stream.readline()) != b"\r\n":
        if not line:
            raise AssertionError("incomplete response headers")
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()
    length = int(headers["content-length"])
    # HEAD 响应仍携带 Content-Length，但协议规定不发送响应正文。
    body = b"" if head else stream.read(length)
    if not head and len(body) != length:
        raise AssertionError("incomplete response body")
    return status, headers, body


class FileHubIntegration(unittest.TestCase):
    """在独立临时站点和真实 TCP 连接上验证服务行为。"""

    @classmethod
    def setUpClass(cls):
        """创建测试文件并启动一份由测试进程独占的 FileHub 实例。"""
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.payload = os.urandom(4 * 1024 * 1024)
        (cls.root / "index.html").write_text("hello filehub\n", encoding="utf-8")
        (cls.root / "archive.bin").write_bytes(cls.payload)
        (cls.root / "notes.txt").write_text("notes\n", encoding="utf-8")
        (cls.root / "outside").symlink_to("/etc/passwd")
        cls.port = unused_port()
        cls.server = subprocess.Popen(
            [str(BINARY), "--port", str(cls.port), "--root", str(cls.root)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # 轮询实际 TCP 可连接状态，避免用固定 sleep 猜测启动时间。
        for _ in range(100):
            if cls.server.poll() is not None:
                raise RuntimeError(cls.server.stderr.read().decode())
            try:
                with socket.create_connection(("127.0.0.1", cls.port), 0.1):
                    break
            except OSError:
                time.sleep(0.02)
        else:
            raise RuntimeError("server did not start")

    @classmethod
    def tearDownClass(cls):
        """请求优雅退出；超时才强制终止，并确认服务正常返回。"""
        cls.server.send_signal(signal.SIGTERM)
        try:
            cls.server.wait(timeout=7)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait()
        assert cls.server.returncode == 0, cls.server.stderr.read().decode()
        cls.server.stderr.close()
        cls.temp.cleanup()

    def request(self, request_bytes, head=False):
        """每次新建连接发送原始请求，便于覆盖异常报文。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.settimeout(5)
            stream = sock.makefile("rb")
            sock.sendall(request_bytes)
            return response(stream, head=head)

    def test_keepalive_and_pipeline(self):
        """同一连接连续发送两个请求，验证流水线顺序和关闭语义。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.settimeout(5)
            stream = sock.makefile("rb")
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
                         b"GET /notes.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            first = response(stream)
            second = response(stream)
            self.assertEqual((first[0], first[2]), (200, b"hello filehub\n"))
            self.assertEqual(first[1]["connection"], "keep-alive")
            self.assertEqual((second[0], second[2]), (200, b"notes\n"))
            self.assertEqual(second[1]["connection"], "close")

    def test_fragmented_request(self):
        """把请求头拆成多次 send，验证 TCP 分片不会影响解析。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.settimeout(5)
            stream = sock.makefile("rb")
            for part in (b"GET /notes", b".txt HTTP/1.1\r\n", b"Host: x\r\n\r\n"):
                sock.sendall(part)
                time.sleep(0.01)
            self.assertEqual(response(stream)[2], b"notes\n")

    def test_head_and_range(self):
        """验证 HEAD 无正文，以及 Range 的状态码、响应头和字节内容。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.settimeout(5)
            stream = sock.makefile("rb")
            sock.sendall(b"HEAD /archive.bin HTTP/1.1\r\nHost: x\r\n\r\n")
            status, headers, body = response(stream, head=True)
            self.assertEqual((status, int(headers["content-length"]), body), (200, len(self.payload), b""))
            sock.sendall(b"GET /archive.bin HTTP/1.1\r\nHost: x\r\nRange: bytes=100-199\r\n\r\n")
            status, headers, body = response(stream)
            self.assertEqual((status, headers["content-range"], body),
                             (206, f"bytes 100-199/{len(self.payload)}", self.payload[100:200]))

    def test_range_errors_and_path_escape(self):
        """覆盖后缀范围、越界范围、目录穿越和符号链接逃逸。"""
        status, _, body = self.request(b"GET /notes.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=-3\r\n\r\n")
        self.assertEqual((status, body), (206, b"es\n"))
        status, headers, _ = self.request(b"GET /notes.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=999-\r\n\r\n")
        self.assertEqual((status, headers["content-range"]), (416, "bytes */6"))
        for path in ("/%2e%2e/etc/passwd", "/outside", "/foo/../notes.txt"):
            status, _, _ = self.request(f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
            self.assertEqual(status, 403, path)

    def test_metrics(self):
        """验证 JSON/文本监控端点以及不支持方法返回 405。"""
        status, _, body = self.request(b"GET /status HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertEqual(status, 200)
        self.assertIn(b'"total_requests"', body)
        status, _, body = self.request(b"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertEqual(status, 200)
        self.assertIn(b"filehub_requests_total", body)
        status, _, _ = self.request(b"POST /status HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertEqual(status, 405)

    def test_slow_large_download_integrity(self):
        """慢速读取大文件时，验证服务公平性、EAGAIN 路径和内容哈希。"""
        _, _, initial_status = self.request(b"GET /status HTTP/1.1\r\nHost: x\r\n\r\n")
        before_eagain = int(initial_status.decode().split('"write_eagain":')[1].split('}')[0])
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            sock.settimeout(30)
            sock.connect(("127.0.0.1", self.port))
            stream = sock.makefile("rb")
            sock.sendall(b"GET /archive.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            self.assertIn(b"200", stream.readline())
            while stream.readline() != b"\r\n":
                pass
            # 一个客户端暂停读取时，另一个普通请求仍必须及时完成。
            self.assertEqual(self.request(b"GET /notes.txt HTTP/1.1\r\nHost: x\r\n\r\n")[2], b"notes\n")
            digest = hashlib.sha256()
            received = 0
            while received < len(self.payload):
                part = stream.read(min(4096, len(self.payload) - received))
                self.assertTrue(part)
                digest.update(part)
                received += len(part)
                time.sleep(0.0002)
            self.assertEqual(digest.digest(), hashlib.sha256(self.payload).digest())
        status, _, body = self.request(b"GET /status HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertEqual(status, 200)
        self.assertGreater(int(body.decode().split('"write_eagain":')[1].split('}')[0]), before_eagain)

    def test_disconnect_during_file_download(self):
        """客户端在下载中途断开后，服务不应崩溃或影响后续请求。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.sendall(b"GET /archive.bin HTTP/1.1\r\nHost: x\r\n\r\n")
            sock.recv(4096)
        status, _, body = self.request(b"GET /notes.txt HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertEqual((status, body), (200, b"notes\n"))

    def test_config_reload_and_timeout(self):
        """SIGHUP 热加载超时配置后，慢请求应按新值返回 408。"""
        port = unused_port()
        config_file = self.root / "filehub.conf"
        config_file.write_text(f"listen_port={port}\ndocument_root={self.root}\n"
                               "request_timeout=3\nkeepalive_timeout=3\nwrite_timeout=3\n")
        process = subprocess.Popen([str(BINARY), "--config", str(config_file)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(("127.0.0.1", port), 0.1):
                        break
                except OSError:
                    time.sleep(0.02)
            else:
                self.fail("configuration-based server did not start")
            config_file.write_text(f"listen_port={port}\ndocument_root={self.root}\n"
                                   "request_timeout=1\nkeepalive_timeout=1\nwrite_timeout=1\n")
            process.send_signal(signal.SIGHUP)
            time.sleep(0.1)
            with socket.create_connection(("127.0.0.1", port), 3) as sock:
                sock.settimeout(4)
                stream = sock.makefile("rb")
                sock.sendall(b"GET / HTTP/1.1\r\nHost:")
                self.assertEqual(response(stream)[0], 408)
        finally:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=7)
            self.assertEqual(process.returncode, 0, process.stderr.read().decode())
            process.stderr.close()

    def test_shutdown_with_slow_receiver(self):
        """存在慢接收方时发送 SIGTERM，服务仍应在宽限期内正常退出。"""
        port = unused_port()
        process = subprocess.Popen([str(BINARY), "--port", str(port), "--root", str(self.root)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(("127.0.0.1", port), 0.1):
                        break
                except OSError:
                    time.sleep(0.02)
            else:
                self.fail("shutdown-test server did not start")
            with socket.socket() as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                sock.settimeout(2)
                sock.connect(("127.0.0.1", port))
                sock.sendall(b"GET /archive.bin HTTP/1.1\r\nHost: x\r\n\r\n")
                self.assertIn(b"200", sock.recv(4096))
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=7), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
