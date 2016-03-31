set -e

TAG=$1
if [ ! -n "$TAG" ]; then
  TAG=latest
fi

rm -rf ~/privatereg && mkdir -p ~/privatereg
echo -n Installing DCOS CLI...
LOG=~/privatereg/dcos-install.log
if [ ! -d ~/dcos ]; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes install -y python-pip >> $LOG
  sudo pip install virtualenv >> $LOG
  mkdir ~/dcos >> $LOG
  wget --tries 4 --retry-connrefused --waitretry=15 -qO- \
    https://downloads.mesosphere.com/dcos-cli/install-legacy-optout.sh \
    | /bin/bash -s ~/dcos/. http://leader.mesos --add-path yes >> $LOG
  ~/dcos/bin/dcos config prepend package.sources https://github.com/mesosphere/multiverse/archive/version-1.x.zip >> $LOG
  ~/dcos/bin/dcos package update >> $LOG
fi
DCOS=~/dcos/bin/dcos
echo done

echo -n Determining master storage account name...
STORAGE_ACCOUNT_NAME=$(grep com\.netflix\.exhibitor\.azure\.account-name /opt/mesosphere/etc/exhibitor.properties | cut -d = -f 2-)
if [ ! -n "$STORAGE_ACCOUNT_NAME" ]; then
  echo not found
  exit 1
fi
echo done

echo -n Determining master storage account key...
STORAGE_ACCOUNT_KEY=$(grep com\.netflix\.exhibitor\.azure\.account-key /opt/mesosphere/etc/exhibitor.properties | cut -d = -f 2-)
if [ ! -n "$STORAGE_ACCOUNT_KEY" ]; then
  echo not found
  exit 1
fi
echo done

echo -n Preparing all nodes for private Docker registry
for node in $ALL_NODES; do
  echo -n .
  ssh -A $node '/bin/bash -s' << "  EOS"
    DOCKER_CONF=/etc/systemd/system/docker.service.d/execstart.conf
    DOCKER_OPT=--insecure-registry=registry.marathon.mesos:5000
    if [ ! -n "$(grep -e $DOCKER_OPT $DOCKER_CONF)" ]; then
      sudo sed -i.orig "s/^ExecStart=\/.*/& $DOCKER_OPT/" $DOCKER_CONF
    fi
    sudo systemctl daemon-reload
    sudo systemctl restart docker.service
  EOS
done
echo done

echo -n Deploying private Docker registry...
cat << EOF > ~/privateregistry/registry.json
{
    "id": "registry",
    "cpus": 1,
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
    "healthChecks": [
        {
            "port": 5000,
            "path": "/",
            "intervalSeconds": 5
        }
    ]
}
EOF
if [ -n "$($DCOS marathon app list | grep '^/registry')" ]; then
  $DCOS marathon app remove --force registry
  sleep 5
fi
$DCOS marathon app add ~/privateregistry/registry.json
echo done

echo -n Waiting for private Docker registry
DCOS_RESULT=0
while [ $DCOS_RESULT -eq 0 ]; do
  echo -n .
  DCOS_RESULT=$($DCOS marathon app show registry | jq ".tasksHealthy")
  sleep 1
done
APP_HOST=$($DCOS marathon app show registry | jq -r ".tasks[].host" | sort)
DIG_RESULT=""
while [ "$DIG_RESULT" != "$APP_HOST" ]; do
  echo -n .
  DIG_RESULT=$(dig +short registry.marathon.slave.mesos | sort)
  sleep 1
done
echo done

echo ACS cluster registry initialization completed!