#include "http_request.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

/* 在显式的 [start, end) 范围内查找 CRLF，避免依赖 NUL 结尾。 */
static const char *find_crlf_in_range(const char *start, const char *end) {
    for (const char *cursor = start; cursor + 1 < end; ++cursor) {
        if (cursor[0] == '\r' && cursor[1] == '\n') return cursor;
    }
    return NULL;
}

int filehub_http_request_parse(const char *buffer, size_t length,
                               filehub_http_request_t *request, size_t *consumed) {
    if (length > REQUEST_BUFFER_SIZE) return -2;
    const char *buffer_end = buffer + length;
    const char *header_end = NULL;
    /* 只有收到完整的 CRLF CRLF 后才开始解析，天然支持 TCP 请求分片。 */
    for (const char *cursor = buffer; cursor + 3 < buffer_end; ++cursor) {
        if (!memcmp(cursor, "\r\n\r\n", 4)) { header_end = cursor + 4; break; }
    }
    if (!header_end) return length == REQUEST_BUFFER_SIZE ? -2 : 0;
    /* 调用字符串解析函数前拒绝 NUL 和非法控制字符，防止截断与歧义。 */
    for (const char *cursor = buffer; cursor < header_end; ++cursor)
        if (*cursor == '\0' || ((unsigned char)*cursor < 32 &&
            *cursor != '\r' && *cursor != '\n' && *cursor != '\t')) return -1;
    memset(request, 0, sizeof(*request));
    request->keep_alive = 1; /* HTTP/1.1 默认使用持久连接。 */
    const char *line_end = find_crlf_in_range(buffer, header_end);
    if (!line_end || line_end - buffer >= 2200) return -1;
    char request_line[2200];
    memcpy(request_line, buffer, (size_t)(line_end - buffer));
    request_line[line_end - buffer] = '\0';
    char version[16], trailing_token[2];
    if (sscanf(request_line, "%7s %2047s %15s %1s", request->method,
               request->path, version, trailing_token) != 3) return -1;
    if (strcmp(version, "HTTP/1.1") || request->path[0] != '/') return -1;
    for (const char *cursor = request->path; *cursor; ++cursor)
        if ((unsigned char)*cursor < 32 || (unsigned char)*cursor == 127) return -1;
    request->head_only = !strcmp(request->method, "HEAD");
    const char *line = line_end + 2;
    int header_count = 0;
    /* 限制请求头数量和单行长度，避免异常输入消耗过多 CPU。 */
    while (line < header_end - 2) {
        line_end = find_crlf_in_range(line, header_end);
        if (!line_end || ++header_count > 64 || line_end - line > 4096) return -1;
        const char *colon = memchr(line, ':', (size_t)(line_end - line));
        if (!colon || colon == line) return -1;
        for (const char *cursor = line; cursor < colon; ++cursor)
            if (!isalnum((unsigned char)*cursor) && *cursor != '-') return -1;
        const char *value = colon + 1;
        while (value < line_end && (*value == ' ' || *value == '\t')) ++value;
        size_t key_len = (size_t)(colon - line);
        size_t value_len = (size_t)(line_end - value);
        if (key_len == 10 && !strncasecmp(line, "Connection", 10)) {
            if (value_len == 5 && !strncasecmp(value, "close", 5)) request->keep_alive = 0;
        } else if (key_len == 5 && !strncasecmp(line, "Range", 5)) {
            if (value_len >= sizeof(request->range)) return -1;
            memcpy(request->range, value, value_len);
            request->range[value_len] = '\0';
        } else if (key_len == 14 && !strncasecmp(line, "Content-Length", 14)) {
            /* 静态文件服务不接收请求体，只允许显式的 Content-Length: 0。 */
            if (value_len != 1 || *value != '0') return -1;
        } else if (key_len == 17 && !strncasecmp(line, "Transfer-Encoding", 17)) {
            /* 不支持分块请求体，直接拒绝以避免请求走私等解析差异。 */
            return -1;
        }
        line = line_end + 2;
    }
    *consumed = (size_t)(header_end - buffer);
    return 1;
}
