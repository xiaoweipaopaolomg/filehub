CC = gcc
# 正式构建保留调试符号，并把常见警告提升为错误。
FLAGS = -O2 -g -Wall -Wextra -Werror -pedantic -std=c11 -pthread
# 自动生成头文件依赖，修改 .h 后会重新编译相关目标。
DEPFLAGS = -MMD -MP

OBJS = main.o config.o file_service.o http_response.o http_request.o server.o worker_pool.o
SOURCES = main.c config.c file_service.c http_response.c http_request.c server.c worker_pool.c

.PHONY: all clean test asan tsan deploy-check
# 默认只构建正式的 FileHub 可执行文件。
all: filehub

filehub: $(OBJS)
	$(CC) $(FLAGS) $(OBJS) -o $@

%.o: %.c
	$(CC) $(FLAGS) $(DEPFLAGS) -c $< -o $@

-include $(OBJS:.o=.d)

test: all
	# 依次执行历史回归、单元测试和端到端集成测试。
	bash filehub-regression-test.sh 7
	$(MAKE) unit_tests
	./unit_tests
	python3 tests/test_filehub.py

deploy-check: all
	# 在临时 DESTDIR 中验证安装产物，不修改当前系统。
	bash deploy/check.sh

unit_tests: tests/unit.c http_request.c http_response.c file_service.c
	$(CC) $(FLAGS) tests/unit.c http_request.c http_response.c file_service.c -o $@

asan:
	# AddressSanitizer 与 UndefinedBehaviorSanitizer 用于内存/未定义行为检查。
	$(CC) -O1 -g -Wall -Wextra -std=c11 -pthread -fsanitize=address,undefined -fno-omit-frame-pointer $(SOURCES) -o filehub-asan

tsan:
	# ThreadSanitizer 用于发现线程池共享状态的数据竞争。
	$(CC) -O1 -g -Wall -Wextra -std=c11 -pthread -fsanitize=thread -fno-omit-frame-pointer $(SOURCES) -o filehub-tsan

clean:
	rm -f *.o *.d filehub filehub-asan filehub-tsan unit_tests
