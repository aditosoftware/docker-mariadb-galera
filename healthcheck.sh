#!/bin/sh

status() {
    var=$1
    mysql --user=root --password="$MYSQL_ROOT_PASSWORD" -ABse "SHOW GLOBAL STATUS LIKE '${var}';" | awk '{ print $2 }'
}

galera_cnf() {
    grep "$1" /etc/mysql/conf.d/galera.cnf | awk -F' = ' '{ print $2 }'
}

is_ready() {
    # Return OK when container is still initializing
    if [ -S /var/run/mysqld/mysqld.sock ]; then
        if [ -f /tmp/entrypoint.init ]; then
            if [ "$(status wsrep_ready)" ]; then
                rm -f /tmp/entrypoint.init
            else
                exit 0
            fi
        fi
    fi
}

health_check() {
    is_ready
    ready=$(status wsrep_ready)
    connected=$(status wsrep_connected)
    state=$(status wsrep_local_state_comment)

    if [ "$(status wsrep_ready)" = "ON" ] && \
        [ "$(status wsrep_connected)" = "ON" ] && \
        [ "$(status wsrep_local_state_comment)" = "Synced" ]; then
            exit 0
        else
            echo ">> Healthcheck failed"
            echo "wsrep_ready: $ready"
            echo "wsrep_connected: $connected"
            echo "wsrep_local_state_comment: $state"
            exit 1
    fi
}

health_check_verbose() {
    echo "Galera node info:"
    echo "  Name: $(galera_cnf wsrep_node_name)"
    echo "  IPv4 address: $(galera_cnf wsrep_node_address)"
    is_ready
    echo ">> wsrep_cluster_address:      $(galera_cnf wsrep_cluster_address)"
    echo ">> wsrep_ready:                $(status wsrep_ready)"
    echo ">> wsrep_connected:            $(status wsrep_connected)"
    echo ">> wsrep_local_state_comment:  $(status wsrep_local_state_comment)"
    echo ">> wsrep_local_send_queue_avg: $(status wsrep_local_send_queue_avg)"
    if [ "$(wsrep_flow_control_paused 2>/dev/null)" ]; then
        echo ">> wsrep_flow_control_paused:  $(wsrep_flow_control_paused)"
    fi
}

case "$1" in
    --verbose|-v)
        health_check_verbose
        ;;
    *)
        health_check
        ;;
esac
