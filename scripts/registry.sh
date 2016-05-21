#!/bin/bash
set -e

SCRIPT_START=$(date +%s%3N)

NAME=
LOCATION=
TAG=latest
VERBOSE=0
while getopts "n:l:t:v" opt; do
  case $opt in
    n) NAME=$OPTARG;;
    l) LOCATION=$OPTARG;;
    t) TAG=$OPTARG;;
    v) VERBOSE=1;;
  esac
done

log() {
  if [ $VERBOSE -eq 0 ]; then
    echo $@
  else
    echo $@
  fi
}

vlog() {
  if [ $VERBOSE -ne 0 ]; then
    log $@
  fi
}

vlog Initializing cluster $NAME@$LOCATION with $TAG version

begin() {
  TASK_START=$(date +%s%3N)
  if [ $VERBOSE -eq 0 ]; then
    echo -n $1...
    if [ -z "$2" ]; then
      LOGFILE=~/registry/init.log
    else
      LOGFILE=~/registry/$2.log
    fi
  else
    log $1...
    LOGFILE=/dev/stderr
  fi
}

beginex() {
  begin "$1 (takes a while)" "$2"
}


inc() {
  if [ $VERBOSE -eq 0 ]; then
    echo -n .
  elif [ -n "$*" ]; then
    log ...$@
  fi
}

err() {
  if [ $VERBOSE -eq 0 ]; then
    echo
  fi
  echo >&2 $@
  echo >&2 Cluster initialization failed
  # TODO: this should exit the entire init script, it doesn't
  exit 1
}

nab() {
  if [ $VERBOSE -eq 0 ]; then
    "$@" 2>>$LOGFILE || err "'$@' failed with code $?; see $LOGFILE"
  else
    "$@" || err "\"$@\" failed with code $?"
  fi
}

run() {
  if [ $VERBOSE -eq 0 ]; then
    "$@" >>$LOGFILE 2>&1 || err "'$@' failed with code $?; see $LOGFILE"
  else
    "$@" || err "\"$@\" failed with code $?"
  fi
}

retrun() {
  RETRIES=0
  if [ $VERBOSE -eq 0 ]; then
    until "$@" >>$LOGFILE 2>&1; do
      if [ $RETRIES -eq 4 ]; then
        err "'$@' failed after 4 retries; see $LOGFILE"
      fi
      sleep $((++RETRIES))
    done
  else
    until "$@"; do
      if [ $RETRIES -eq 4 ]; then
        err "'$@' failed after 4 retries"
      fi
      sleep $((++RETRIES))
    done
  fi
}

since() {
  if [ -z "$1" ]; then
    return
  fi
  ELAPSED=$(($(date +%s%3N) - $1))
  if [ $ELAPSED -lt 1000 ]; then
    echo ${ELAPSED}ms
  elif [ $ELAPSED -lt 60000 ]; then
    SECONDS=$((ELAPSED / 1000))
    TENTHS=$((ELAPSED % 1000 / 100))
    if [ $TENTHS -eq 0 ]; then
      echo ${SECONDS}s
    else
      echo ${SECONDS}.${TENTHS}s
    fi
  else
    MINUTES=$((ELAPSED / 60000))
    SECONDS=$((ELAPSED % 60000 / 1000))
    if [ $SECONDS -eq 0 ]; then
      echo ${MINUTES}m
    else
      echo ${MINUTES}m ${SECONDS}s
    fi
  fi
}

end() {
  LOGFILE=
  if [ $VERBOSE -eq 1 ]; then
    if [ -n "$TASK_START" ]; then
      vlog $@ in $(since $TASK_START)
    else
      vlog $@
    fi
  else
    echo $(since $TASK_START)
  fi
  TASK_START=
}

PATH="/opt/mesosphere/bin:$PATH"

rm -rf ~/registry && mkdir -p ~/registry

begin "Determining master and agent nodes"
MASTER_NODES=$(dig +short master.mesos | sort)
MASTER_NODE_COUNT=$(echo $MASTER_NODES | wc -w)
vlog $MASTER_NODE_COUNT masters: $MASTER_NODES
AGENT_PUBLIC_NODES=$(dig +short slave.mesos | sort | grep ^10\\.0\\.)
AGENT_PUBLIC_NODE_COUNT=$(echo $AGENT_PUBLIC_NODES | wc -w)
vlog $AGENT_PUBLIC_NODE_COUNT public agents: $AGENT_PUBLIC_NODES
AGENT_PRIVATE_NODES=$(dig +short slave.mesos | sort | grep ^10\\.32\\.)
AGENT_PRIVATE_NODE_COUNT=$(echo $AGENT_PRIVATE_NODES | wc -w)
vlog $AGENT_PRIVATE_NODE_COUNT private agents: $AGENT_PRIVATE_NODES
AGENT_NODES="$AGENT_PUBLIC_NODES $AGENT_PRIVATE_NODES"
ALL_NODES="$MASTER_NODES $AGENT_NODES"
end Determined master and agent nodes

