#define _GNU_SOURCE
#include "file_service.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

/* 把一个十六进制字符转换为数值；非法字符返回 -1。 */
static int hex_digit_value(char character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}

/*
 * 对 URI 路径执行百分号解码并丢弃查询参数。这里只做语法和字符级校验，
 * 目录层级及符号链接约束由 open_beneath() 负责。
 */
static int decode_uri_path(const char *uri, char *output, size_t capacity) {
    const char *uri_end = strchr(uri, '?');
    if (!uri_end) uri_end = uri + strlen(uri);
    size_t output_length = 0;
    for (const char *cursor = uri; cursor < uri_end; ++cursor) {
        unsigned char decoded = (unsigned char)*cursor;
        if (*cursor == '%') {
            if (uri_end - cursor < 3) return -1;
            int high = hex_digit_value(cursor[1]);
            int low = hex_digit_value(cursor[2]);
            if (high < 0 || low < 0) return -1;
            decoded = (unsigned char)((high << 4) | low);
            cursor += 2;
        }
        /* 禁止 NUL、控制字符和反斜杠，避免不同路径语义产生绕过。 */
        if (decoded == 0 || decoded < 32 || decoded == 127 || decoded == '\\' ||
            output_length + 1 >= capacity) return -1;
        output[output_length++] = (char)decoded;
    }
    output[output_length] = '\0';
    return output[0] == '/' ? 0 : -1;
}

/* 拒绝“.”、“..”、空路径分量以及任意层级的符号链接。 */
static int open_file_beneath_root(int root_fd, const char *path) {
    if (!strcmp(path, "/")) path = "/index.html";
    /*
     * 先验证完整路径，再打开任何分量。否则 foo/../file 可能因为 foo 不存在
     * 而提前返回 404，掩盖其中的目录穿越尝试。
     */
    const char *check = path + 1;
    while (*check) {
        const char *slash = strchr(check, '/');
        size_t length = slash ? (size_t)(slash - check) : strlen(check);
        if (!length || length > 255 || (length == 1 && check[0] == '.') ||
            (length == 2 && check[0] == '.' && check[1] == '.')) {
            errno = EACCES;
            return -1;
        }
        if (!slash) break;
        check = slash + 1;
    }
    int directory_fd = dup(root_fd);
    if (directory_fd < 0) return -1;
    /*
     * 逐级使用 openat()，并在进入下一层后关闭上一层描述符。这样路径解析
     * 始终锚定在已打开目录，而不是依赖可能变化的进程工作目录。
     */
    const char *component = path + 1;
    while (*component) {
        const char *slash = strchr(component, '/');
        size_t length = slash ? (size_t)(slash - component) : strlen(component);
        if (!length || length > 255 || (length == 1 && component[0] == '.') ||
            (length == 2 && component[0] == '.' && component[1] == '.')) {
            close(directory_fd); errno = EACCES; return -1;
        }
        char name[256];
        memcpy(name, component, length);
        name[length] = '\0';
        int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW;
        /* 中间分量必须是目录，最后一个分量在后续通过 fstat() 确认为普通文件。 */
        if (slash) flags |= O_DIRECTORY;
        int opened_fd = openat(directory_fd, name, flags);
        close(directory_fd);
        if (opened_fd < 0) return -1;
        directory_fd = opened_fd;
        if (!slash) break;
        component = slash + 1;
    }
    return directory_fd;
}

/* 根据最终扩展名返回少量常用 MIME 类型，未知类型按二进制流处理。 */
static const char *detect_mime_type(const char *path) {
    const char *extension = strrchr(path, '.');
    if (!extension) return "application/octet-stream";
    if (!strcasecmp(extension, ".html")) return "text/html; charset=utf-8";
    if (!strcasecmp(extension, ".css")) return "text/css";
    if (!strcasecmp(extension, ".js")) return "application/javascript";
    if (!strcasecmp(extension, ".txt")) return "text/plain; charset=utf-8";
    if (!strcasecmp(extension, ".json")) return "application/json";
    if (!strcasecmp(extension, ".jpg") || !strcasecmp(extension, ".jpeg")) return "image/jpeg";
    if (!strcasecmp(extension, ".png")) return "image/png";
    if (!strcasecmp(extension, ".pdf")) return "application/pdf";
    return "application/octet-stream";
}

