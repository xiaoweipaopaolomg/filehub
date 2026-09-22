#define _GNU_SOURCE
#include "server.h"
#include "http_request.h"
#include "http_response.h"
#include "worker_pool.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

/*
 * epoll data.u64 中 1~4 保留给服务级事件，客户端 token 从 CLIENT_BASE
 * 开始编码。批量读取 128 个事件可减少 epoll_wait() 调用次数。
 */
enum {
    FILEHUB_EVENT_LISTENER = 1,
    FILEHUB_EVENT_WORKER = 2,
    FILEHUB_EVENT_TIMER = 3,
    FILEHUB_EVENT_SIGNAL = 4,
    FILEHUB_CLIENT_TOKEN_BASE = 16,
    FILEHUB_EVENT_BATCH_SIZE = 128
};

/* 每个连接只能处于以下四种状态之一，状态转换只发生在 Reactor 线程。 */
enum filehub_connection_state {
    FILEHUB_CONNECTION_FREE,
    FILEHUB_CONNECTION_READING,
    FILEHUB_CONNECTION_PROCESSING,
    FILEHUB_CONNECTION_WRITING
};

/*
 * 固定槽位中的连接上下文。输入缓冲区支持分片请求和流水线残留数据；
 * 各种 offset 记录非阻塞发送进度，使 EAGAIN 后可以从原位置继续。
 */
typedef struct {
    int fd;                         /* 客户端 socket；空闲时为 -1。 */
    uint32_t generation;            /* 槽位复用代次，用于识别过期异步结果。 */
    enum filehub_connection_state state;
    char request_buffer[REQUEST_BUFFER_SIZE];
    size_t request_buffer_length;
    int peer_read_closed;           /* 对端已经关闭发送方向。 */
    int request_started;            /* 已收到本次请求的至少一个字节。 */
    char request_path[2048];        /* 仅用于访问日志。 */
    uint64_t response_bytes_sent;   /* 本次响应已发送字节数，包含响应头。 */
    char response_header[2048];
    size_t response_header_length;
    size_t response_header_offset;
    size_t response_body_offset;
    off_t file_offset;
    filehub_http_response_t response;
    int64_t stage_deadline_ms;      /* 当前阶段的绝对单调时钟截止时间。 */
} filehub_connection_t;

/* 服务级资源与统计信息；除 filehub_worker_pool_t 内部队列外均由 Reactor 独占。 */
typedef struct {
    filehub_config_t config;
    int epoll_fd;
    int listener_fd;
    int document_root_fd;
    int timeout_timer_fd;
    int signal_event_fd;
    int worker_pool_ready;          /* 标记线程池是否可安全销毁。 */
    int shutting_down;              /* 已进入优雅停机阶段。 */
    int64_t shutdown_deadline_ms;
    filehub_worker_pool_t worker_pool;
    filehub_connection_t *connections;
    int active_connections;
    uint64_t total_requests;
    uint64_t total_bytes_sent;
    uint64_t write_eagain_count;
} filehub_server_t;

/* 使用单调时钟，避免系统时间校准影响超时判断。 */
static int64_t monotonic_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* 把连接槽位和复用代次压入一个 64 位 epoll/线程池标识。 */
static uint64_t make_connection_token(int connection_index, uint32_t generation) {
    return ((uint64_t)generation << 32) |
           (uint32_t)(connection_index + FILEHUB_CLIENT_TOKEN_BASE);
}

/*
 * 解析 token 并验证代次。工作线程结果返回较晚时，原槽位可能已经被新连接
 * 复用；代次不一致即可安全丢弃旧结果。
 */
static filehub_connection_t *lookup_connection_by_token(filehub_server_t *server,
                                                         uint64_t token,
                                                         int *connection_index) {
    uint32_t low = (uint32_t)token;
    if (low < FILEHUB_CLIENT_TOKEN_BASE ||
        low - FILEHUB_CLIENT_TOKEN_BASE >= (uint32_t)server->config.max_connections)
        return NULL;
    *connection_index = (int)(low - FILEHUB_CLIENT_TOKEN_BASE);
    filehub_connection_t *connection = &server->connections[*connection_index];
    return connection->state != FILEHUB_CONNECTION_FREE &&
           connection->generation == (uint32_t)(token >> 32) ? connection : NULL;
}

