#!/usr/bin/env bash
set -em
# requires: lsof, awk, sed, grep, pgrep, docker

export GO111MODULE=on
export GOFLAGS="-mod=vendor"

# Changeable environment variables (parameters)
INSOLAR_ARTIFACTS_DIR=${INSOLAR_ARTIFACTS_DIR:-".artifacts"}/
LAUNCHNET_BASE_DIR=${LAUNCHNET_BASE_DIR:-"${INSOLAR_ARTIFACTS_DIR}launchnet"}/

INSOLAR_LOG_FORMATTER=${INSOLAR_LOG_FORMATTER:-""}
INSOLAR_LOG_LEVEL=${INSOLAR_LOG_LEVEL:-"debug"}
GORUND_LOG_LEVEL=${GORUND_LOG_LEVEL:-${INSOLAR_LOG_LEVEL}}
# we can skip build binaries (by default in CI environment they skips)
SKIP_BUILD=${SKIP_BUILD:-${CI_ENV}}
BUILD_TAGS=${BUILD_TAGS:-'-tags "debug functest"'}

# predefined/dependent environment variables

LAUNCHNET_LOGS_DIR=${LAUNCHNET_BASE_DIR}logs/
DISCOVERY_NODE_LOGS=${LAUNCHNET_LOGS_DIR}discoverynodes/

BIN_DIR=bin
INSOLAR_CLI=${BIN_DIR}/insolar
INSOLARD=$BIN_DIR/insolard
KEEPERD=keeperd
PULSARD=pulsard
PULSEWATCHER=pulsewatcher

# DUMP_METRICS_ENABLE enables metrics dump to logs dir after every functest
DUMP_METRICS_ENABLE=${DUMP_METRICS_ENABLE:-"1"}

PULSAR_DATA_DIR=${LAUNCHNET_BASE_DIR}pulsar_data
PULSAR_CONFIG=${LAUNCHNET_BASE_DIR}pulsar.yaml

SCRIPTS_DIR=scripts/insolard/

CONFIGS_DIR=${LAUNCHNET_BASE_DIR}configs/

PULSAR_KEYS=${CONFIGS_DIR}pulsar_keys.json
HEAVY_GENESIS_CONFIG_FILE=${CONFIGS_DIR}heavy_genesis.json
CONTRACTS_PLUGINS_DIR=${LAUNCHNET_BASE_DIR}contracts

DISCOVERY_NODES_DATA=${LAUNCHNET_BASE_DIR}discoverynodes/

DISCOVERY_NODES_HEAVY_DATA=${DISCOVERY_NODES_DATA}1/

BOOTSTRAP_TEMPLATE=${SCRIPTS_DIR}bootstrap_template.yaml
BOOTSTRAP_CONFIG=${LAUNCHNET_BASE_DIR}bootstrap.yaml
BOOTSTRAP_INSOLARD_CONFIG=${LAUNCHNET_BASE_DIR}insolard.yaml

KEEPERD_CONFIG=${LAUNCHNET_BASE_DIR}keeperd.yaml
KEEPERD_LOG=${LAUNCHNET_LOGS_DIR}keeperd.log

PULSEWATCHER_CONFIG=${LAUNCHNET_BASE_DIR}pulsewatcher.yaml

set -x
export INSOLAR_LOG_FORMATTER=${INSOLAR_LOG_FORMATTER}
export INSOLAR_LOG_LEVEL=${INSOLAR_LOG_LEVEL}
{ set +x; } 2>/dev/null

NUM_DISCOVERY_NODES=$(sed '/^nodes:/ q' $BOOTSTRAP_TEMPLATE | grep "host:" | grep -v "#" | wc -l | tr -d '[:space:]')
NUM_NODES=$(sed -n '/^nodes:/,$p' $BOOTSTRAP_TEMPLATE | grep "host:" | grep -v "#" | wc -l | tr -d '[:space:]')
echo "discovery+other nodes: ${NUM_DISCOVERY_NODES}+${NUM_NODES}"

