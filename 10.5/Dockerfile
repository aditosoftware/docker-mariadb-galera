# vim:set ft=dockerfile:
FROM debian:buster-slim

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

# https://bugs.debian.org/830696 (apt uses gpgv by default in newer releases, rather than gpg)
RUN set -ex; \
  apt-get update; \
  if ! which gpg; then \
    apt-get install -y --no-install-recommends gnupg; \
  fi; \
  if ! gpg --version | grep -q '^gpg (GnuPG) 1\.'; then \
# so, if we're not running gnupg 1.x, explicitly install dirmngr too
    apt-get install -y --no-install-recommends dirmngr; \
  fi; \
  rm -rf /var/lib/apt/lists/*

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION 1.12
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget; \
    rm -rf /var/lib/apt/lists/*; \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
    apt-mark auto '.*' > /dev/null; \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    chmod +x /usr/local/bin/gosu; \
    gosu --version; \
    gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d

# install runtime dependencies
RUN set -ex; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    pwgen \
    tzdata \
    xz-utils \
    cracklib-runtime \
    curl \
    jq \
    libpwquality-tools \
    procps \
    socat \
  ; \
  rm -rf /var/lib/apt/lists/*

ENV GPG_KEYS \
# pub   rsa4096 2016-03-30 [SC]
#         177F 4010 FE56 CA33 3630  0305 F165 6F24 C74C D1D8
# uid           [ unknown] MariaDB Signing Key <signing-key@mariadb.org>
# sub   rsa4096 2016-03-30 [E]
  177F4010FE56CA3336300305F1656F24C74CD1D8

RUN set -ex; \
  export GNUPGHOME="$(mktemp -d)"; \
  for key in $GPG_KEYS; do \
    gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
  done; \
  gpg --batch --export $GPG_KEYS > /etc/apt/trusted.gpg.d/mariadb.gpg; \
  command -v gpgconf > /dev/null && gpgconf --kill all ||: ; \
  rm -r "$GNUPGHOME"; \
  apt-key list

# bashbrew-architectures: amd64 arm64v8 ppc64le
ARG MARIADB_MAJOR=10.5
ARG MARIADB_VERSION=1:10.5.20+maria~buster
# release-status:Stable
# (https://downloads.mariadb.org/mariadb/+releases/)

RUN set -e;\
  echo "deb http://ftp.osuosl.org/pub/mariadb/repo/$MARIADB_MAJOR/debian buster main" > /etc/apt/sources.list.d/mariadb.list; \
  { \
    echo 'Package: *'; \
    echo 'Pin: release o=MariaDB'; \
    echo 'Pin-Priority: 999'; \
  } > /etc/apt/preferences.d/mariadb
# add repository pinning to make sure dependencies from this MariaDB repo are preferred over Debian dependencies
#  libmariadbclient18 : Depends: libmysqlclient18 (= 5.5.42+maria-1~wheezy) but 5.5.43-0+deb7u1 is to be installed

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN set -ex; \
  { \
    echo "mariadb-server-$MARIADB_MAJOR" mysql-server/root_password password 'unused'; \
    echo "mariadb-server-$MARIADB_MAJOR" mysql-server/root_password_again password 'unused'; \
  } | debconf-set-selections; \
  apt-get update; \
  apt-get install -y \
    galera-4 \
    galera-arbitrator-4 \
    "mariadb-client=$MARIADB_VERSION" \
    "mariadb-server=$MARIADB_VERSION" \
# mariadb-backup is installed at the same time so that `mysql-common` is only installed once from just mariadb repos
    mariadb-backup \
    ; \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false dirmngr; \
  rm -rf /var/lib/apt/lists/*; \
# purge and re-create /var/lib/mysql with appropriate ownership
  rm -rf /var/lib/mysql; \
  mkdir -p /var/lib/mysql /var/run/mysqld; \
  chown -R mysql:mysql /var/lib/mysql /var/run/mysqld; \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
  chmod 777 /var/run/mysqld; \
# comment out a few problematic configuration values
  find /etc/mysql/ -name '*.cnf' -print0 \
  | xargs -0 grep -lZE '^(bind-address|log|user\s)' \
  | xargs -rt -0 sed -Ei 's/^(bind-address|log|user\s)/#&/'; \
# don't reverse lookup hostnames, they are usually another container
  echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf

VOLUME /var/lib/mysql

ADD galera.cnf /etc/mysql/conf.d/galera.cnf
RUN chown mysql:mysql -R /etc/mysql/conf.d

COPY entrypoint.sh /entrypoint.sh
COPY report_status.sh /usr/local/bin/report_status.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

EXPOSE 3306 4444 4567 4568

WORKDIR /var/lib/mysql
ENTRYPOINT ["/entrypoint.sh"]
CMD ["mysqld"]
