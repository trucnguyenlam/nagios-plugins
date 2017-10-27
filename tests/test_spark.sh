#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-02-10 23:18:47 +0000 (Wed, 10 Feb 2016)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x

srcdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$srcdir/.."

. "$srcdir/utils.sh"

section "S p a r k"

export SPARK_VERSIONS="${@:-${SPARK_VERSIONS:-latest 1.3 1.4 1.5 1.6}}"

SPARK_HOST="${DOCKER_HOST:-${SPARK_HOST:-${HOST:-localhost}}}"
SPARK_HOST="${SPARK_HOST##*/}"
SPARK_HOST="${SPARK_HOST%%:*}"
export SPARK_HOST
export SPARK_MASTER_PORT_DEFAULT=8080
export SPARK_WORKER_PORT_DEFAULT=8081

export DOCKER_IMAGE="harisekhon/spark"
export DOCKER_CONTAINER="nagios-plugins-spark-test"

startupwait 15

check_docker_available

trap_debug_env spark

test_spark(){
    local version="$1"
    section2 "Setting up Spark $version test container"
    docker-compose down &>/dev/null
    if is_CI; then
        VERSION="$version" docker-compose pull $docker_compose_quiet
    fi
    VERSION="$version" docker-compose up -d
    echo "getting Spark dynamic port mappings:"
    printf "Spark Master Port => "
    export SPARK_MASTER_PORT="`docker-compose port "$DOCKER_SERVICE" "$SPARK_MASTER_PORT_DEFAULT" | sed 's/.*://'`"
    echo "$SPARK_MASTER_PORT"
    printf "Spark Worker Port => "
    export SPARK_WORKER_PORT="`docker-compose port "$DOCKER_SERVICE" "$SPARK_WORKER_PORT_DEFAULT" | sed 's/.*://'`"
    echo "$SPARK_WORKER_PORT"
    hr
    when_ports_available "$SPARK_HOST" "$SPARK_MASTER_PORT" "$SPARK_WORKER_PORT"
    hr
    when_url_content "http://$SPARK_HOST:$SPARK_MASTER_PORT" "Spark Master"
    hr
    when_url_content "http://$SPARK_HOST:$SPARK_WORKER_PORT" "Spark Worker"
    hr
    if [ -n "${NOTESTS:-}" ]; then
        exit 0
    fi
    if [ "$version" = "latest" ]; then
        echo "latest version, fetching latest version from DockerHub master branch"
        local version="$(dockerhub_latest_version spark)"
        echo "expecting version '$version'"
    fi
    hr
    run ./check_spark_master_version.py -e "$version"
    hr
    run_fail 2 ./check_spark_master_version.py -e "fail-version"
    hr
    run_conn_refused ./check_spark_master_version.py -e "$version"
    hr
    run ./check_spark_worker_version.py -e "$version"
    hr
    run_fail 2 ./check_spark_worker_version.py -e "fail-version"
    hr
    run_conn_refused ./check_spark_worker_version.py -e "$version"
    hr
    echo "trying check_spark_cluster.pl up to 10 times to give cluster worker a chance to initialize:"
    retry 10 ./check_spark_cluster.pl -c 1: -v
    hr
    run $perl -T ./check_spark_cluster.pl -c 1: -v
    hr
    run_conn_refused $perl -T ./check_spark_cluster.pl -c 1: -v
    hr
    run $perl -T ./check_spark_cluster_dead_workers.pl -w 0 -c 1 -v
    hr
    run_conn_refused $perl -T ./check_spark_cluster_dead_workers.pl -w 1 -c 1 -v
    hr
    run $perl -T ./check_spark_cluster_memory.pl -w 80 -c 90 -v
    hr
    run_conn_refused $perl -T ./check_spark_cluster_memory.pl -w 80 -c 90 -v
    hr
    run $perl -T ./check_spark_worker.pl -w 80 -c 90 -v
    hr
    run_conn_refused $perl -T ./check_spark_worker.pl -w 80 -c 90 -v
    hr
    echo "Now killing Spark Worker to check for worker failure detection:"
    docker exec "$DOCKER_CONTAINER" pkill -f org.apache.spark.deploy.worker.Worker
    hr
    echo "Now waiting for 10 secs for Spark Worker failure to be detected:"
    retry 10 ! $perl -T ./check_spark_cluster_dead_workers.pl
    hr
    echo "Completed $run_count Spark tests"
    hr
    [ -n "${KEEPDOCKER:-}" ] ||
    docker-compose down
    hr
    echo
}

run_test_versions Spark