begin "Registering all nodes as known hosts"
for node in $ALL_NODES; do
  if [ ! -n "$(ssh-keygen -H -F $node 2> /dev/null)" ]; then
    nab ssh-keyscan -t ecdsa $node >> ~/.ssh/known_hosts
  fi
done
end Registered all nodes as known hosts

begin "Configuring Docker for private registry" registry-conf
for node in $ALL_NODES; do
  run ssh -A $node '/bin/bash -s' << "  EOS" &
    DOCKER_CONF=/etc/systemd/system/docker.service.d/execstart.conf
    DOCKER_OPT=--insecure-registry=registry.marathon.mesos:5000
    if [ ! -n "$(grep -e $DOCKER_OPT $DOCKER_CONF)" ]; then
      sudo sed -i.orig "s/^ExecStart=\/.*/& $DOCKER_OPT/" $DOCKER_CONF
      sudo systemctl daemon-reload
      sudo systemctl restart docker.service
    fi
  EOS
done
wait
end Configured Docker for private registry

begin "Starting to cache Docker images"
for node in $AGENT_PUBLIC_NODES; do
  run ssh -A $node '/bin/bash -s' << "  EOS" &
    mkdir -p ~/registry
    nohup sudo docker pull registry:2 > ~/registry/docker-pull-registry.log 2>&1 &
  EOS
done
wait
end Started to cache Docker images

vlog Checking for DC/OS CLI installation
if [ ! -e ~/dcos/bin/dcos ]; then
  beginex "Installing DC/OS CLI" dcos-install
  run sudo $(which pip) install virtualenv
  if [ ! -e "$(dirname $(which pip))/virtualenv" ]; then
    run sudo ln -s $(dirname $(readlink $(which pip)))/virtualenv $(dirname $(which pip))/virtualenv
  fi
  rm -rf ~/dcos && mkdir -p ~/dcos
  nab wget --tries 4 --retry-connrefused --waitretry=15 -O- https://downloads.dcos.io/dcos-cli/install-optout.sh --no-check-certificate \
    | run /bin/bash -s ~/dcos/. http://leader.mesos --add-path yes
  if [ ! -e ~/dcos/bin/dcos ]; then
    err Failed to install DC/OS CLI
  fi
  end Installed DC/OS CLI
fi
DCOS=~/dcos/bin/dcos

vlog Checking for existing private Docker registry
if [ -n "$($DCOS marathon app list | grep '^/registry')" ]; then
  begin "Removing existing private Docker registry"
  retrun $DCOS marathon app remove --force registry
  end Removed existing private Docker registry
fi

begin "Determining master storage account name"
STORAGE_ACCOUNT_NAME=$(nab grep com\.netflix\.exhibitor\.azure\.account-name /opt/mesosphere/etc/exhibitor.properties | cut -d = -f 2-)
if [ ! -n "$STORAGE_ACCOUNT_NAME" ]; then
  err Failed to determine master storage account name
fi
vlog Master storage account name is $STORAGE_ACCOUNT_NAME
end Determined master storage account name

begin "Determining master storage account key"
STORAGE_ACCOUNT_KEY=$(nab grep com\.netflix\.exhibitor\.azure\.account-key /opt/mesosphere/etc/exhibitor.properties | cut -d = -f 2-)
if [ ! -n "$STORAGE_ACCOUNT_KEY" ]; then
  err Failed to determine master storage account key
fi
end Determined master storage account key

begin "Deploying private Docker registry" registry-deploy
cat << EOF > ~/registry/registry.json
{
    "id": "registry",
    "cpus": 0.2,
    "mem": 256,
    "instances": 1,
    "container": {
        "type": "DOCKER",
        "docker": {
            "image": "registry:2",
            "network": "HOST"
        }
    },
    "env": {
        "REGISTRY_STORAGE": "azure",
        "REGISTRY_STORAGE_AZURE_ACCOUNTNAME": "$STORAGE_ACCOUNT_NAME",
        "REGISTRY_STORAGE_AZURE_ACCOUNTKEY": "$STORAGE_ACCOUNT_KEY",
        "REGISTRY_STORAGE_AZURE_CONTAINER": "registry"
    },
    "ports": [ 5000 ],
    "requirePorts": true,
    "healthChecks": [
        {
            "port": 5000,
            "path": "/",
            "intervalSeconds": 5
        }
    ],
    "upgradeStrategy": {
      "minimumHealthCapacity": 0
    }
}
EOF
retrun $DCOS marathon app add ~/registry/registry.json
end Deployed private Docker registry



jval() {
  python -c "import sys,json;obj=json.load(sys.stdin);print(obj.get('$1'))"
}

jvals() {
  python -c "import sys,json;obj=json.load(sys.stdin);[print(elem.get('$2')) for elem in obj.get('$1')]"
}

log Cluster initialization completed successfully in $(since $SCRIPT_START)
