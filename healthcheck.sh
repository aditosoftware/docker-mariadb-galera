#!/bin/sh

status() {
    var=$1
    mysql --user=root --password="$MYSQL_ROOT_PASSWORD" -ABse "SHOW GLOBAL STATUS LIKE '${var}';" | awk '{ print $2 }'
}

is_ready() {
    # check for mysqld socket
    if [ ! -S /var/run/mysqld/mysqld.sock ]; then
        exit 1
    fi
    # check mysqld status
    if ! mysqladmin status --user=root --password="$MYSQL_ROOT_PASSWORD" >/dev/null; then
        exit 1
    fi
    # check galera status
    if ! status wsrep_ready; then
        exit 1
    fi
    # entrypoint is finished at this point
    if [ -f /tmp/entrypoint.init ]; then
        rm -f /tmp/entrypoint.init
    fi
}

is_alive() {
    if ! mysqladmin status --user=root --password="$MYSQL_ROOT_PASSWORD" >/dev/null; then
        exit 1
    fi
}

case "$1" in
    --readiness)
        is_ready
        ;;
    --liveness)
        is_alive
        ;;
    *)
        ;;
esac
exit 0
