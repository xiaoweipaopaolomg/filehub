#include "config.h"
#include "server.h"

/*
 * FileHub 进程入口：先建立安全的默认配置，再按“配置文件 < 命令行”的
 * 优先级解析参数，最后把完整配置交给事件循环。main 只负责退出码映射，
 * 具体资源的申请与释放统一由 filehub_server_run() 管理。
 */
int main(int argc, char **argv) {
    filehub_config_t config;
    filehub_config_set_defaults(&config);
    int parse_status = filehub_config_parse_cli(&config, argc, argv);
    /* --help 属于正常退出；参数或配置错误使用常见的命令行错误码 2。 */
    if (parse_status > 0) return 0;
    if (parse_status < 0) { filehub_config_print_usage(argv[0]); return 2; }
    return filehub_server_run(&config) == 0 ? 0 : 1;
}