for i in `seq 1 $NUM_DISCOVERY_NODES`
do
    DISCOVERY_NODE_DIRS+=(${DISCOVERY_NODES_DATA}${i})
done

# LOGROTATOR_ENABLE enables log rotation before every functest start
LOGROTATOR_ENABLE=${LOGROTATOR_ENABLE:-""}
LOGROTATOR=tee
if [[ "$LOGROTATOR_ENABLE" == "1" ]]; then
  LOGROTATOR=inslogrotator
fi

build_logger()
{
    echo "build logger binaries"
    GO111MODULE=off go get github.com/insolar/insolar/scripts/inslogrotator
}

kill_port()
{
    port=$1
    pids=$(lsof -i :$port 2>/dev/null | grep "LISTEN\|UDP" | awk '{print $2}')
    for pid in $pids
    do
        echo -n "killing pid $pid at "
        date
        kill $pid || true
    done
}

kill_all()
{
  echo "kill all processes: insolard, pulsard"
  set +e
  killall insolard
  killall pulsard
  set -e
}

stop_listening()
{
    echo "stop_listening(): starts ..."
    ports="$ports 58090" # Pulsar

    transport_ports=$( grep "host:" ${BOOTSTRAP_CONFIG} | grep -o ":\d\+" | grep -o "\d\+" | tr '\n' ' ' )
    keeperd_port=$( grep "listenaddress:" ${KEEPERD_CONFIG} | grep -o ":\d\+" | grep -o "\d\+" | tr '\n' ' ' )
    ports="$ports $transport_ports $keeperd_port"

    for port in $ports
    do
        echo "killing process using port '$port'"
        kill_port $port
    done

    echo "stop_listening() end."
}

stop_all()
{
  stop_listening true
  kill_all
}

clear_dirs()
{
    echo "clear_dirs() starts ..."
    set -x
    rm -rfv ${CONFIGS_DIR}
    rm -rfv ${DISCOVERY_NODES_DATA}
    rm -rfv ${LAUNCHNET_LOGS_DIR}
    rm -rfv ${CONTRACTS_PLUGINS_DIR}
    { set +x; } 2>/dev/null

    for i in `seq 1 $NUM_DISCOVERY_NODES`
    do
        set -x
        rm -rfv ${DISCOVERY_NODE_LOGS}${i}
        { set +x; } 2>/dev/null
    done
}

create_required_dirs()
{
    echo "create_required_dirs() starts ..."
    set -x
    mkdir -p ${DISCOVERY_NODES_DATA}certs
    mkdir -p ${CONFIGS_DIR}

    for i in `seq 1 $NUM_DISCOVERY_NODES`
    do
        set -x
        mkdir -p ${DISCOVERY_NODE_LOGS}${i}
        { set +x; } 2>/dev/null
    done

    echo "create_required_dirs() end."
}

generate_insolard_configs()
{
    echo "generate configs"
    set -x
    go run insolar-scripts/generate_insolar_configs.go
    { set +x; } 2>/dev/null
}

prepare()
{
    echo "prepare() starts ..."
    clear_dirs
    create_required_dirs
    echo "prepare() end."
}

build_binaries()
{
    echo "build binaries"
    set -x
    export BUILD_TAGS
    make build
    GOFLAGS='' go get github.com/insolar/insolar/cmd/pulsard
    GOFLAGS='' go get github.com/insolar/insolar/cmd/pulsewatcher
    GOFLAGS='' go get github.com/insolar/insolar/cmd/keeperd
    { set +x; } 2>/dev/null
}

rebuild_binaries()
{
    echo "rebuild binaries"
    make clean
    build_binaries
}

generate_pulsar_keys()
{
    echo "generate pulsar keys: ${PULSAR_KEYS}"
    bin/insolar gen-key-pair --target=node > ${PULSAR_KEYS}
}