/* 注册监听 socket、eventfd、timerfd、signalfd 等新的 epoll 事件源。 */
static int register_epoll_source(filehub_server_t *server, int fd,
                                 uint32_t flags, uint64_t token) {
    struct epoll_event event = { .events = flags, .data.u64 = token };
    return epoll_ctl(server->epoll_fd, EPOLL_CTL_ADD, fd, &event);
}

/*
 * 客户端采用 ET + ONESHOT。每次处理到 EAGAIN 或主动预算边界后必须重新
 * EPOLL_CTL_MOD，否则该连接不会再产生可处理事件。
 */
static int rearm_connection(filehub_server_t *server, filehub_connection_t *connection,
                            int connection_index, uint32_t readiness) {
    struct epoll_event event = {
        .events = readiness | EPOLLET | EPOLLONESHOT | EPOLLRDHUP,
        .data.u64 = make_connection_token(connection_index, connection->generation)
    };
    return epoll_ctl(server->epoll_fd, EPOLL_CTL_MOD, connection->fd, &event);
}

/* Reactor 是唯一关闭客户端 socket 或修改 epoll 的线程，避免并发释放竞态。 */
static void close_connection(filehub_server_t *server, filehub_connection_t *connection) {
    if (connection->state == FILEHUB_CONNECTION_FREE) return;
    epoll_ctl(server->epoll_fd, EPOLL_CTL_DEL, connection->fd, NULL);
    close(connection->fd);
    filehub_http_response_close(&connection->response);
    connection->fd = -1;
    connection->state = FILEHUB_CONNECTION_FREE;
    --server->active_connections;
}

/*
 * 接管一个已准备好的响应并切换到写状态。file_fd 的所有权从临时响应
 * 转移到连接对象，防止任务对象释放时提前关闭文件。
 */
static int start_response_write(filehub_server_t *server,
                                filehub_connection_t *connection,
                                int connection_index,
                                filehub_http_response_t *response) {
    filehub_http_response_close(&connection->response);
    connection->response = *response;
    response->file_fd = -1; /* 所有权已经转移，原对象不再负责关闭。 */
    int header_length = filehub_http_response_format_headers(
        &connection->response, connection->response_header,
        sizeof(connection->response_header));
    if (header_length < 0) { close_connection(server, connection); return -1; }
    connection->response_header_length = (size_t)header_length;
    connection->response_header_offset = 0;
    connection->response_body_offset = 0;
    connection->response_bytes_sent = 0;
    connection->file_offset = connection->response.file_start;
    connection->state = FILEHUB_CONNECTION_WRITING;
    connection->stage_deadline_ms = monotonic_time_ms() +
                                    (int64_t)server->config.write_timeout_seconds * 1000;
    if (rearm_connection(server, connection, connection_index, EPOLLOUT) < 0) {
        close_connection(server, connection);
        return -1;
    }
    return 0;
}

/* 解析或调度失败后的统一错误响应入口；错误后主动关闭连接。 */
static void start_error_response(filehub_server_t *server,
                                 filehub_connection_t *connection,
                                 int connection_index, int status) {
    filehub_http_response_t response;
    filehub_http_response_set_error(&response, status, 0, 0);
    start_response_write(server, connection, connection_index, &response);
}

/* 只接受端点本身或其后紧跟查询参数，避免把 /statusx 误判为 /status。 */
static int path_matches_endpoint(const char *path, const char *endpoint) {
    size_t endpoint_length = strlen(endpoint);
    return !strncmp(path, endpoint, endpoint_length) &&
           (path[endpoint_length] == '\0' || path[endpoint_length] == '?');
}

