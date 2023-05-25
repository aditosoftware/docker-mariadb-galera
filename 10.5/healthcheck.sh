#!/bin/sh

status() {
    var=$1
    mysql --user=root --password="$MYSQL_ROOT_PASSWORD" -ABse "SHOW GLOBAL STATUS LIKE '${var}';" | awk '{ print $2 }'
}

is_ready() {
    # check mysqld status
    if ! mysqladmin ping --user=root --password="$MYSQL_ROOT_PASSWORD" >/dev/null; then
        exit 1
    fi
    # check mysqld status
    if ! mysqladmin status --user=root --password="$MYSQL_ROOT_PASSWORD" >/dev/null; then
        exit 1
    fi
}

case "$1" in
    --readiness)
        is_ready
        ;;
    --liveness)
        is_ready
        ;;
    *)
        ;;
esac
exit 0
