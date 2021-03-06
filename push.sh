#!/bin/bash

set -e # exit on error

cd `dirname $0`
source .default.sh

# Always start a build
GOPATH=$(cd ../../../..;pwd) go build &

# Were we called by ./tunnel?
if [ "$1" == -t ]; then
  tunnel=yes
  shift
fi

handleKnownHosts(){
  local prefix=$1
  local localHostkey=$2

  hostsEntry="[$prefix]:$CHISEL_LOCAL_PORT `cat $localHostKey.pub`"
  fgrep -q "$hostsEntry" ~/.ssh/known_hosts || echo "$hostsEntry" >> ~/.ssh/known_hosts
}

handleHostKey(){
  # Generate a key to identify the server (if one doesn't already exist)
  # TODO: put all generated files (this and id_rsa.pub) into a single directory
  local deployHostKey=ssh_host_rsa_key 
  local localHostKey="$HOME/.ssh/chisel_host_rsa_key" # NOTE: also used to find .pub key!
  if [ ! -r $deployHostKey ]; then
    if [ ! -r $localHostKey ]; then
      ssh-keygen -t rsa -f $localHostKey -N '' -C "chisel-ssh identity"
    fi

    cp $localHostKey $deployHostKey
  fi

  # We always check to see if the key is in known_hosts, because it's a per-port
  # entry. Many entries will all use the same key. We add entries for both
  # 'localhost' and '127.0.0.1'.
  handleKnownHosts 127.0.0.1 $localHostKey
  handleKnownHosts localhost $localHostKey
}

handlePrivateKey(){
  if [ ! -r id_rsa.pub ]; then
    cp ~/.ssh/id_rsa.pub .
  fi
}

checkIfRunning(){
  echo "Checking if $CHISEL_APP_NAME is running"
  set +e
  local out=`cf app $CHISEL_APP_NAME`
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "cf app $CHISEL_APP_NAME returned $rc; looking for it via 'cf apps'" >&2
    out=`cf apps`
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "cf apps returned $rc"
      exit $rc
    fi

    lineCount=`echo "$out" | wc -l`
    secondLine=`echo "$out" | head -n2 | tail -n1`
    if [ "$secondLine" != "OK" -o $lineCount -lt 4 ]; then
      echo "unexpected results from 'cf apps':"
      echo
      echo "$out"
      exit 2
    fi

    # At this point, assume things are OK and that the app just isn't installed.
  else
    if echo "$out" | grep -q running; then
      echo "$CHISEL_APP_NAME is running; skipping push."
      wait # Make sure build is done
      exit
    fi
  fi
}

# Before anything else, we want to handle creating a host key, and ensure that
# that host key is registered in known_hosts. This makes it much easier to
# debug issues with key registration.
handleHostKey
checkIfRunning
handlePrivateKey

if ! grep -q 'Host chisel' ~/.ssh/config; then
cat <<_EOF_

You might want to add this entry to ~/.ssh/config. Note that the config file is
position-sensitive, so this needs to be added before the 'Host *' entry if you
have one.

Host chisel
    ForwardAgent yes
    HostName localhost
    Port $CHISEL_LOCAL_PORT
    User vcap
    Compression yes
_EOF_
fi

echo "pushing $CHISEL_APP_NAME to cloud foundry"

cf push -t 180 $@ "$CHISEL_APP_NAME" # -t: maximum number of seconds to wait for app to start

wait

# If we weren't started by tunnel, run ./tunnel
[ -n "$tunnel" ] || ./tunnel

# vi: expandtab sw=2 ts=2