/*
 * 尝试从连接缓冲区取出一个完整请求。内置状态端点由 Reactor 直接生成，
 * 文件请求提交给线程池；缓冲区中未消费的数据保留给 HTTP 流水线下一请求。
 */
static int parse_or_dispatch_request(filehub_server_t *server,
                                     filehub_connection_t *connection,
                                     int connection_index) {
    filehub_http_request_t request;
    size_t consumed = 0;
    int parse_status = filehub_http_request_parse(
        connection->request_buffer, connection->request_buffer_length,
        &request, &consumed);
    if (parse_status == 0) {
        if (connection->peer_read_closed) {
            close_connection(server, connection);
            return -1;
        }
        if (rearm_connection(server, connection, connection_index, EPOLLIN) < 0) {
            close_connection(server, connection);
            return -1;
        }
        return 0;
    }
    if (parse_status < 0) {
        strcpy(connection->request_path, "-");
        start_error_response(server, connection, connection_index,
                             parse_status == -2 ? 431 : 400);
        return 0;
    }
    memmove(connection->request_buffer, connection->request_buffer + consumed,
            connection->request_buffer_length - consumed);
    connection->request_buffer_length -= consumed;
    if (connection->peer_read_closed || server->shutting_down) request.keep_alive = 0;
    strcpy(connection->request_path, request.path);
    ++server->total_requests;
    if (strcmp(request.method, "GET") && strcmp(request.method, "HEAD")) {
        start_error_response(server, connection, connection_index, 405);
        return 0;
    }

    if (path_matches_endpoint(request.path, "/status") ||
        path_matches_endpoint(request.path, "/metrics")) {
        /* 监控端点不执行文件 I/O，无需占用线程池队列。 */
        filehub_http_response_t response;
        filehub_http_response_init(&response);
        response.status = 200;
        response.reason = "OK";
        response.head_only = request.head_only;
        response.keep_alive = request.keep_alive;
        if (path_matches_endpoint(request.path, "/status")) {
            response.content_type = "application/json";
            int body_length = snprintf(response.body, sizeof(response.body),
                "{\"active_connections\":%d,\"total_requests\":%" PRIu64 ",\"bytes_sent\":%" PRIu64 ",\"write_eagain\":%" PRIu64 "}\n",
                server->active_connections, server->total_requests, server->total_bytes_sent,
                server->write_eagain_count);
            response.body_len = body_length > 0 ? (size_t)body_length : 0;
        } else {
            response.content_type = "text/plain; version=0.0.4";
            int body_length = snprintf(response.body, sizeof(response.body),
                "filehub_active_connections %d\nfilehub_requests_total %" PRIu64 "\nfilehub_bytes_sent_total %" PRIu64 "\nfilehub_write_eagain_total %" PRIu64 "\n",
                server->active_connections, server->total_requests, server->total_bytes_sent,
                server->write_eagain_count);
            response.body_len = body_length > 0 ? (size_t)body_length : 0;
        }
        start_response_write(server, connection, connection_index, &response);
        return 0;
    }
    if (filehub_worker_pool_submit(
            &server->worker_pool,
            make_connection_token(connection_index, connection->generation),
            &request) < 0) {
        /* 队列过载时快速返回 503，避免无限排队拖垮进程。 */
        start_error_response(server, connection, connection_index, 503);
        return 0;
    }
    connection->state = FILEHUB_CONNECTION_PROCESSING;
    connection->stage_deadline_ms = monotonic_time_ms() +
                                    (int64_t)server->config.write_timeout_seconds * 1000;
    return 0;
}

/*
 * ET 模式下必须循环 recv() 直到 EAGAIN。首次收到数据后设置绝对请求头
 * 截止时间，后续零散字节不会延长它，从而抵御 Slowloris 类慢请求。
 */
