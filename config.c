#define _POSIX_C_SOURCE 200809L
#include "config.h"

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 默认值同时服务于直接运行和配置文件缺省项。 */
void filehub_config_set_defaults(filehub_config_t *config) {
    memset(config, 0, sizeof(*config));
    config->listen_port = 8080;
    snprintf(config->document_root, sizeof(config->document_root), "./docroot");
    config->worker_threads = 4;
    config->max_connections = 256;
    config->worker_queue_limit = 256;
    config->request_timeout_seconds = 10;
    config->keepalive_timeout_seconds = 30;
    config->write_timeout_seconds = 30;
    config->access_log_enabled = 0;
}

/*
 * 严格解析十进制整数：拒绝空串、尾随字符、溢出和越界值。
 * 成功后才写入 out，避免失败时留下半更新配置。
 */
static int parse_bounded_integer(const char *text, int minimum, int maximum, int *result) {
    char *end = NULL;
    errno = 0;
    long parsed_value = strtol(text, &end, 10);
    if (errno || end == text || *end != '\0' ||
        parsed_value < minimum || parsed_value > maximum) return -1;
    *result = (int)parsed_value;
    return 0;
}

/* 把配置键映射到结构体字段；这里也是所有配置项的统一范围校验入口。 */
static int apply_config_option(filehub_config_t *config, const char *key, const char *value) {
    if (!strcmp(key, "listen_port")) return parse_bounded_integer(value, 1, 65535, &config->listen_port);
    if (!strcmp(key, "worker_threads")) return parse_bounded_integer(value, 1, 64, &config->worker_threads);
    if (!strcmp(key, "max_connections")) return parse_bounded_integer(value, 1, 65535, &config->max_connections);
    if (!strcmp(key, "queue_limit")) return parse_bounded_integer(value, 1, 65535, &config->worker_queue_limit);
    if (!strcmp(key, "request_timeout")) return parse_bounded_integer(value, 1, 3600, &config->request_timeout_seconds);
    if (!strcmp(key, "keepalive_timeout")) return parse_bounded_integer(value, 1, 3600, &config->keepalive_timeout_seconds);
    if (!strcmp(key, "write_timeout")) return parse_bounded_integer(value, 1, 3600, &config->write_timeout_seconds);
    if (!strcmp(key, "access_log")) return parse_bounded_integer(value, 0, 1, &config->access_log_enabled);
    if (!strcmp(key, "document_root")) {
        if (strlen(value) >= sizeof(config->document_root)) return -1;
        strcpy(config->document_root, value);
        return 0;
    }
    fprintf(stderr, "unknown configuration key: %s\n", key);
    return -1;
}

/* 原地去除一行首尾的空白字符，返回第一个有效字符。 */
static char *trim_whitespace(char *text) {
    while (*text == ' ' || *text == '\t') ++text;
    size_t length = strlen(text);
    while (length && (text[length - 1] == ' ' || text[length - 1] == '\t' ||
                      text[length - 1] == '\n' || text[length - 1] == '\r')) {
        text[--length] = '\0';
    }
    return text;
}

/*
 * 配置文件按行解析为 key=value。函数遇到首个错误立即停止，并输出
 * 文件名和行号，避免服务带着部分错误配置继续启动。
 */
int filehub_config_load_file(filehub_config_t *config, const char *path) {
    FILE *config_file = fopen(path, "r");
    if (!config_file) { perror(path); return -1; }
    char line[PATH_MAX + 128];
    int line_number = 0;
    while (fgets(line, sizeof(line), config_file)) {
        ++line_number;
        char *key = trim_whitespace(line);
        if (!*key || *key == '#') continue;
        char *equals = strchr(key, '=');
        if (!equals) { fprintf(stderr, "%s:%d: expected key=value\n", path, line_number); fclose(config_file); return -1; }
        *equals = '\0';
        if (apply_config_option(config, trim_whitespace(key), trim_whitespace(equals + 1)) < 0) {
            fprintf(stderr, "%s:%d: invalid option\n", path, line_number);
            fclose(config_file);
            return -1;
        }
    }
    int read_failed = ferror(config_file);
    fclose(config_file);
    return read_failed ? -1 : 0;
}

void filehub_config_print_usage(const char *program_name) {
    fprintf(stderr, "Usage: %s [--config FILE] [--port N] [--root DIR] [--workers N] [--max-connections N] [--queue-limit N]\n", program_name);
    fprintf(stderr, "       %s PORT DOCROOT  (legacy syntax)\n", program_name);
}

int filehub_config_parse_cli(filehub_config_t *config, int argc, char **argv) {
    static const struct option options[] = {
        {"config", required_argument, NULL, 'c'}, {"port", required_argument, NULL, 'p'},
        {"root", required_argument, NULL, 'r'}, {"workers", required_argument, NULL, 'w'},
        {"max-connections", required_argument, NULL, 'm'}, {"queue-limit", required_argument, NULL, 'q'},
        {"help", no_argument, NULL, 'h'}, {NULL, 0, NULL, 0}
    };
    /* 先应用配置文件，再解析全部命令行参数，使命令行拥有最高优先级。 */
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--config") || !strcmp(argv[i], "-c")) {
            if (++i >= argc || strlen(argv[i]) >= sizeof(config->config_file_path)) return -1;
            strcpy(config->config_file_path, argv[i]);
            if (filehub_config_load_file(config, argv[i]) < 0) return -1;
        } else if (!strncmp(argv[i], "--config=", 9)) {
            const char *path = argv[i] + 9;
            if (!*path || strlen(path) >= sizeof(config->config_file_path)) return -1;
            strcpy(config->config_file_path, path);
            if (filehub_config_load_file(config, path) < 0) return -1;
        }
    }
    optind = 1;
    int option;
    while ((option = getopt_long(argc, argv, "c:p:r:w:m:q:h", options, NULL)) != -1) {
        switch (option) {
            case 'c': break;
            case 'p': if (parse_bounded_integer(optarg, 1, 65535, &config->listen_port)) return -1; break;
            case 'r': if (strlen(optarg) >= sizeof(config->document_root)) return -1; strcpy(config->document_root, optarg); break;
            case 'w': if (parse_bounded_integer(optarg, 1, 64, &config->worker_threads)) return -1; break;
            case 'm': if (parse_bounded_integer(optarg, 1, 65535, &config->max_connections)) return -1; break;
            case 'q': if (parse_bounded_integer(optarg, 1, 65535, &config->worker_queue_limit)) return -1; break;
            case 'h': filehub_config_print_usage(argv[0]); return 1;
            default: return -1;
        }
    }
    if (optind < argc) {
        /* 兼容原项目的“PORT DOCROOT”位置参数写法。 */
        if (argc - optind != 2 || parse_bounded_integer(argv[optind], 1, 65535, &config->listen_port)) return -1;
        if (strlen(argv[optind + 1]) >= sizeof(config->document_root)) return -1;
        strcpy(config->document_root, argv[optind + 1]);
    }
    return 0;
}
