#!/bin/sh
# Hadoop (inside Spark) needs a user name for the process's uid. A pod may run as a uid the image doesn't name:
# give it one through nss_wrapper (a passwd file in $HOME), leaving /etc/passwd read-only.
set -eu
if ! getent passwd "$(id -u)" >/dev/null; then
  cp /etc/passwd "$HOME/passwd"
  printf 'teehr-run:x:%s:%s:teehr-evaluate:%s:/usr/sbin/nologin\n' "$(id -u)" "$(id -g)" "$HOME" >> "$HOME/passwd"
  export LD_PRELOAD=libnss_wrapper.so NSS_WRAPPER_PASSWD="$HOME/passwd" NSS_WRAPPER_GROUP=/etc/group
fi
exec "$@"
