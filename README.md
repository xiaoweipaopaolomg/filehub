# FileHub：Linux 高并发文件分发服务

FileHub 是一个使用 C11 编写的 Linux HTTP/1.1 静态文件分发服务，面向局域网文件下载、安装包分发和只读资源共享场景。项目采用 `epoll` Reactor、固定工作线程池和 `sendfile()` 零拷贝传输，不依赖开发板，可直接运行在普通 Linux 主机上。

项目支持 HTTP Keep-Alive、请求分片、流水线请求、断点下载、慢客户端处理、运行指标、配置热加载和 systemd 部署，并包含功能、稳定性、性能与资源释放测试。



## 核心特性

- 使用 `epoll` ET + `EPOLLONESHOT` 管理非阻塞客户端连接。
- Reactor 线程独占客户端 socket 和 epoll 注册，工作线程只负责文件打开与响应准备。
- 使用有界工作队列控制过载，队列满时快速返回 `503 Service Unavailable`。
- 使用 `eventfd` 将工作线程完成结果通知给 Reactor。
- 使用 `sendfile()` 发送文件，正确处理短写、`EAGAIN` 和客户端中途断开。
- 支持 HTTP/1.1 Keep-Alive、顺序流水线、`GET`、`HEAD` 和单段 `Range`。
- 支持 `bytes=start-end`、`bytes=start-` 和 `bytes=-suffix` 三种断点下载形式。
- 使用 `openat()` + `O_NOFOLLOW` 逐级打开路径，阻止 `..`、编码穿越和符号链接逃逸。
- 使用 `timerfd` 管理请求头、空闲 Keep-Alive、文件发送和任务处理超时。
- 使用 `signalfd` 统一处理 `SIGINT`、`SIGTERM` 和 `SIGHUP`。
- 提供 `/status` JSON 状态端点和 `/metrics` Prometheus 文本指标。
- 提供 systemd 安全沙箱、原子安装、冒烟测试和部署实例压力测试。

## 系统架构

```text
                               ┌───────────────────────────────┐
TCP 客户端 ──────────────────► │ Reactor / epoll 事件循环       │
                               │ accept、解析、发送、超时、关闭  │
                               └───────────────┬───────────────┘
                                               │ 文件准备任务
                                               ▼
                                      ┌─────────────────┐
                                      │ 有界 FIFO 队列   │
                                      └────────┬────────┘
                                               ▼
                                      ┌─────────────────┐
                                      │ pthread 工作池   │
                                      │ 路径检查、openat │
                                      └────────┬────────┘
                                               │ 完成结果
                                               ▼
                                      ┌─────────────────┐
                                      │ 完成队列         │
                                      └────────┬────────┘
                                               │ eventfd
                                               └──────────────► Reactor

timerfd  ─► 周期性连接超时检查
signalfd ─► SIGINT / SIGTERM / SIGHUP
```

每个连接由“槽位编号 + 复用代次”组成唯一 token。工作线程返回结果时，Reactor 会检查代次是否仍然匹配；如果原连接已经超时或断开，旧结果会被丢弃并关闭其文件描述符，避免把响应发送给后来复用该槽位的新连接。

## 目录结构

```text
filehub/
├── main.c                     # 程序入口
├── config.c/.h                # 默认配置、配置文件与命令行解析
├── server.c/.h                # epoll Reactor、连接状态机与信号处理
├── http_request.c/.h          # 增量 HTTP/1.1 请求解析
├── http_response.c/.h         # 响应对象与响应头生成
├── file_service.c/.h          # 安全路径访问、MIME 与 Range 处理
├── worker_pool.c/.h           # 有界工作队列与完成队列
├── tests/                     # 单元、集成、稳定性和性能测试
├── deploy/                    # systemd、安装、冒烟及部署压测脚本
├── docroot/                   # 默认静态文件目录
├── filehub-regression-test.sh # 累积功能回归测试
└── Makefile
```

## 环境要求