static void read_connection(filehub_server_t *server,
                            filehub_connection_t *connection,
                            int connection_index) {
    for (;;) {
        if (connection->request_buffer_length == sizeof(connection->request_buffer)) {
            start_error_response(server, connection, connection_index, 431);
            return;
        }
        ssize_t bytes_received = recv(
            connection->fd,
            connection->request_buffer + connection->request_buffer_length,
            sizeof(connection->request_buffer) - connection->request_buffer_length, 0);
        if (bytes_received > 0) {
            if (!connection->request_started) {
                connection->request_started = 1;
                /* 绝对截止时间：逐字节发送不能无限延长请求生命周期。 */
                connection->stage_deadline_ms = monotonic_time_ms() +
                    (int64_t)server->config.request_timeout_seconds * 1000;
            }
            connection->request_buffer_length += (size_t)bytes_received;
            continue;
        }
        if (bytes_received == 0) { connection->peer_read_closed = 1; break; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        close_connection(server, connection);
        return;
    }
    parse_or_dispatch_request(server, connection, connection_index);
}

/* 完成访问日志与资源回收，并根据 keep-alive 决定关闭或读取下一请求。 */
static void finish_connection_response(filehub_server_t *server,
                                       filehub_connection_t *connection,
                                       int connection_index) {
    if (server->config.access_log_enabled)
        fprintf(stderr, "path=%s status=%d bytes=%" PRIu64 "\n",
                connection->request_path, connection->response.status,
                connection->response_bytes_sent);
    int keep_alive = connection->response.keep_alive && !server->shutting_down &&
                     !connection->peer_read_closed;
    filehub_http_response_close(&connection->response);
    if (!keep_alive) { close_connection(server, connection); return; }
    filehub_http_response_init(&connection->response);
    connection->state = FILEHUB_CONNECTION_READING;
    /* 流水线数据已在缓冲区时立即解析，否则重新监听 EPOLLIN。 */
    connection->request_started = connection->request_buffer_length > 0;
    connection->stage_deadline_ms = monotonic_time_ms() +
        (int64_t)(connection->request_started ?
                  server->config.request_timeout_seconds :
                  server->config.keepalive_timeout_seconds) * 1000;
    if (connection->request_buffer_length)
        parse_or_dispatch_request(server, connection, connection_index);
    else if (rearm_connection(server, connection, connection_index, EPOLLIN) < 0)
        close_connection(server, connection);
}

/*
 * 每次事件最多发送 1 MiB，防止单个大文件连接长期独占 Reactor。
 * EPOLLONESHOT 允许预算耗尽后主动重装 EPOLLOUT，无需等待新的边沿；
 * 慢接收方只保留连接状态，不会占用工作线程。
 */
static void write_connection(filehub_server_t *server,
                             filehub_connection_t *connection,
                             int connection_index) {
    size_t send_budget = 1024 * 1024;
    while (send_budget) {
        if (connection->response_header_offset < connection->response_header_length) {
            /* 响应头必须先完整发送，再进入文件或内存正文阶段。 */
            size_t bytes_remaining = connection->response_header_length -
                                     connection->response_header_offset;
            if (bytes_remaining > send_budget) bytes_remaining = send_budget;
            ssize_t bytes_sent = send(
                connection->fd,
                connection->response_header + connection->response_header_offset,
                bytes_remaining, MSG_NOSIGNAL);
            if (bytes_sent > 0) {
                connection->response_header_offset += (size_t)bytes_sent;
                send_budget -= (size_t)bytes_sent;
                server->total_bytes_sent += (uint64_t)bytes_sent;
                connection->response_bytes_sent += (uint64_t)bytes_sent;
                connection->stage_deadline_ms = monotonic_time_ms() +
                    (int64_t)server->config.write_timeout_seconds * 1000;
                continue;
            }
            if (bytes_sent < 0 && errno == EINTR) continue;
            if (bytes_sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                ++server->write_eagain_count;
                break;
            }
            close_connection(server, connection);
            return;
        }
        if (connection->response.head_only) {
            finish_connection_response(server, connection, connection_index);
            return;
        }
        if (connection->response.file_fd >= 0) {
            /* sendfile() 在内核态完成文件到 socket 的传输，避免用户态拷贝。 */
            off_t file_bytes_remaining = connection->response.file_end -
                                         connection->file_offset;
            if (file_bytes_remaining == 0) {
                finish_connection_response(server, connection, connection_index);
                return;
            }
            size_t send_count = file_bytes_remaining > (off_t)send_budget ?
                                send_budget : (size_t)file_bytes_remaining;
            ssize_t bytes_sent = sendfile(connection->fd, connection->response.file_fd,
                                          &connection->file_offset, send_count);
            if (bytes_sent > 0) {
                send_budget -= (size_t)bytes_sent;
                server->total_bytes_sent += (uint64_t)bytes_sent;
                connection->response_bytes_sent += (uint64_t)bytes_sent;
                connection->stage_deadline_ms = monotonic_time_ms() +
                    (int64_t)server->config.write_timeout_seconds * 1000;
                continue;
            }
            if (bytes_sent < 0 && errno == EINTR) continue;
            if (bytes_sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                ++server->write_eagain_count;
                break;
            }
            close_connection(server, connection);
            return;
        }
        if (connection->response_body_offset == connection->response.body_len) {
            finish_connection_response(server, connection, connection_index);
            return;
        }
        size_t body_bytes_remaining = connection->response.body_len -
                                      connection->response_body_offset;
        if (body_bytes_remaining > send_budget) body_bytes_remaining = send_budget;
        ssize_t bytes_sent = send(
            connection->fd,
            connection->response.body + connection->response_body_offset,
            body_bytes_remaining, MSG_NOSIGNAL);
        if (bytes_sent > 0) {
            connection->response_body_offset += (size_t)bytes_sent;
            send_budget -= (size_t)bytes_sent;
            server->total_bytes_sent += (uint64_t)bytes_sent;
            connection->response_bytes_sent += (uint64_t)bytes_sent;
            connection->stage_deadline_ms = monotonic_time_ms() +
                (int64_t)server->config.write_timeout_seconds * 1000;
            continue;
        }
        if (bytes_sent < 0 && errno == EINTR) continue;
        if (bytes_sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            ++server->write_eagain_count;
            break;
        }
        close_connection(server, connection);
        return;
    }
    if (rearm_connection(server, connection, connection_index, EPOLLOUT) < 0)
        close_connection(server, connection);
}

/* 清空 eventfd 计数并接收工作线程完成的响应。 */
static void drain_worker_results(filehub_server_t *server) {
    uint64_t completed_count;
    while (read(server->worker_pool.completion_event_fd, &completed_count,
                sizeof(completed_count)) > 0) { }
    filehub_work_item_t *work_item;
    while ((work_item = filehub_worker_pool_take_result(&server->worker_pool))) {
        int connection_index = -1;
        filehub_connection_t *connection = lookup_connection_by_token(
            server, work_item->token, &connection_index);
        if (connection && connection->state == FILEHUB_CONNECTION_PROCESSING)
            start_response_write(server, connection, connection_index,
                                 &work_item->response);
        /* 连接已关闭或代次不匹配时，仍需释放任务持有的文件描述符。 */
        filehub_http_response_close(&work_item->response);
        free(work_item);
    }
}

/* 连接数达到上限时发送最小 503 响应并立即关闭，不占用连接槽位。 */
static void reject_overloaded_connection(int client_fd) {
    static const char message[] = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    ssize_t unused = send(client_fd, message, sizeof(message) - 1, MSG_NOSIGNAL);
    (void)unused;
    close(client_fd);
}

/*
 * ET 模式下持续 accept4() 到 EAGAIN；新 socket 从创建起即设置为
 * NONBLOCK/CLOEXEC，并在找到空闲槽位后注册到 epoll。
 */
static void accept_pending_connections(filehub_server_t *server) {
    for (;;) {
        int client_fd = accept4(server->listener_fd, NULL, NULL,
                                SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) perror("accept4");
            return;
        }
        /*
         * 响应由小响应头和随后正文组成。关闭 Nagle，避免响应头等待延迟 ACK
         * 后才与正文共同发出，改善本机及低延迟网络中的短请求延迟。
         */
        int no_delay = 1;
        if (setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY,
                       &no_delay, sizeof(no_delay)) < 0) {
            perror("TCP_NODELAY");
            close(client_fd);
            continue;
        }
        int connection_index = -1;
        if (server->active_connections < server->config.max_connections) {
            for (int candidate = 0; candidate < server->config.max_connections;
                 ++candidate) {
                if (server->connections[candidate].state == FILEHUB_CONNECTION_FREE) {
                    connection_index = candidate;
                    break;
                }
            }
        }
        if (connection_index < 0) {
            reject_overloaded_connection(client_fd);
            continue;
        }
        filehub_connection_t *connection = &server->connections[connection_index];
        /* 代次 0 作为初始值保留，溢出后跳回 1。 */
        connection->generation += 1;
        if (connection->generation == 0) connection->generation = 1;
        connection->fd = client_fd;
        connection->state = FILEHUB_CONNECTION_READING;
        connection->request_buffer_length = 0;
        connection->peer_read_closed = 0;
        connection->request_started = 0;
        filehub_http_response_init(&connection->response);
        connection->stage_deadline_ms = monotonic_time_ms() +
            (int64_t)server->config.request_timeout_seconds * 1000;
        if (register_epoll_source(
                server, client_fd,
                EPOLLIN | EPOLLET | EPOLLONESHOT | EPOLLRDHUP,
                make_connection_token(connection_index,
                                      connection->generation)) < 0) {
            close(client_fd);
            connection->fd = -1;
            connection->state = FILEHUB_CONNECTION_FREE;
            continue;
        }
        ++server->active_connections;
    }
}

