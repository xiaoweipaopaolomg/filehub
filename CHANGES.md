# FileHub implementation checklist

## Implemented

- Replaced the original write-once worker design with a Reactor that alone owns client sockets and epoll registrations. Client events use edge-triggered `EPOLLONESHOT` and a connection generation token.
- Added bounded worker tasks and a completion queue; `eventfd` returns completed file-open results to the Reactor. Stale results are discarded and their file descriptors closed.
- Added incremental request-header parsing, a 16 KiB header limit, HTTP/1.1 Keep-Alive, `GET` and `HEAD`, and sequential handling of pipelined requests.
- Added partial `send()`/`sendfile()` handling. On `EAGAIN`, the socket is rearmed for `EPOLLOUT`; each event has a 1 MiB send budget.
- Enabled `TCP_NODELAY` on accepted sockets. A same-machine A-B-A test showed that this removes the roughly 44 ms small-response delay caused by the interaction between separately written headers/bodies and delayed ACKs.
- Added full-file and single-range downloads (`bytes=start-end`, `bytes=start-`, `bytes=-suffix`) with `206`/`416` responses.
- Added component-by-component `openat()` access beneath a preopened document root; traversal and symbolic links are rejected.
- Added `timerfd` checks for absolute request-header deadlines, idle Keep-Alive connections, stalled writes, and processing timeouts.
- Added `signalfd` handling for `SIGINT`/`SIGTERM` graceful shutdown and `SIGHUP` timeout/access-log reload.
- Added configurable port, document root, worker count, connection limit, queue limit, timeouts and access logging; provided a systemd unit example.
- Added a hardened systemd deployment bundle with atomic binary upgrades, configuration preservation, staged installation, lifecycle-safe smoke tests and documented operations.
- Added deployed-service pressure acceptance with response hashing, systemd restart detection, RSS/FD checks, raw wrk output and journal capture.
- Added `/status` and `/metrics`, including a counter for nonblocking write `EAGAIN` events.
- Unified the executable, source modules, public C APIs and regression runner under the `filehub` name.

## Verification

- `make test`: original 36 checks, parser/file-path unit checks, and 9 new integration checks pass.
- `make asan` followed by the integration suite: passes with AddressSanitizer and UndefinedBehaviorSanitizer.
- `make tsan` followed by the integration suite: passes with ThreadSanitizer.
- The slow download integration check verifies a SHA-256 match and a newly observed nonblocking-write `EAGAIN` event; another request completes while that client reads slowly.
- Valgrind 3.27.1 concurrent-disconnect check: 0 errors, 0 bytes in use at exit, and only the 3 inherited standard descriptors remained open.
- A 120-second, 12-client mixed-workload stability run completed 309,503 operations with 0 errors; sampled RSS remained 2,424 KiB and graceful shutdown completed in 5.79 seconds.
- wrk 4.2.0 same-machine regression covered `/status` and 64 B, 4 KiB, 64 KiB, 1 MiB and 8 MiB files at 1/10/50 connections, with three 5-second runs per case. All 54 runs reported 0 socket errors and 0 non-2xx responses. These localhost results are not disk or production-network measurements.