- Linux（使用了 epoll、eventfd、timerfd、signalfd 和 sendfile）
- GCC 或兼容的 C11 编译器
- GNU Make
- POSIX Threads
- Python 3（运行集成与稳定性测试）
- curl（冒烟与回归测试）
- wrk（性能和部署压力测试，可选）
- Valgrind（内存检查，可选）

## 编译和运行

```bash
cd /home/wang/weijd/project/filehub
make clean all
./filehub --port 8080 --root ./docroot
```

在另一个终端验证：

```bash
curl -i http://127.0.0.1:8080/
curl -I http://127.0.0.1:8080/info.html
curl http://127.0.0.1:8080/status
curl http://127.0.0.1:8080/metrics
curl -H 'Range: bytes=0-99' http://127.0.0.1:8080/info.html
```

使用 `Ctrl+C` 会向前台进程发送 `SIGINT`，服务停止接受新连接，并等待正在发送的响应完成，最长等待 5 秒。

### 命令行参数

```text
--config FILE           配置文件路径
--port N                TCP 监听端口
--root DIR              静态文件根目录
--workers N             工作线程数
--max-connections N     最大并发连接数
--queue-limit N         工作队列上限
--help                  显示帮助
```

命令行参数的优先级高于配置文件。

## 配置文件

参考 [`deploy/filehub.conf.example`](deploy/filehub.conf.example)：

```ini
listen_port=8080
document_root=/srv/filehub
worker_threads=4
max_connections=256
queue_limit=256
request_timeout=10
keepalive_timeout=30
write_timeout=30
access_log=1
```

| 配置项 | 作用 |
| --- | --- |
| `listen_port` | TCP 监听端口 |
| `document_root` | 只读文件根目录 |
| `worker_threads` | 文件准备线程数量 |
| `max_connections` | 活动客户端连接上限 |
| `queue_limit` | 等待工作线程处理的任务上限 |
| `request_timeout` | 请求头接收超时，单位为秒 |
| `keepalive_timeout` | 空闲长连接超时，单位为秒 |
| `write_timeout` | 响应发送无进展超时，单位为秒 |
| `access_log` | `1` 开启逐请求日志，`0` 关闭 |

修改三个超时项或 `access_log` 后，可以发送 `SIGHUP` 热加载；端口、目录、线程数和容量限制发生变化时需要重启服务。

## HTTP 行为

| 请求 | 返回结果 |
| --- | --- |
| `GET /file` | 完整文件，`200 OK` |
| `HEAD /file` | 只返回响应头，`Content-Length` 与 GET 一致 |
| `GET /file` + `Range` | 单段文件内容，`206 Partial Content` |
| 不可满足或不支持的 Range | `416 Range Not Satisfiable` |
| 不存在的文件 | `404 Not Found` |
| 非普通文件、非法路径或符号链接 | `403 Forbidden` |
| POST、DELETE 等不支持的方法 | `405 Method Not Allowed` |
| 请求头接收超时 | `408 Request Timeout` |
| 请求头过大 | `431 Request Header Fields Too Large` |
| 工作队列或连接槽位过载 | `503 Service Unavailable` |

请求头最大为 16 KiB。服务不接受请求体、不支持分块请求体，也不支持多段 Range。

## systemd 部署

先在临时目录验证安装流程，不修改系统：

```bash
make clean all
make deploy-check
```

正式安装：

```bash
sudo bash deploy/install.sh
```

默认安装位置：

```text
/usr/local/bin/filehub
/etc/filehub/filehub.conf
/etc/systemd/system/filehub.service
/srv/filehub/index.html
/srv/filehub/info.html
```

服务使用低权限账户 `www-data` 运行，并启用了 systemd 文件系统、设备、内核接口和 capability 限制。

### 启动、停止和查看状态

```bash
# 查看当前状态
systemctl status filehub.service

# 停止本次运行，但保留开机自启设置
sudo systemctl stop filehub.service

# 启动服务
sudo systemctl start filehub.service

# 重启服务
sudo systemctl restart filehub.service

# 热加载超时和访问日志配置
sudo systemctl reload filehub.service

# 查看是否设置为开机自启
systemctl is-enabled filehub.service

# 同时停止服务并取消开机自启
sudo systemctl disable --now filehub.service

# 重新设置开机自启并立即启动
sudo systemctl enable --now filehub.service
```