/*
 * timerfd 每秒触发一次，集中扫描各连接当前阶段的截止时间。读取中的半包
 * 返回 408；空闲 keep-alive、处理超时或写超时直接关闭。
 */
static void expire_timed_out_connections(filehub_server_t *server) {
    uint64_t expirations;
    while (read(server->timeout_timer_fd, &expirations, sizeof(expirations)) > 0) { }
    int64_t current_time_ms = monotonic_time_ms();
    for (int connection_index = 0;
         connection_index < server->config.max_connections;
         ++connection_index) {
        filehub_connection_t *connection = &server->connections[connection_index];
        if (connection->state == FILEHUB_CONNECTION_FREE ||
            connection->stage_deadline_ms > current_time_ms) continue;
        if (connection->state == FILEHUB_CONNECTION_READING &&
            connection->request_buffer_length > 0)
            start_error_response(server, connection, connection_index, 408);
        else
            close_connection(server, connection);
    }
    if (server->shutting_down && current_time_ms >= server->shutdown_deadline_ms)
        /* 优雅停机最多等待 5 秒，超时后强制关闭剩余客户端。 */
        for (int connection_index = 0;
             connection_index < server->config.max_connections;
             ++connection_index)
            close_connection(server, &server->connections[connection_index]);
}

/*
 * 信号通过 signalfd 纳入事件循环，避免异步信号处理函数中的不安全操作。
 * SIGHUP 仅热加载可在线调整的超时和日志项；端口、线程数等保持不变。
 */
