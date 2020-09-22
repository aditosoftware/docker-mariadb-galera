# MariaDB Galera cluster for Docker

## Overview

The image runs MariaDB (with Galera support). It requires an etcd cluster to run homogeneously.
The Docker image requires/accepts the following parameters:

* one of variables: `MYSQL_ROOT_PASSWORD`, `MYSQL_ALLOW_EMPTY_PASSWORD` or `MYSQL_RANDOM_ROOT_PASSWORD` must be defined
* `ETCD_CLUSTER` must be present and defined as <hostname:port>
* the image will create the user `sst@localhost` for the mariabackup SST method. Use `SST_PASSWORD` to password for the `sst` user, set `XTRABACKUP_PASSWORD`. The username can be changed setting `SST_USER` variable

## Known Limitations

* split-brain not covered

## TODO

* WSREP_SST: [INFO] Logging all stderr of SST/Innobackupex to syslog
