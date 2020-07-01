#!/bin/bash

# shellcheck disable=SC2086
set -e

join() {
    local IFS="$1"; shift; echo "$*";
}

IPADDR=$(hostname -i | awk '{print $1}')
[ -z $IPADDR ] && IPADDR=$(hostname -I | awk '{print $1}')
[ -z $NODE_NAME ] && NODE_NAME=$(hostname)
[ -z $SST_USER ] && SST_USER=sst

# Setup galera.cnf
sed -i -e "s|NODE_IP|${IPADDR}|g" \
    -i -e "s|NODE_NAME|${NODE_NAME}|g" \
    -i -e "s|WSREP_NODE_ADDRESS|${IPADDR}|g" \
    -i -e "s|SST_USER|${SST_USER}|g" \
    -i -e "s|SST_PASSWORD|${SST_PASSWORD}|g" \
    /etc/mysql/conf.d/galera.cnf

# Can be used by health check
gosu mysql touch /tmp/entrypoint.init

if [ "$1" = 'mysqld' ]; then

    [ -z "$TTL" ] && TTL=10

    if [ -z "$CLUSTER_NAME" ]; then
        echo >&2 'Error: please specify CLUSTER_NAME'
        exit 1
    fi

    # TODO: replace/merge initdb with https://github.com/docker-library/mariadb/blob/master/10.1/docker-entrypoint.sh
    if [ -z "$DATADIR" ]; then
        DATADIR="/var/lib/mysql"
    fi

    # start initdb
    if [ ! -s "$DATADIR/grastate.dat" ]; then
        INITIALIZED=1

        if [ -z "$MYSQL_ROOT_PASSWORD" ] && [ -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ] && [ -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            echo >&2 "Error: database is uninitialized and password option is not specified"
            echo >&2 "Please specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD"
            exit 1
        fi

        echo ">> No existing database found, creating a new one"

        echo ">> Running mysql_install_db"
        mysql_install_db --user=mysql --datadir="$DATADIR" --rpm
        echo ">> Finished mysql_install_db"

        mysqld --user=mysql --datadir="$DATADIR" --skip-networking --wsrep-cluster-address='gcomm://' &
        pid="$!"

        mysql=(mysql -uroot)

        echo ">> Waiting on the database for 30s..."
        for i in {30..0}; do
            if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
                break
            fi
            sleep 1
        done
        if [ "$i" = 0 ]; then
            echo >&2 "Error: MariaDB database not initialized, aborting."
            exit 1
        fi

        # sed is for https://bugs.mysql.com/bug.php?id=20545
        mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
        if [ -n "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            MYSQL_ROOT_PASSWORD="$(pwmake 128)"
            echo ">> GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
        fi

"${mysql[@]}" <<-EOSQL
    -- What's done in this file shouldn't be replicated
    --  or products like mysql-fabric won't work
    SET @@SESSION.SQL_LOG_BIN=0;
    DELETE FROM mysql.user ;
    CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
    GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
    CREATE USER '${SST_USER}'@'localhost' IDENTIFIED BY '${SST_PASSWORD}';
    GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${SST_USER}'@'localhost';
    GRANT REPLICATION CLIENT ON *.* TO monitor@'%' IDENTIFIED BY 'monitor';
    DROP DATABASE IF EXISTS test ;
    FLUSH PRIVILEGES ;
EOSQL

        if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
            mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
        fi

        if [ "$MYSQL_DATABASE" ]; then
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
            mysql+=( "$MYSQL_DATABASE" )
        fi

        if [ "$MYSQL_USER" ] && [ "$MYSQL_PASSWORD" ]; then
            echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" | "${mysql[@]}"
            if [ "$MYSQL_DATABASE" ]; then
                echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
            fi
            echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
        fi

        if [ -n "$MYSQL_ONETIME_PASSWORD" ]; then
"${mysql[@]}" <<-EOSQL
    ALTER USER 'root'@'%' PASSWORD EXPIRE;
EOSQL
        fi

        if ! kill -s TERM "$pid" || ! wait "$pid"; then
            echo >&2 "Error: MySQL init process failed."
            exit 1
        fi

        chown -R mysql:mysql "$DATADIR"

        echo ">> MariaDB database initialized."
        echo
    fi
    # end initdb

    # start EMPTY ETCD_CLUSTER
    # TODO: unsupported
    if [ -z "$ETCD_CLUSTER" ]; then
        cluster_join=$CLUSTER_JOIN
    else
        echo ">> Registering with etcd cluster"

        if ! curl -s -m 60 http://$ETCD_CLUSTER/health > /dev/null; then
            echo >&2 "Error: etcd cluster is not available."
            exit 1
        fi

        etcd_health=$(curl -s http://$ETCD_CLUSTER/health | jq -r '.health')
        if [ "$etcd_health" == "false" ]; then
            echo >&2 "Error: etcd cluster not ready."
            exit 1
        fi

        URL="http://$ETCD_CLUSTER/v2/keys/galera/$CLUSTER_NAME"

        set +e

        echo ">> Waiting for $TTL seconds to read non-expired keys.."
        sleep $TTL

        # Read the list of registered IP addresses
        echo ">> Retrieving list of keys for $CLUSTER_NAME"

        cluster_join=$(curl -s $URL | jq -r '.? | .node.nodes[].key | split("/") | .[3]' | sed 's/ /,/g')

        if [[ -z $cluster_join ]]; then
          echo
          echo ">> Registering first node ($IPADDR) in http://$ETCD_CLUSTER"
          curl -s "$URL/$IPADDR" -X PUT -d dir=true -d ttl=120
          curl -s "$URL/$IPADDR/ipaddress" -X PUT -d "value=$IPADDR"
        else
          curl -s "${URL}?recursive=true&sorted=true" > /tmp/out
          running_nodes=$(jq -r '.node.nodes[].nodes[]? | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key | split("/") | .[3]' < /tmp/out)

          echo ">> Running nodes: [${running_nodes}]"

          # TODO: don't do that on a new node not present in etcd
          if [ -z "$running_nodes" ]; then
            # if there is no Synced node, determine the sequence number.
            TMP=/var/lib/mysql/$(hostname).err
            echo
            echo ">> There is no node in synced state."
            echo ">> It's unsafe to bootstrap unless the sequence number is the latest."
            echo ">> Determining the Galera last committed seqno using --wsrep-recover.."

            mysqld_safe --wsrep-cluster-address=gcomm:// --wsrep-recover
            seqno=$(tr ' ' "\n" < $TMP | grep -e '[a-z0-9]*-[a-z0-9]*:[0-9]' | head -1 | cut -d ":" -f 2)

            # if this is a new container, set seqno to 0
            if [ $INITIALIZED ] && [ $INITIALIZED -eq 1 ]; then
                echo
                echo ">> This is a new container, thus setting seqno to 0."
                seqno=0
            fi

            if [ -n "$seqno" ]; then
                echo
                echo ">> Reporting seqno:$seqno to etcd cluster ${ETCD_CLUSTER}."
                WAIT=$((TTL * 2))
                curl -s "$URL/$IPADDR/seqno" -X PUT -d "value=$seqno&ttl=$WAIT"
            else
                seqno=$(tr ' ' "\n" < $TMP | grep -e '[a-z0-9]*-[a-z0-9]*:[0-9]' | head -1)
                echo >&2 "Error: Unable to determine Galera sequence number."
                exit 1
            fi
            rm $TMP

            echo
            echo ">> Sleeping for $TTL seconds to wait for other nodes to report."
            sleep $TTL

            echo
            echo ">> Retrieving list of seqno for $CLUSTER_NAME"
            bootstrap_flag=1

            # Retrieve seqno from etcd
            curl -s "${URL}?recursive=true&sorted=true" > /tmp/out
            cluster_seqno=$(jq -r '.node.nodes[].nodes[]? | select(.key | contains ("seqno")) | .value' < /tmp/out | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

            for i in $cluster_seqno; do
              if [ $i -gt $seqno ]; then
                bootstrap_flag=0
                echo >&2 ">> Found another node holding a greater seqno ($i/$seqno)"
              fi
            done

            if [ $bootstrap_flag -eq 1 ]; then
                # Find the earliest node to report if there is no higher seqno
                # node_to_bootstrap=$(cat /tmp/out | jq -c '.node.nodes[].nodes[]?' | grep seqno | tr ',:\"' ' ' | sort -k 11 | head -1 | awk -F'/' '{print $(NF-1)}')
                # The earliest node to report if there is no higher seqno is computed wrongly: issue #6
                node_to_bootstrap=$(jq -c '.node.nodes[].nodes[]?' < /tmp/out | grep seqno | tr ',:"' ' ' | sort -k5,5r -k11 | head -1 | awk -F'/' '{print $(NF-1)}')
                if [ "$node_to_bootstrap" == "$IPADDR" ]; then
                    echo
                    echo ">> This node is safe to bootstrap."
                    cluster_join=
                else
                    echo
                    echo ">> Based on timestamp, $node_to_bootstrap is the chosen node to bootstrap."
                    echo ">> Wait again for $TTL seconds to look for a bootstrapped node."
                    sleep $TTL
                    curl -s "${URL}?recursive=true&sorted=true" > /tmp/out

                    # Look for a synced node again
                    running_nodes2=$(jq -r '.node.nodes[].nodes[]? | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' < /tmp/out | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

                    echo
                    echo ">> Running nodes: [${running_nodes2}]"

                    if [ -n "$running_nodes2" ]; then
                        cluster_join=$(join , $running_nodes2)
                    else
                        echo
                        echo >&2 "Error: unable to find a bootstrapped node to join."
                        echo >&2 "Exiting."
                        exit 1
                    fi
                fi
            else
                echo
                echo ">> Refusing to start for now because there is a node holding higher seqno."
                echo ">> Wait again for $TTL seconds to look for a bootstrapped node."
                sleep $TTL

                # Look for a synced node again
                curl -s "${URL}?recursive=true&sorted=true" > /tmp/out
                running_nodes3=$(jq -r '.node.nodes[].nodes[]? | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' < /tmp/out | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

                echo
                echo >&2 ">> Running nodes: [${running_nodes3}]"

                if [ -n "$running_nodes2" ]; then
                    cluster_join=$(join , $running_nodes3)
                else
                    echo
                    echo >&2 "Error: Unable to find a bootstrapped node to join."
                    echo >&2 "Exiting."
                    exit 1
                fi
            fi
          else
              # if there is a Synced node, join the address
              cluster_join=$(join , $running_nodes)
          fi
        fi
        set -e
    fi # end EMPTY ETCD_CLUSTER

    echo
    echo ">> Starting reporting script in the background"
    nohup /report_status.sh root $MYSQL_ROOT_PASSWORD $CLUSTER_NAME $TTL $ETCD_CLUSTER $IPADDR &

    echo
    echo ">> Starting mysqld process"

    if [ -z $cluster_join ]; then
        export _WSREP_NEW_CLUSTER='--wsrep-new-cluster'
        # set safe_to_bootstrap = 1
        GRASTATE=$DATADIR/grastate.dat
        [ -f $GRASTATE ] && sed -i "s|safe_to_bootstrap.*|safe_to_bootstrap: 1|g" $GRASTATE
    else
        unset _WSREP_NEW_CLUSTER
    fi

    if [ "${1:0:1}" = '-' ]; then
        set -- mysqld "$@"
    fi

    if [ "$(id -u)" = "0" ]; then
        exec gosu mysql "$@" --wsrep_cluster_name=$CLUSTER_NAME --wsrep-cluster-address="gcomm://$cluster_join" --wsrep_sst_auth="$SST_USER:$SST_PASSWORD" $_WSREP_NEW_CLUSTER
    fi
fi

exec "$@"