static void handle_server_signals(filehub_server_t *server) {
    struct signalfd_siginfo signal_info;
    while (read(server->signal_event_fd, &signal_info,
                sizeof(signal_info)) == sizeof(signal_info)) {
        if (signal_info.ssi_signo == SIGHUP && !server->shutting_down &&
            server->config.config_file_path[0]) {
            filehub_config_t reloaded_config = server->config;
            if (filehub_config_load_file(&reloaded_config,
                                         server->config.config_file_path) == 0) {
                server->config.request_timeout_seconds =
                    reloaded_config.request_timeout_seconds;
                server->config.keepalive_timeout_seconds =
                    reloaded_config.keepalive_timeout_seconds;
                server->config.write_timeout_seconds =
                    reloaded_config.write_timeout_seconds;
                server->config.access_log_enabled =
                    reloaded_config.access_log_enabled;
                fprintf(stderr, "FileHub: reloaded timeout settings\n");
            }
        } else if ((signal_info.ssi_signo == SIGINT ||
                    signal_info.ssi_signo == SIGTERM) && !server->shutting_down) {
            /* 停止接收新连接，关闭空闲读连接，让正在生成/发送的响应继续收尾。 */
            server->shutting_down = 1;
            server->shutdown_deadline_ms = monotonic_time_ms() + 5000;
            if (server->listener_fd >= 0) {
                epoll_ctl(server->epoll_fd, EPOLL_CTL_DEL,
                          server->listener_fd, NULL);
                close(server->listener_fd);
                server->listener_fd = -1;
            }
            for (int connection_index = 0;
                 connection_index < server->config.max_connections;
                 ++connection_index) {
                if (server->connections[connection_index].state ==
                    FILEHUB_CONNECTION_READING)
                    close_connection(server,
                                     &server->connections[connection_index]);
            }
        }
    }
}

