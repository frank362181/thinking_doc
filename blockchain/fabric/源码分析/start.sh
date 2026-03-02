#!/bin/bash

echo "start docker-peer..."

echo "using CLUSTER $CLUSTER"
ORG=${CLUSTER#*.}
PEERN=$(expr $CLUSTER : peer[0-9]*)
PEERN=${CLUSTER:0:$PEERN}
echo "using PEERN $PEERN"
N=${PEERN#*peer}
DOMAIN_SUFFIX="td-hz.blockchain"

REMOTE_ENDPOINT=$CLUSTER.fabric.$DOMAIN_SUFFIX:7051
NETWORK=default

PRODUCTION_PATH="/var/hyperledger/$CLUSTER"
export CORE_PEER_FILESYSTEMPATH="$PRODUCTION_PATH/data"
if [ ! -d $CORE_PEER_FILESYSTEMPATH ]; then
	mkdir -p $CORE_PEER_FILESYSTEMPATH
fi

CONFIG_PATH="$PRODUCTION_PATH/config"
if [ ! -d $CONFIG_PATH ]; then
	mkdir -p $CONFIG_PATH
fi

cat > ~/.ssh/config <<EOF
Host *
    StrictHostKeyChecking no
EOF
chmod 400 ~/.ssh/config
chmod 400 ~/.ssh/id_rsa

rsync -avuP cfgreader@$CONFIG_SERVER:/var/hyperledger/fabric/crypto-config/peerOrganizations/$ORG/peers/$CLUSTER $CONFIG_PATH

export FABRIC_LOGGING_SPEC=${LOG_LEVEL:-debug}

export CORE_PEER_ID=$ORG
export CORE_PEER_LOCALMSPID=$ORG
export CORE_PEER_ADDRESS="0.0.0.0:7051"
export CORE_PEER_LISTEN_ADDRESS="0.0.0.0:7051"
export CORE_PEER_TLS_ENABLED=true

export CORE_CHAINCODE_LOGGING_LEVEL=debug

if [[ $PEERN == "peer0" ]]; then
	export CORE_PEER_GOSSIP_BOOTSTRAP="peer1.$ORG.fabric.$DOMAIN_SUFFIX:7051"
else
	export CORE_PEER_GOSSIP_BOOTSTRAP="peer0.$ORG.fabric.$DOMAIN_SUFFIX:7051"
fi
export CORE_PEER_GOSSIP_USELEADERELECTION=true
export CORE_PEER_GOSSIP_ORGLEADER=false
export CORE_PEER_GOSSIP_ENDPOINT=$REMOTE_ENDPOINT
export CORE_PEER_GOSSIP_EXTERNALENDPOINT=$REMOTE_ENDPOINT

export CORE_PEER_PROFILE_ENABLED=${PPROF:-false}
export CORE_PEER_PROFILE_LISTEN_ADDRESS="0.0.0.0:6060"
export CORE_PEER_NETWORKID=$NETWORK
export CORE_PEER_MSPCONFIGPATH="$CONFIG_PATH/$CLUSTER/msp"
export CORE_PEER_TLS_CERT_FILE="$CONFIG_PATH/$CLUSTER/tls/server.crt"
export CORE_PEER_TLS_KEY_FILE="$CONFIG_PATH/$CLUSTER/tls/server.key"
export CORE_PEER_TLS_ROOTCERT_FILE="$CONFIG_PATH/$CLUSTER/tls/ca.crt"


if [[ $ENV == "production" ]]; then
	export CORE_CHAINCODE_BUILDER="registry.hz.td/blockchain/hyperledger/fabric-ccenv:latest"
	export CORE_CHAINCODE_GOLANG_RUNTIME="registry.hz.td/blockchain/hyperledger/fabric-baseos:amd64-0.4.15"
    export CORE_CHAINCODE_CAR_RUNTIME="registry.hz.td/blockchain/hyperledger/fabric-baseos:amd64-0.4.15"
    export CORE_CHAINCODE_JAVA_RUNTIME="registry.hz.td/blockchain/hyperledger/fabric-javaenv:amd64-1.4.1"
    export CORE_CHAINCODE_NODE_RUNTIME="registry.hz.td/blockchain/hyperledger/fabric-baseimage:amd64-0.4.15"
else
	export CORE_CHAINCODE_BUILDER="registry.tongdun.me/blockchain/hyperledger/fabric-ccenv:latest"
	export CORE_CHAINCODE_GOLANG_RUNTIME="registry.tongdun.me/blockchain/hyperledger/fabric-baseos:amd64-0.4.15"
    export CORE_CHAINCODE_CAR_RUNTIME="registry.tongdun.me/blockchain/hyperledger/fabric-baseos:amd64-0.4.15"
    export CORE_CHAINCODE_JAVA_RUNTIME="registry.tongdun.me/blockchain/hyperledger/fabric-javaenv:amd64-1.4.1"
    export CORE_CHAINCODE_NODE_RUNTIME="registry.tongdun.me/blockchain/hyperledger/fabric-baseimage:amd64-0.4.15"
fi

export CORE_LEDGER_STATE_STATEDATABASE="CouchDB"
export CORE_LEDGER_STATE_COUCHDBCONFIG_USERNAME=""
export CORE_LEDGER_STATE_COUCHDBCONFIG_PASSWORD=""
export CORE_LEDGER_STATE_COUCHDBCONFIG_COUCHDBADDRESS="localhost:5984"
export CORE_LEDGER_STATE_COUCHDBCONFIG_REQUESTTIMEOUT="100s"
# 根据业务需要改，值越大上传效率越高，查询效率可能越低
export CORE_LEDGER_STATE_COUCHDBCONFIG_WARMINDEXESAFTERNBLOCKS=1

export CORE_OPERATIONS_LISTENADDRESS="0.0.0.0:9443"
export CORE_METRICS_PROVIDER="prometheus"

export CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
export CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=${CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE:-bridge}
export GODEBUG="netdns=go+1"

echo "#### ENV ####"
env

# start peer server
exec "$@"