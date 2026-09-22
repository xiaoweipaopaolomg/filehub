# FileHub deployment

FileHub is deployed as a native Linux binary. Conda is only used by the test
tooling and is not required by the service.

## Prerequisites

- Linux x86-64 with glibc
- systemd running as PID 1
- root or sudo access for system installation
- curl for the deployment smoke test
- an unprivileged www-data user and group
- an unused TCP port (8080 by default)

Confirm systemd before installing:

~~~sh
ps -p 1 -o comm=
~~~

The result must be systemd. The default unit has no network capabilities, so
use a port of 1024 or above unless the unit is deliberately changed.

## Validate without changing the system

Build and perform a staged installation under a temporary directory:

~~~sh
make clean all
make deploy-check
~~~

This checks the installed paths and modes, preservation of an existing
configuration, startup, HTTP/HEAD/Range/status/metrics behavior, graceful
SIGTERM exit, port conflicts, invalid configuration and a missing document
root. It does not write to /etc, /usr/local or /srv.

To inspect a staged tree manually:

~~~sh
DESTDIR=/tmp/filehub-stage bash deploy/install.sh --no-start
find /tmp/filehub-stage -maxdepth 4 -type f -ls
~~~

## System installation

For the default configuration and port:

~~~sh
make clean all
sudo bash deploy/install.sh
~~~

The installer atomically replaces the binary, preserves an existing
configuration and existing document files, validates the unit, reloads
systemd, enables and restarts the service, and finally runs the smoke test.

Installed layout:

~~~text
/usr/local/bin/filehub
/etc/filehub/filehub.conf
/etc/systemd/system/filehub.service
/srv/filehub/index.html
/srv/filehub/info.html
~~~

To review or edit configuration before the first start:

~~~sh
sudo bash deploy/install.sh --no-start
sudo editor /etc/filehub/filehub.conf
sudo systemctl enable --now filehub.service
bash deploy/smoke_test.sh --systemd
~~~

The installer does not replace an existing configuration unless
--force-config is supplied.

## Operations

~~~sh
sudo systemctl status filehub.service
sudo systemctl reload filehub.service
sudo systemctl restart filehub.service
sudo systemctl stop filehub.service
journalctl -u filehub.service -n 100 --no-pager
journalctl -u filehub.service -f
bash deploy/smoke_test.sh --systemd
~~~

Reload sends SIGHUP and only applies request, Keep-Alive and write timeouts plus
the access-log setting. Port, document root, worker count and connection limits
require a restart.

The service runs as www-data, has no Linux capabilities, cannot access home
directories, and sees the system and device trees as read-only/restricted.
Files under /srv/filehub therefore need only be readable, not writable, by
www-data.

## Troubleshooting

~~~sh
sudo systemctl --no-pager --full status filehub.service
journalctl -u filehub.service -b --no-pager
sudo -u www-data test -r /srv/filehub/index.html
ss -ltnp | grep ':8080'
~~~

Common failures are an occupied port, an invalid key=value entry, a missing
document root, or unreadable files. When clients connect from another machine,
also check the host firewall and bind/network reachability.

## Deployed-service pressure test

After the systemd smoke test passes, run the default one-minute pressure
acceptance:

~~~sh
conda activate filehub-test
bash deploy/run_pressure_test.sh
~~~

High-rate tests must not run with per-request access logging enabled. The
wrapper asks for sudo, temporarily changes access_log=1 to access_log=0,
reloads the service, and restores the original value on normal completion,
failure, Ctrl-C or termination.

The test uses 10, 50, 100 and 200 persistent connections for 15 seconds each.
It requires zero socket errors and zero non-2xx responses, checks the response
SHA-256 after every level, confirms that systemd did not restart the service,
and verifies that RSS and file descriptors return near their baseline. Raw wrk
output, metadata and the service journal are saved under tests/results.

To test another deployed file or use a longer run:

~~~sh
bash deploy/run_pressure_test.sh --path /archive.bin --duration 30
~~~

Use a real downloadable file for transfer-throughput testing. The default
/info.html target primarily stresses request parsing, connection management and
response dispatch.

The lower-level load_test.sh refuses to start when the deployed configuration
still contains access_log=1, preventing accidental journal flooding.