`systemctl stop` 会发送 `SIGTERM`。FileHub 停止接受新连接，允许活动响应在 5 秒内完成；unit 中的 `TimeoutStopSec=7` 给服务额外留出了清理时间。

查看日志：

```bash
journalctl -u filehub.service -n 100 --no-pager
journalctl -u filehub.service -f
```

检查端口是否已经释放：

```bash
ss -ltnp | grep ':8080'
```

仅停止服务不会删除程序、配置和站点文件。

## 测试

### 完整功能回归

```bash
make test
```

当前测试包括：

- 36 项累积协议与并发回归检查。
- C 请求解析、Range 和路径安全单元测试。
- 9 项 Python 端到端集成测试。
- TCP 请求分片和 HTTP 流水线。
- Keep-Alive、HEAD、Range 和错误响应。
- 慢客户端、大文件 SHA-256 完整性和 `EAGAIN` 路径。
- 下载中途断开、配置热加载、请求超时和优雅退出。

### Sanitizer 与 Valgrind

```bash
make asan
FILEHUB_BIN=filehub-asan python3 tests/test_filehub.py

make tsan
FILEHUB_BIN=filehub-tsan python3 tests/test_filehub.py

bash valgrind_run.sh
```

### 混合负载稳定性测试

```bash
python3 tests/stability_test.py --duration 120 --clients 12
```

测试会混合执行完整下载、随机 Range、状态查询、请求分片和提前断开，并持续记录 RSS、FD、活动连接数和退出耗时。

### 性能回归

```bash
conda activate filehub-test
python3 tests/benchmark_latency.py --duration 5 --rounds 3
```

### 已部署服务压力测试

```bash
conda activate filehub-test
bash deploy/run_pressure_test.sh
```

包装脚本会临时关闭逐请求访问日志，运行结束、失败或收到中断信号时自动恢复原值。压测会验证：

- wrk socket error 为 0。
- 非 2xx/3xx 响应为 0。
- 每个并发级别结束后文件 SHA-256 不变。
- systemd 没有重启服务。
- FD 回落到基线附近。
- RSS 没有异常增长。
- 压测后核心 HTTP 冒烟测试仍然通过。

## 本机压力测试结果

以下结果来自本机回环地址、小文件 `/info.html`、4 个 wrk 线程、每级 15 秒的部署实例测试。压测期间关闭逐请求日志：

| 并发连接 | 请求吞吐量 | 平均延迟 | P99 延迟 |
| ---: | ---: | ---: | ---: |
| 10 | 38,573 req/s | 0.20 ms | 0.48 ms |
| 50 | 46,166 req/s | 1.04 ms | 2.45 ms |
| 100 | 47,415 req/s | 2.11 ms | 4.83 ms |
| 200 | 47,454 req/s | 4.22 ms | 9.53 ms |

连续两轮结果波动小于约 1.5%，稳定吞吐量约为 4.7 万 req/s，观测峰值约为 4.8 万 req/s。100～200 并发已经进入吞吐平台区间，继续提高并发主要增加延迟。

这些数字主要反映本机小文件请求解析、连接管理和响应调度能力，不代表真实网络或磁盘环境中的大文件传输带宽。测试结果保存在 [`tests/results`](tests/results) 中。

## 安全边界与当前限制

- 当前只支持明文 HTTP/1.1，不提供 TLS。
- 不提供身份认证、权限控制、上传、CGI 或目录浏览。
- 只支持单段 Range，不支持 multipart/byteranges。
- `/status` 和 `/metrics` 默认对所有可访问客户端开放。
- 推荐只在可信局域网使用；对公网提供服务时，应部署在带 TLS、认证和访问控制的反向代理之后。
- FileHub 是 Linux 应用开发与工程实践项目，不用于替代经过长期生产验证的 Nginx、Caddy 等服务器。