usage()
{
    echo "usage: $0 [options]"
    echo "possible options: "
    echo -e "\t-h - show help"
    echo -e "\t-g - start launchnet"
    echo -e "\t-b - do bootstrap only and exit, show bootstrap logs"
    echo -e "\t-l - clear all and exit"
    echo -e "\t-C - generate configs only"
    echo -e "\t-w - start without pulse watcher"
}

process_input_params()
{
    # shell does not reset OPTIND automatically;
    # it must be manually reset between multiple calls to getopts
    # within the same shell invocation if a new set of parameters is to be used
    OPTIND=1
    while getopts "h?gblwC" opt; do
        case "$opt" in
        h|\?)
            usage
            exit 0
            ;;
        g)
            GENESIS=1
            bootstrap
            ;;
        b)
            NO_BOOTSTRAP_LOG_REDIRECT=1
            NO_STOP_LISTENING_ON_PREPARE=${NO_STOP_LISTENING_ON_PREPARE:-"1"}
            bootstrap
            exit 0
            ;;
        l)
            prepare
            exit 0
            ;;
        w)
            watch_pulse=false
            ;;
        C)
            generate_insolard_configs
            exit $?
        esac
    done
}

launch_keeperd()
{
    echo "launch_keeperd() starts ..."
    ${KEEPERD} --config=${KEEPERD_CONFIG} \
    &> ${KEEPERD_LOG} &

    echo "launch_keeperd() end."
}

copy_discovery_certs()
{
    echo "copy_certs() starts ..."
    i=0
    for node in "${DISCOVERY_NODE_DIRS[@]}"
    do
        i=$((i + 1))
        set -x
        cp -v ${DISCOVERY_NODES_DATA}certs/discovery_cert_$i.json ${node}/cert.json
        { set +x; } 2>/dev/null
    done
    echo "copy_certs() end."
}

wait_for_complete_network_state()
{
    while true
    do
        num=`insolar-scripts/insolard/check_status.sh 2>/dev/null | grep "CompleteNetworkState" | wc -l`
        echo "$num/$NUM_DISCOVERY_NODES discovery nodes ready"
        if [[ "$num" -eq "$NUM_DISCOVERY_NODES" ]]
        then
            break
        fi
        sleep 5s
    done
}

bootstrap()
{
    echo "bootstrap start"
    prepare
    if [[ "$SKIP_BUILD" != "1" ]]; then
        build_binaries
    else
        echo "SKIP: build binaries (SKIP_BUILD=$SKIP_BUILD)"
    fi
    generate_pulsar_keys
    ./scripts/insolard/generate_initial_data.sh
    generate_insolard_configs

    echo "start bootstrap ..."
    CMD="${INSOLAR_CLI} bootstrap --config=${BOOTSTRAP_CONFIG}"

    GENESIS_EXIT_CODE=0
    set +e
    if [[ "$NO_BOOTSTRAP_LOG_REDIRECT" != "1" ]]; then
        set -x
        ${CMD} &> ${LAUNCHNET_LOGS_DIR}bootstrap.log
        GENESIS_EXIT_CODE=$?
        { set +x; } 2>/dev/null
        echo "bootstrap log: ${LAUNCHNET_LOGS_DIR}bootstrap.log"
    else
        set -x
        ${CMD}
        GENESIS_EXIT_CODE=$?
        { set +x; } 2>/dev/null
    fi
    set -e
    if [[ ${GENESIS_EXIT_CODE} -ne 0 ]]; then
        echo "Genesis failed"
        if [[ "${NO_BOOTSTRAP_LOG_REDIRECT}" != "1" ]]; then
            echo "check log: ${LAUNCHNET_LOGS_DIR}/bootstrap.log"
        fi
        exit ${GENESIS_EXIT_CODE}
    fi
    echo "bootstrap is done"

    copy_discovery_certs
}

watch_pulse=true
process_input_params $@

kill_all
trap 'stop_all' INT TERM EXIT

