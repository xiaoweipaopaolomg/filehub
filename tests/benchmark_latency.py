#!/usr/bin/env python3
"""可重复执行的 FileHub 本机延迟与吞吐量基准测试。

示例：
  python tests/benchmark_latency.py --duration 5 --rounds 3
"""

import argparse
import csv
import hashlib
import http.client
import json
import os
from pathlib import Path
import random
import re
import shutil
import signal
import socket
import statistics
import subprocess
import tempfile
import time


PROJECT = Path(__file__).resolve().parents[1]
# 测试文件从 64 B 到 8 MiB，分别观察请求开销与大文件吞吐能力。
FILES = {
    "tiny": ("/tiny.bin", bytes(range(64))),
    "small": ("/index.html", b"x" * 4096),
    "medium": ("/medium.bin", b"m" * 65536),
    "large": ("/large.bin", b"filehub-" * 131072),
    "xlarge": ("/xlarge.bin", b"L" * (8 * 1024 * 1024)),
}
PATHS = {"status": "/status", **{name: path for name, (path, _) in FILES.items()}}
UNITS_MS = {"us": 0.001, "ms": 1.0, "s": 1000.0}
UNITS_MIB = {"B": 1 / (1024 * 1024), "KB": 1 / 1024, "MB": 1.0, "GB": 1024.0}


def free_port():
    """让内核选择一个当前可用的本机端口。"""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_ready(process, port):
    """轮询服务就绪状态，而不是依赖固定启动延时。"""
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(f"server exited early ({process.returncode})")
        try:
            with socket.create_connection(("127.0.0.1", port), 0.1):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("server did not start")


def check_response(name, body):
    """在记录性能前先验证响应语义和文件哈希，防止测到错误结果。"""
    if name == "status":
        if "total_requests" not in json.loads(body):
            raise RuntimeError("/status omitted total_requests")
    elif hashlib.sha256(body).digest() != hashlib.sha256(FILES[name][1]).digest():
        raise RuntimeError(f"{name} response hash mismatch")


def measure_http(port, name, repetitions=12):
    """在一个 keep-alive 连接上测量首部与完整响应的中位延迟。"""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers_ms = []
    total_ms = []
    try:
        for _ in range(repetitions):
            start = time.perf_counter()
            connection.request("GET", PATHS[name])
            response = connection.getresponse()
            headers = time.perf_counter()
            body = response.read()
            end = time.perf_counter()
            if response.status != 200:
                raise RuntimeError(f"{name} returned HTTP {response.status}")
            check_response(name, body)
            headers_ms.append((headers - start) * 1000)
            total_ms.append((end - start) * 1000)
    finally:
        connection.close()
    return {
        "headers_ms_median": round(statistics.median(headers_ms), 3),
        "total_ms_median": round(statistics.median(total_ms), 3),
    }


def parse_latency(output, percentile):
    """读取 wrk 延迟分位数并统一换算为毫秒。"""
    match = re.search(
        rf"^\s*{percentile}%\s+([0-9.]+)(us|ms|s)\s*$", output, re.MULTILINE
    )
    if not match:
        raise RuntimeError(f"wrk output omitted p{percentile}")
    return float(match.group(1)) * UNITS_MS[match.group(2)]


def parse_wrk(output):
    """把 wrk 文本输出转换为便于汇总的结构化指标。"""
    throughput = re.search(r"^Requests/sec:\s+([0-9.]+)", output, re.MULTILINE)
    requests = re.search(r"^\s*(\d+) requests in ", output, re.MULTILINE)
    if not throughput or not requests:
        raise RuntimeError(f"wrk output incomplete:\n{output}")
    # wrk 仅在发生错误时输出对应行，因此缺失代表计数为 0。
    socket_errors = re.search(
        r"Socket errors:\s*connect\s+(\d+),\s*read\s+(\d+),"
        r"\s*write\s+(\d+),\s*timeout\s+(\d+)",
        output,
    )
    non_2xx = re.search(r"Non-2xx or 3xx responses:\s*(\d+)", output)
    transfer = re.search(
        r"^Transfer/sec:\s+([0-9.]+)(B|KB|MB|GB)", output, re.MULTILINE
    )
    if not transfer:
        raise RuntimeError(f"wrk output omitted transfer rate:\n{output}")
    return {
        "requests": int(requests.group(1)),
        "rps": float(throughput.group(1)),
        "transfer_mib_s": float(transfer.group(1)) * UNITS_MIB[transfer.group(2)],
        "p50_ms": parse_latency(output, 50),
        "p99_ms": parse_latency(output, 99),
        "socket_errors": sum(map(int, socket_errors.groups())) if socket_errors else 0,
        "non_2xx": int(non_2xx.group(1)) if non_2xx else 0,
    }


def run_wrk(wrk, port, name, connections, duration):
    """执行单个 wrk 用例，并同时保留命令、原始输出和解析结果。"""
    threads = min(2, connections)
    command = [
        wrk, f"-t{threads}", f"-c{connections}", f"-d{duration}s",
        "--latency", f"http://127.0.0.1:{port}{PATHS[name]}",
    ]
    completed = subprocess.run(
        command, capture_output=True, text=True, timeout=duration + 10
    )
    output = completed.stdout + completed.stderr
    if completed.returncode:
        raise RuntimeError(f"wrk exited {completed.returncode}:\n{output}")
    return command, output, parse_wrk(output)


