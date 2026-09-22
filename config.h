#ifndef FILEHUB_CONFIG_H
#define FILEHUB_CONFIG_H

#include <limits.h>

/* 服务启动后使用的完整配置。路径采用定长缓冲区，避免动态内存所有权问题。 */
typedef struct {
    int listen_port;                /* TCP 监听端口。 */
    char document_root[PATH_MAX];   /* 静态文件根目录。 */
    char config_file_path[PATH_MAX];/* 用于 SIGHUP 热加载的配置文件路径。 */
    int worker_threads;             /* 文件准备线程数。 */
    int max_connections;            /* 同时存在的客户端连接上限。 */
    int worker_queue_limit;         /* 线程池待处理队列上限。 */
    int request_timeout_seconds;    /* 请求头接收超时，单位为秒。 */
    int keepalive_timeout_seconds;  /* 空闲长连接超时，单位为秒。 */
    int write_timeout_seconds;      /* 响应发送无进展超时，单位为秒。 */
    int access_log_enabled;         /* 0 关闭、1 开启逐请求访问日志。 */
} filehub_config_t;

/* 写入一组可直接运行的默认值。 */
void filehub_config_set_defaults(filehub_config_t *config);
/* 读取 key=value 配置；遇到未知或非法配置时返回 -1。 */
int filehub_config_load_file(filehub_config_t *config, const char *path);
/* 返回 0 表示成功，1 表示已打印帮助，-1 表示参数错误。 */
int filehub_config_parse_cli(filehub_config_t *config, int argc, char **argv);
void filehub_config_print_usage(const char *program_name);

#endif