echo "start pulsar ..."
echo "   log: ${LAUNCHNET_LOGS_DIR}pulsar_output.log"
set -x
mkdir -p ${PULSAR_DATA_DIR}
${PULSARD} -c ${PULSAR_CONFIG} &> ${LAUNCHNET_LOGS_DIR}pulsar_output.log &
{ set +x; } 2>/dev/null
echo "pulsar log: ${LAUNCHNET_LOGS_DIR}pulsar_output.log"

launch_keeperd

if [[ "$LOGROTATOR_ENABLE" == "1" ]]; then
  echo "prepare logger"
  build_logger
fi

HEAVY_DB="badger"
if [[ "$POSTGRES_ENABLE" == "1" ]]; then
  # Terminate running PostgreSQL container if there is one
  docker stop insolar-postgresql || true
  docker rm insolar-postgresql || true
  # Build PostgreSQL Docker image with custom postgresql.conf
  OLD_PWD=`pwd`
  echo "pwd: $OLD_PWD"
  cd insolar-scripts/insolard/postgresql-docker
  docker build --no-cache -t insolar-functests-postgresql .
  cd $OLD_PWD
  # Start a new PostgreSQL container
  docker run -d --name insolar-postgresql -e POSTGRES_DB=insolar -e POSTGRES_PASSWORD=s3cr3t -p 5432:5432 insolar-functests-postgresql:latest
  # Make sure PostgreSQL is up
  until bash -c "PGPASSWORD=s3cr3t docker exec -t insolar-postgresql psql -h localhost -U postgres insolar -c 'SELECT 1;'"
  do
    echo "PostgreSQL is not up yet, retrying..."
    sleep 1
  done
  HEAVY_DB="postgres"
fi

handle_sigchld()
{
  jobs -pn
  echo "someone left the network"
}

trap 'handle_sigchld' SIGCHLD

echo "Running genesis before actually starting any nodes (consensus may fail if genesis takes long)"
$INSOLARD heavy \
    --config ${DISCOVERY_NODES_DATA}1/insolard.yaml \
    --heavy-genesis ${HEAVY_GENESIS_CONFIG_FILE} \
    --database=$HEAVY_DB \
    --genesis-only

echo "start heavy node"
set -x
$INSOLARD heavy \
    --config ${DISCOVERY_NODES_DATA}1/insolard.yaml \
    --heavy-genesis ${HEAVY_GENESIS_CONFIG_FILE} \
    --database=$HEAVY_DB \
    2>&1 | ${LOGROTATOR} ${DISCOVERY_NODE_LOGS}1/output.log > /dev/null &
{ set +x; } 2>/dev/null
echo "heavy node started in background"
echo "log: ${DISCOVERY_NODE_LOGS}1/output.log"

echo "start discovery nodes ..."
for i in `seq 2 $NUM_DISCOVERY_NODES`
do
    ROLE=""
    # even - lme, odd - vm
    if [ $((i%2)) -eq 0 ]
    then
      ROLE="virtual"
    else
      ROLE="light"
    fi

    set -x
    $INSOLARD $ROLE \
        --config ${DISCOVERY_NODES_DATA}${i}/insolard.yaml \
        2>&1 | ${LOGROTATOR} ${DISCOVERY_NODE_LOGS}${i}/output.log > /dev/null &
    { set +x; } 2>/dev/null
    echo "discovery node $i started in background"
    echo "log: ${DISCOVERY_NODE_LOGS}${i}/output.log"
done

echo "discovery nodes started ..."

if [[ "$NUM_NODES" -ne "0" ]]
then
    wait_for_complete_network_state
    if [[ "$GENESIS" == "1" ]]; then
        ./insolar-scripts/insolard/start_nodes.sh -g
    else
        ./insolar-scripts/insolard/start_nodes.sh
    fi
fi

if [[ "$watch_pulse" == "true" ]]
then
    echo "starting pulse watcher..."
    echo "${PULSEWATCHER} -c ${PULSEWATCHER_CONFIG}"
    ${PULSEWATCHER} -c ${PULSEWATCHER_CONFIG}
else
    echo "waiting..."
    wait
fi

echo "FINISHING ..."