/* 在指定字符区间内解析非负十进制偏移，并显式检查 64 位溢出。 */
static int parse_nonnegative_offset(const char *begin, const char *end, off_t *number) {
    if (begin == end) return -1;
    uint64_t value = 0;
    for (const char *p = begin; p < end; ++p) {
        if (!isdigit((unsigned char)*p) || value > (INT64_MAX - (uint64_t)(*p - '0')) / 10) return -1;
        value = value * 10 + (uint64_t)(*p - '0');
    }
    *number = (off_t)value;
    return 0;
}

/*
 * 解析单段 RFC 7233 字节范围，输出半开区间 [start, end)。
 * 支持 start-end、start- 和 -suffix 三种形式，不支持多段范围。
 */
static int parse_single_byte_range(const char *range, off_t size, off_t *start, off_t *end) {
    if (strncmp(range, "bytes=", 6) || size == 0 || strchr(range, ',')) return -1;
    const char *first = range + 6;
    const char *dash = strchr(first, '-');
    if (!dash) return -1;
    const char *last = dash + 1;
    const char *limit = last + strlen(last);
    if (first == dash) {
        /* 后缀范围：bytes=-N，N 大于文件长度时返回整个文件。 */
        off_t suffix;
        if (parse_nonnegative_offset(last, limit, &suffix) || suffix == 0) return -1;
        *start = suffix >= size ? 0 : size - suffix;
        *end = size;
    } else {
        if (parse_nonnegative_offset(first, dash, start) || *start >= size) return -1;
        if (last == limit) *end = size;
        else {
            off_t inclusive;
            if (parse_nonnegative_offset(last, limit, &inclusive) || inclusive < *start) return -1;
            *end = inclusive >= size ? size : inclusive + 1;
        }
    }
    return 0;
}

void filehub_file_prepare_response(int root_fd,
                                   const filehub_http_request_t *request,
                                   filehub_http_response_t *response) {
    filehub_http_response_init(response);
    response->keep_alive = request->keep_alive;
    response->head_only = request->head_only;
    if (strcmp(request->method, "GET") && strcmp(request->method, "HEAD")) {
        filehub_http_response_set_error(response, 405, request->keep_alive, request->head_only);
        return;
    }
    char path[sizeof(request->path)];
    if (decode_uri_path(request->path, path, sizeof(path))) {
        filehub_http_response_set_error(response, 400, request->keep_alive, request->head_only);
        return;
    }
    int file_fd = open_file_beneath_root(root_fd, path);
    if (file_fd < 0) {
        /* 对外收敛 errno，避免泄露内部路径细节。 */
        int status;
        if (errno == ENOENT) status = 404;
        else if (errno == EACCES || errno == ELOOP || errno == ENOTDIR) status = 403;
        else status = 500;
        filehub_http_response_set_error(response, status, request->keep_alive, request->head_only);
        return;
    }
    struct stat file_stat;
    /* 只提供普通文件，目录、设备节点等对象一律拒绝。 */
    if (fstat(file_fd, &file_stat) < 0 || !S_ISREG(file_stat.st_mode) ||
        file_stat.st_size < 0) {
        close(file_fd);
        filehub_http_response_set_error(response, 403, request->keep_alive, request->head_only);
        return;
    }
    response->file_fd = file_fd;
    response->file_start = 0;
    response->file_end = file_stat.st_size;
    response->full_size = file_stat.st_size;
    response->content_type = detect_mime_type(path);
    response->status = 200;
    response->reason = "OK";
    if (request->range[0]) {
        if (parse_single_byte_range(request->range, file_stat.st_size,
                                    &response->file_start, &response->file_end)) {
            close(file_fd);
            filehub_http_response_set_error(response, 416, request->keep_alive,
                                            request->head_only);
            /* 416 的 Content-Range 仍需要携带完整文件长度。 */
            response->full_size = file_stat.st_size;
            return;
        }
        response->status = 206;
        response->reason = "Partial Content";
        response->partial = 1;
    }
}
