#!/bin/sh

# shellcheck disable=SC2086

# Report Galera status to etcd periodically.
# report_status.sh [mysql user] [mysql password] [cluster name] [interval] [comma separated etcd hosts]
# Example: 
# report_status.sh root myS3cret galera_cluster 15 192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379

USER=$1
PASSWORD=$2
CLUSTER_NAME=$3
TTL=$4
ETCD_CLUSTER=$5
IPADDR=$6

check_etcd() {
    if ! curl -s -m 60 http://$ETCD_CLUSTER/health > /dev/null; then
        echo >&2 "$(date +'%F %T') report_status [Error]: etcd cluster is not available. $?"
        return 1
    fi

    etcd_health=$(curl -s http://$ETCD_CLUSTER/health | jq -r '.health')
    if [ "$etcd_health" != "true" ]; then
        echo >&2 "$(date +'%F %T') report_status [Error]: etcd cluster is not healthy, status check:"
        metrics=$(curl -s http://$ETCD_CLUSTER/metrics)
        echo "$metrics" | grep -s ^etcd_server_has_leader >&2
        echo "$metrics" | grep -s ^etcd_server_leader_changes_seen_total >&2
        echo "$metrics" | grep -s ^etcd_server_proposals_failed_total >&2
        return 1
    fi
}

report_status() {
  var=$1
  key=$2

  if [ -n "$var" ]; then
    check_etcd

    URL="http://$ETCD_CLUSTER/v2/keys/galera/$CLUSTER_NAME"

    # let the top dir expire after 120s, assume container is no longer available
    curl -s "$URL/$IPADDR" -X PUT -d ttl=120 -d dir=true -d prevExist=true > /dev/null

    output=$(mysql --user=$USER --password=$PASSWORD -A -Bse "show status like '$var'" 2> /dev/null)
    if [ -z $key ]; then
      key=$(echo $output | awk '{ print $1 }')
    fi
    value=$(echo $output | awk '{ print $2 }')

    if [ -n "$value" ]; then
      curl -s "$URL/$IPADDR/$key" -X PUT -d value=$value -d ttl=$TTL > /dev/null
    fi
  fi
}

while true;
do
  report_status wsrep_local_state_comment
  report_status wsrep_last_committed seqno
  # report every ttl - 2 to ensure value does not expire
  sleep $((TTL - 2))
done
