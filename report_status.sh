#!/bin/sh

# shellcheck disable=SC2086
set -x

# Report Galera status to etcd periodically.
# report_status.sh [mysql user] [mysql password] [cluster name] [interval] [comma separated etcd hosts]
# Example: 
# report_status.sh root myS3cret galera_cluster 15 192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379

USER=$1
PASSWORD=$2
CLUSTER_NAME=$3
TTL=$4
ETCD_CLUSTER=$5

check_etcd() {
    curl -s http://$ETCD_CLUSTER/health > /dev/null
    if curl -s http://$ETCD_CLUSTER/health | jq -e 'contains({ "health": "true"})' > /dev/null; then
        flag=0
    fi
    # Flag is 0 if there is a healthy etcd host
    [ $flag -ne 0 ] && echo "report>> Couldn't reach healthy etcd nodes."
}

report_status() {
  var=$1
  key=$2

  if [ -n "$var" ]; then
    check_etcd

    URL="http://$ETCD_CLUSTER/v2/keys/galera/$CLUSTER_NAME"
    output=$(mysql --user=$USER --password=$PASSWORD -A -Bse "show status like '$var'" 2> /dev/null)
    if [ -z $key ]; then
      key=$(echo $output | awk '{ print $1 }')
    fi
    value=$(echo $output | awk '{ print $2 }')
    ipaddr=$(hostname -i | awk '{ print $1 }')

    if [ -n "$value" ]; then
      curl -s "$URL/$ipaddr/$key" -X PUT -d "value=$value&ttl=$TTL" > /dev/null
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
