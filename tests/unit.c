#define _GNU_SOURCE
#include "../http_request.h"
#include "../http_response.h"
#include "../file_service.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* 验证增量解析、合法请求字段提取，以及不支持协议/请求体的拒绝逻辑。 */
static void test_http_request_parser(void) {
    const char *wire = "GET /index.html HTTP/1.1\r\nHost: local\r\nRange: bytes=2-5\r\n\r\n";
    filehub_http_request_t request;
    size_t consumed = 0;
    size_t length = strlen(wire);
    assert(filehub_http_request_parse(wire, 10, &request, &consumed) == 0); /* 请求分片尚未完整。 */
    assert(filehub_http_request_parse(wire, length, &request, &consumed) == 1);
    assert(consumed == length);
    assert(!strcmp(request.method, "GET"));
    assert(!strcmp(request.path, "/index.html"));
    assert(!strcmp(request.range, "bytes=2-5"));
    assert(request.keep_alive);
    assert(filehub_http_request_parse("GET / HTTP/2.0\r\n\r\n", 18,
                                      &request, &consumed) == -1);
    assert(filehub_http_request_parse(
               "GET / HTTP/1.1\r\nContent-Length: 8\r\n\r\n", 37,
               &request, &consumed) == -1);
}

/*
 * 在临时目录中验证 Range 半开区间换算，以及“..”和符号链接均不能
 * 逃逸 document root。所有临时资源在用例末尾显式回收。
 */
static void test_file_range_and_path_security(void) {
    char name[] = "/tmp/filehub-unit-XXXXXX";
    char *directory = mkdtemp(name);
    assert(directory);
    int root_fd = open(directory, O_RDONLY | O_DIRECTORY);
    assert(root_fd >= 0);
    int file_fd = openat(root_fd, "test.txt", O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(file_fd >= 0);
    assert(write(file_fd, "abcdef", 6) == 6);
    close(file_fd);
    assert(symlinkat("/etc/passwd", root_fd, "escape") == 0);

    /* bytes=2-4 对应文件偏移半开区间 [2, 5)。 */
    filehub_http_request_t request = {0};
    strcpy(request.method, "GET");
    strcpy(request.path, "/test.txt");
    strcpy(request.range, "bytes=2-4");
    request.keep_alive = 1;
    filehub_http_response_t response;
    filehub_file_prepare_response(root_fd, &request, &response);
    assert(response.status == 206);
    assert(response.file_start == 2 && response.file_end == 5);
    char headers[2048];
    assert(filehub_http_response_format_headers(&response, headers,
                                                sizeof(headers)) > 0);
    assert(strstr(headers, "Content-Range: bytes 2-4/6\r\n"));
    filehub_http_response_close(&response);

    strcpy(request.range, "bytes=99-");
    filehub_file_prepare_response(root_fd, &request, &response);
    assert(response.status == 416);
    assert(response.full_size == 6);
    filehub_http_response_close(&response);

    request.range[0] = '\0';
    /* 即使前置目录不存在，包含“..”的路径也必须返回 403 而不是 404。 */
    strcpy(request.path, "/missing/../test.txt");
    filehub_file_prepare_response(root_fd, &request, &response);
    assert(response.status == 403);
    filehub_http_response_close(&response);
    strcpy(request.path, "/escape");
    filehub_file_prepare_response(root_fd, &request, &response);
    assert(response.status == 403);
    filehub_http_response_close(&response);

    assert(unlinkat(root_fd, "test.txt", 0) == 0);
    assert(unlinkat(root_fd, "escape", 0) == 0);
    close(root_fd);
    assert(rmdir(directory) == 0);
}

int main(void) {
    test_http_request_parser();
    test_file_range_and_path_security();
    puts("unit tests passed");
    return 0;
}
