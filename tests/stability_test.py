#!/usr/bin/env python3
"""FileHub 混合负载稳定性测试，仅依赖 Python 标准库。"""

import argparse
from collections import Counter
import hashlib
import http.client
import json
import os
from pathlib import Path
import random
import re
import signal
import socket
import subprocess
import tempfile
import threading
import time
import traceback


PROJECT = Path(__file__).resolve().parents[1]


def free_port():
    """申请一个临时回环端口，降低并行测试时的端口冲突概率。"""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_ready(process, port):
    """等待服务真正接受连接，并在进程提前退出时立即报告日志。"""
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(process.stderr.read().decode())
        try:
            with socket.create_connection(("127.0.0.1", port), 0.1):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("server did not start")


def request(port, path, headers=None):
    """执行一次短连接 GET，并返回状态码、响应头和完整正文。"""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        body = response.read()
        return response.status, dict(response.getheaders()), body
    finally:
        connection.close()


def proc_value(pid, key):
    """从 /proc/<pid>/status 读取以 KiB 表示的进程指标。"""
    text = Path(f"/proc/{pid}/status").read_text()
    match = re.search(rf"^{key}:\s+(\d+)\s+kB", text, re.MULTILINE)
    return int(match.group(1)) if match else None


class Workload:
    """一个并发客户端，按固定随机种子循环执行混合操作。"""

    def __init__(self, port, payloads, stop, counts, errors, lock, seed):
        self.port = port
        self.payloads = payloads
        self.stop = stop
        self.counts = counts
        self.errors = errors
        self.lock = lock
        self.random = random.Random(seed)
        self.hashes = {
            name: hashlib.sha256(payload).digest()
            for name, payload in payloads.items()
        }

    def record(self, name):
        """在共享锁保护下累计成功操作次数。"""
        with self.lock:
            self.counts[name] += 1

    def full_download(self):
        """下载随机大小文件并用 SHA-256 验证完整性。"""
        name = self.random.choice(tuple(self.payloads))
        status, _, body = request(self.port, f"/{name}")
        if status != 200 or hashlib.sha256(body).digest() != self.hashes[name]:
            raise AssertionError(f"full download failed: {name}, status={status}")
        self.record("full_download")

    def range_download(self):
        """随机选择合法区间，核对 206、Content-Range 与正文。"""
        name = self.random.choice(tuple(self.payloads))
        payload = self.payloads[name]
        start = self.random.randrange(len(payload))
        length = min(self.random.randint(1, 65536), len(payload) - start)
        end = start + length - 1
        status, headers, body = request(
            self.port, f"/{name}", {"Range": f"bytes={start}-{end}"}
        )
        expected_range = f"bytes {start}-{end}/{len(payload)}"
        if (
            status != 206
            or headers.get("Content-Range") != expected_range
            or body != payload[start:end + 1]
        ):
            raise AssertionError(f"range download failed: {name}, {start}-{end}")
        self.record("range_download")

    def status_request(self):
        """访问监控端点并验证返回 JSON 的关键字段。"""
        status, _, body = request(self.port, "/status")
        metrics = json.loads(body)
        if status != 200 or "active_connections" not in metrics:
            raise AssertionError("status endpoint failed")
        self.record("status")

    def fragmented_request(self):
        """分三次发送请求头，持续覆盖增量解析路径。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.settimeout(5)
            for part in (
                b"GET /small.bin",
                b" HTTP/1.1\r\nHost: ",
                b"localhost\r\nConnection: close\r\n\r\n",
            ):
                sock.sendall(part)
                time.sleep(0.001)
            response = http.client.HTTPResponse(sock)
            response.begin()
            body = response.read()
            if (
                response.status != 200
                or hashlib.sha256(body).digest() != self.hashes["small.bin"]
            ):
                raise AssertionError("fragmented request failed")
        self.record("fragmented")

    def early_disconnect(self):
        """收到首批响应后主动断开，模拟取消下载的客户端。"""
        with socket.create_connection(("127.0.0.1", self.port), 3) as sock:
            sock.settimeout(3)
            sock.sendall(
                b"GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
            if not sock.recv(4096):
                raise AssertionError("server closed before sending data")
        self.record("early_disconnect")

    def run(self):
        """循环执行加权操作；首个异常会通知所有客户端停止。"""
        # 重复 full_download，提高正常下载在混合负载中的占比。
        operations = (
            self.full_download, self.full_download, self.range_download,
            self.status_request, self.fragmented_request, self.early_disconnect,
        )
        while not self.stop.is_set():
            try:
                self.random.choice(operations)()
            except Exception:
                if self.stop.is_set():
                    return
                with self.lock:
                    self.errors.append(traceback.format_exc())
                self.stop.set()
                return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=PROJECT / "filehub")
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--clients", type=int, default=12)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.duration < 1 or args.clients < 1:
        parser.error("duration and clients must be positive")
    if not args.binary.is_file():
        parser.error(f"binary is unavailable: {args.binary}")
    output = args.output or (
        PROJECT / "tests" / "results"
        / time.strftime("stability-%Y%m%d-%H%M%S.json")
    )
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="filehub-stability-") as directory:
        root = Path(directory)
        # 固定文件尺寸覆盖小响应、常规文件和会触发多次发送的大文件。
        payloads = {
            "tiny.bin": bytes(range(64)),
            "small.bin": os.urandom(4096),
            "medium.bin": os.urandom(65536),
            "large.bin": os.urandom(4 * 1024 * 1024),
        }
        for name, payload in payloads.items():
            (root / name).write_bytes(payload)
        (root / "index.html").write_bytes(b"filehub stability\n")
        port = free_port()
        process = subprocess.Popen(
            [str(args.binary), "--port", str(port), "--root", str(root)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        stop = threading.Event()
        counts = Counter()
        errors = []
        lock = threading.Lock()
        threads = []
        samples = []
        started = time.monotonic()
        try:
            wait_ready(process, port)
            # 每个线程使用不同但可复现的随机序列，方便复测失败场景。
            for number in range(args.clients):
                workload = Workload(
                    port, payloads, stop, counts, errors, lock, 2026 + number
                )
                thread = threading.Thread(
                    target=workload.run, name=f"client-{number}", daemon=True
                )
                thread.start()
                threads.append(thread)
            while time.monotonic() - started < args.duration and not stop.wait(1):
                if process.poll() is not None:
                    errors.append(f"server exited early ({process.returncode})")
                    stop.set()
                    break
                status, _, body = request(port, "/status")
                metrics = json.loads(body)
                # 每秒采集资源与服务指标，用于识别 RSS/FD 随时间增长。
                samples.append({
                    "elapsed_seconds": round(time.monotonic() - started, 3),
                    "rss_kb": proc_value(process.pid, "VmRSS"),
                    "fd_count": len(os.listdir(f"/proc/{process.pid}/fd")),
                    "active_connections": metrics["active_connections"],
                    "total_requests": metrics["total_requests"],
                    "bytes_sent": metrics["bytes_sent"],
                })
            stop.set()
            for thread in threads:
                thread.join(timeout=15)
            if any(thread.is_alive() for thread in threads):
                errors.append("client thread failed to stop")

            # 停机前保留若干慢接收方，验证优雅退出不会无限等待。
            slow_clients = []
            for _ in range(min(args.clients, 16)):
                sock = socket.socket()
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                sock.settimeout(3)
                sock.connect(("127.0.0.1", port))
                sock.sendall(
                    b"GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n"
                )
                slow_clients.append(sock)
            time.sleep(0.2)
            shutdown_started = time.monotonic()
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=8)
            shutdown_seconds = time.monotonic() - shutdown_started
            for sock in slow_clients:
                sock.close()
            if process.returncode != 0:
                errors.append(f"server exit code {process.returncode}")
        finally:
            # 无论测试在哪个阶段失败，都终止线程和子进程，避免污染后续测试。
            stop.set()
            for thread in threads:
                thread.join(timeout=1)
            if process.poll() is None:
                process.kill()
                process.wait()
            server_log = process.stderr.read().decode(errors="replace")
            process.stderr.close()

        # 保存原始采样和聚合结果，既供人工复盘，也便于自动化判定。
        result = {
            "duration_seconds": round(time.monotonic() - started, 3),
            "requested_duration_seconds": args.duration,
            "clients": args.clients,
            "counts": dict(counts),
            "total_operations": sum(counts.values()),
            "errors": errors,
            "samples": samples,
            "rss_kb_min": min(item["rss_kb"] for item in samples),
            "rss_kb_max": max(item["rss_kb"] for item in samples),
            "fd_min": min(item["fd_count"] for item in samples),
            "fd_max": max(item["fd_count"] for item in samples),
            "shutdown_seconds": round(shutdown_seconds, 3),
            "exit_code": process.returncode,
            "server_log": server_log,
        }
        output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({key: value for key, value in result.items()
                          if key not in ("samples", "server_log")}, indent=2))
        print(f"results: {output}")
        if errors:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