/* 创建非阻塞 IPv4 监听 socket；SO_REUSEADDR 便于服务快速重启。 */
static int create_listen_socket(int listen_port) {
    int listener_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (listener_fd < 0) return -1;
    int reuse_address = 1;
    if (setsockopt(listener_fd, SOL_SOCKET, SO_REUSEADDR,
                   &reuse_address, sizeof(reuse_address)) < 0) {
        close(listener_fd);
        return -1;
    }
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons((uint16_t)listen_port);
    if (bind(listener_fd, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        listen(listener_fd, 256) < 0) {
        close(listener_fd);
        return -1;
    }
    return listener_fd;
}

int filehub_server_run(const filehub_config_t *config) {
    filehub_server_t *server = calloc(1, sizeof(*server));
    if (!server) return -1;
    server->config = *config;
    server->epoll_fd = -1;
    server->listener_fd = -1;
    server->document_root_fd = -1;
    server->timeout_timer_fd = -1;
    server->signal_event_fd = -1;
    int result = -1;
    sigset_t handled_signals;
    sigemptyset(&handled_signals);
    sigaddset(&handled_signals, SIGINT);
    sigaddset(&handled_signals, SIGTERM);
    sigaddset(&handled_signals, SIGHUP);
    /* 发送到已关闭连接时依靠返回 EPIPE，而不是让 SIGPIPE 终止进程。 */
    signal(SIGPIPE, SIG_IGN);
    /* 先在线程创建前阻塞信号，随后统一由 signalfd 同步消费。 */
    if (sigprocmask(SIG_BLOCK, &handled_signals, NULL) < 0) goto cleanup;
    server->document_root_fd = open(config->document_root,
                                    O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (server->document_root_fd < 0) { perror("document root"); goto cleanup; }
    server->connections = calloc((size_t)config->max_connections,
                                 sizeof(*server->connections));
    if (!server->connections) goto cleanup;
    for (int connection_index = 0;
         connection_index < config->max_connections;
         ++connection_index)
        server->connections[connection_index].fd = -1;
    server->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    server->listener_fd = create_listen_socket(config->listen_port);
    server->timeout_timer_fd = timerfd_create(
        CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    server->signal_event_fd = signalfd(
        -1, &handled_signals, SFD_NONBLOCK | SFD_CLOEXEC);
    if (server->epoll_fd < 0 || server->listener_fd < 0 ||
        server->timeout_timer_fd < 0 || server->signal_event_fd < 0) {
        perror("server setup"); goto cleanup;
    }
    struct itimerspec timeout_tick = {
        .it_interval = {1, 0},
        .it_value = {1, 0}
    };
    if (timerfd_settime(server->timeout_timer_fd, 0, &timeout_tick, NULL) < 0)
        goto cleanup;
    if (filehub_worker_pool_init(&server->worker_pool, config->worker_threads,
                                 config->worker_queue_limit,
                                 server->document_root_fd) < 0)
        goto cleanup;
    server->worker_pool_ready = 1;
    if (register_epoll_source(server, server->listener_fd, EPOLLIN,
                              FILEHUB_EVENT_LISTENER) < 0 ||
        register_epoll_source(server, server->worker_pool.completion_event_fd, EPOLLIN,
                              FILEHUB_EVENT_WORKER) < 0 ||
        register_epoll_source(server, server->timeout_timer_fd, EPOLLIN,
                              FILEHUB_EVENT_TIMER) < 0 ||
        register_epoll_source(server, server->signal_event_fd, EPOLLIN,
                              FILEHUB_EVENT_SIGNAL) < 0)
        goto cleanup;
    fprintf(stderr, "FileHub listening on port %d, root %s\n",
            config->listen_port, config->document_root);
    /* 停机后继续循环，直到活动连接自然完成或 5 秒截止时间到达。 */
    while (!server->shutting_down || server->active_connections > 0) {
        struct epoll_event ready_events[FILEHUB_EVENT_BATCH_SIZE];
        int ready_count = epoll_wait(server->epoll_fd, ready_events,
                                     FILEHUB_EVENT_BATCH_SIZE, -1);
        if (ready_count < 0) {
            if (errno == EINTR) continue;
            perror("epoll_wait");
            goto cleanup;
        }
        for (int event_index = 0; event_index < ready_count; ++event_index) {
            uint64_t token = ready_events[event_index].data.u64;
            if (token == FILEHUB_EVENT_LISTENER) {
                if (!server->shutting_down) accept_pending_connections(server);
            }
            else if (token == FILEHUB_EVENT_WORKER) drain_worker_results(server);
            else if (token == FILEHUB_EVENT_TIMER) expire_timed_out_connections(server);
            else if (token == FILEHUB_EVENT_SIGNAL) handle_server_signals(server);
            else {
                int connection_index = -1;
                filehub_connection_t *connection = lookup_connection_by_token(
                    server, token, &connection_index);
                if (!connection) continue;
                uint32_t event_flags = ready_events[event_index].events;
                if (event_flags & (EPOLLERR | EPOLLHUP)) {
                    close_connection(server, connection);
                    continue;
                }
                if (connection->state == FILEHUB_CONNECTION_READING &&
                    (event_flags & (EPOLLIN | EPOLLRDHUP)))
                    read_connection(server, connection, connection_index);
                else if (connection->state == FILEHUB_CONNECTION_WRITING &&
                         (event_flags & EPOLLOUT))
                    write_connection(server, connection, connection_index);
                else if (connection->state == FILEHUB_CONNECTION_WRITING &&
                         (event_flags & EPOLLRDHUP))
                    close_connection(server, connection);
            }
        }
    }
    result = 0;
cleanup:
    /*
     * 所有初始化失败和正常退出都汇聚到同一清理路径。先关闭客户端并停止
     * 线程池，再释放服务级描述符，保证没有工作线程继续引用这些资源。
     */
    if (server->connections)
        for (int connection_index = 0;
             connection_index < server->config.max_connections;
             ++connection_index)
            if (server->connections[connection_index].state !=
                FILEHUB_CONNECTION_FREE) {
                if (server->epoll_fd >= 0)
                    close_connection(server,
                                     &server->connections[connection_index]);
                else
                    close(server->connections[connection_index].fd);
            }
    if (server->worker_pool_ready)
        filehub_worker_pool_destroy(&server->worker_pool);
    if (server->listener_fd >= 0) close(server->listener_fd);
    if (server->timeout_timer_fd >= 0) close(server->timeout_timer_fd);
    if (server->signal_event_fd >= 0) close(server->signal_event_fd);
    if (server->epoll_fd >= 0) close(server->epoll_fd);
    if (server->document_root_fd >= 0) close(server->document_root_fd);
    free(server->connections);
    free(server);
    return result;
}