def rss_kb(pid):
    """读取被测进程当前常驻内存，单位为 KiB。"""
    status = Path(f"/proc/{pid}/status").read_text()
    match = re.search(r"^VmRSS:\s+(\d+) kB", status, re.MULTILINE)
    return int(match.group(1)) if match else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=PROJECT / "filehub")
    parser.add_argument("--wrk", default=shutil.which("wrk"))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--duration", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--connections", default="1,10,50")
    parser.add_argument(
        "--endpoints", default="status,tiny,small,medium,large,xlarge"
    )
    args = parser.parse_args()
    if not args.wrk or not Path(args.wrk).is_file():
        parser.error("wrk is unavailable; activate filehub-test first")
    if not args.binary.is_file():
        parser.error(f"binary is unavailable: {args.binary}")
    connections = [int(item) for item in args.connections.split(",")]
    endpoints = args.endpoints.split(",")
    if (
        args.duration < 1 or args.rounds < 1
        or not connections or any(item < 1 for item in connections)
        or not endpoints or any(item not in PATHS for item in endpoints)
    ):
        parser.error("invalid duration, rounds, connections, or endpoints")

    # 默认使用时间戳目录，避免覆盖历史基准数据。
    output_dir = args.output_dir or (
        PROJECT / "tests" / "results" / time.strftime("latency-%Y%m%d-%H%M%S")
    )
    output_dir.mkdir(parents=True, exist_ok=False)
    (output_dir / "raw").mkdir()
    print(f"results: {output_dir}", flush=True)

    with tempfile.TemporaryDirectory(prefix="filehub-latency-") as directory:
        root = Path(directory)
        for _, (path, body) in FILES.items():
            (root / path.lstrip("/")).write_bytes(body)
        port = free_port()
        process = subprocess.Popen(
            [str(args.binary), "--port", str(port), "--root", str(root)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        rows = []
        try:
            wait_ready(process, port)
            fd_before = len(os.listdir(f"/proc/{process.pid}/fd"))
            http_timings = {
                name: measure_http(port, name) for name in endpoints
            }
            # 正式计时前预热代码路径和页缓存，降低冷启动噪声。
            for name in endpoints:
                run_wrk(args.wrk, port, name, min(10, max(connections)), 1)

            cases = [(name, count) for name in endpoints for count in connections]
            for round_number in range(1, args.rounds + 1):
                order = cases[:]
                # 固定种子打乱顺序，兼顾可复现性并减少顺序偏差。
                random.Random(2026 + round_number).shuffle(order)
                for name, count in order:
                    command, output, metrics = run_wrk(
                        args.wrk, port, name, count, args.duration
                    )
                    (output_dir / "raw" / f"{name}-c{count}-r{round_number}.txt").write_text(
                        "Command: " + " ".join(command) + "\n\n" + output
                    )
                    row = {
                        "endpoint": name, "connections": count,
                        "round": round_number, "threads": min(2, count),
                        **metrics,
                    }
                    rows.append(row)
                    print(
                        f"{name:6} c={count:<2} round={round_number} "
                        f"rps={metrics['rps']:.2f} "
                        f"MiB/s={metrics['transfer_mib_s']:.2f} "
                        f"p50={metrics['p50_ms']:.2f}ms "
                        f"p99={metrics['p99_ms']:.2f}ms "
                        f"errors={metrics['socket_errors'] + metrics['non_2xx']}",
                        flush=True,
                    )
            time.sleep(0.5)
            fd_after = len(os.listdir(f"/proc/{process.pid}/fd"))
            # 保存环境信息，避免脱离硬件和参数解读性能数字。
            metadata = {
                "host": os.uname().nodename,
                "kernel": os.uname().release,
                "cpu_count": os.cpu_count(),
                "binary": str(args.binary.resolve()),
                "wrk": str(Path(args.wrk).resolve()),
                "duration_seconds": args.duration,
                "rounds": args.rounds,
                "threads": "1 for c=1, otherwise 2",
                "random_seed": 2026,
                "file_sizes": {name: len(body) for name, (_, body) in FILES.items()},
                "http_timings": http_timings,
                "fd_before": fd_before,
                "fd_after": fd_after,
                "rss_kb_after": rss_kb(process.pid),
            }
            (output_dir / "metadata.json").write_text(
                json.dumps(metadata, indent=2) + "\n"
            )
            with (output_dir / "summary.csv").open("w", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)
            for name in endpoints:
                for count in connections:
                    sample = [
                        row for row in rows
                        if row["endpoint"] == name and row["connections"] == count
                    ]
                    print(
                        f"MEDIAN {name:6} c={count:<2} "
                        f"rps={statistics.median(row['rps'] for row in sample):.2f} "
                        f"MiB/s={statistics.median(row['transfer_mib_s'] for row in sample):.2f} "
                        f"p50={statistics.median(row['p50_ms'] for row in sample):.2f}ms "
                        f"p99={statistics.median(row['p99_ms'] for row in sample):.2f}ms",
                        flush=True,
                    )
            print(f"HTTP timings (ms): {http_timings}", flush=True)
            print(f"FD: {fd_before}->{fd_after}; RSS: {metadata['rss_kb_after']} KiB", flush=True)
            # 出现协议错误或 FD 未回落时，即使吞吐量较高也判定基准失败。
            if any(row["socket_errors"] or row["non_2xx"] for row in rows):
                raise RuntimeError("wrk reported socket errors or non-2xx responses")
            if fd_after > fd_before + 3:
                raise RuntimeError("file descriptor count did not return to baseline")
        finally:
            # 基准异常退出时也要先优雅停机，超时后才强制杀死进程。
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            server_log = process.stderr.read().decode(errors="replace")
            process.stderr.close()
            if process.returncode != 0:
                raise RuntimeError(
                    f"server exited {process.returncode}:\n{server_log}"
                )


if __name__ == "__main__":
    main()
