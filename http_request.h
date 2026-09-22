#ifndef FILEHUB_HTTP_REQUEST_H
#define FILEHUB_HTTP_REQUEST_H

#include <stddef.h>

/* 请求头的硬上限，同时也是单连接输入缓冲区大小。 */
#define REQUEST_BUFFER_SIZE 16384

/* 仅保存 FileHub 实际使用的 HTTP/1.1 请求信息，不保留无关请求头。 */
typedef struct {
    char method[8];       /* 请求方法，例如 GET、HEAD。 */
    char path[2048];      /* 原始 URI 路径，后续由文件模块解码和校验。 */
    char range[128];      /* Range 请求头的值；空串表示未提供。 */
    int keep_alive;       /* 响应完成后是否保留 TCP 连接。 */
    int head_only;        /* HEAD 请求只发送响应头。 */
} filehub_http_request_t;

/*
 * 从 buffer 起始位置解析一个请求头，并通过 consumed 返回消费字节数。
 * 返回值：0=数据尚不完整，1=解析成功，-1=格式非法，-2=请求头过大。
 */
int filehub_http_request_parse(const char *buffer, size_t length,
                               filehub_http_request_t *request, size_t *consumed);

#endif
