#!/bin/bash
# End-to-end test for every service in the datalake stack.
#
# This is the gate in front of publishing images. Any change to a file under
# docker_build/ - a Dockerfile, a conf/, the build script - gets rebuilt, started and
# run through this before `docker push`, because "the container is Up" and "the service
# works" are different claims and only the second one matters to someone following a
# blog post.
#
#   ./demos/e2e_test.sh                  # core profile, every check
#   PROFILE=all ./demos/e2e_test.sh      # also Trino, Flink, Jupyter, XTable
#   ./demos/e2e_test.sh kafka spark      # only checks whose name starts with these
#   SKIP_FORMATS=1 ./demos/e2e_test.sh   # skip the slow Spark table writes
#
# Exit status is 0 only if nothing failed, so it can be used directly in CI or in a
# pre-push hook. Every check is a real operation - produce and consume a message, write
# and read back a table, run a query - not a port probe, except where a port probe is
# genuinely all a component offers.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
PROFILE="${PROFILE:-core}"
IMAGE_VERSION="${IMAGE_VERSION:-1.0.0}"
SUFFIX="${SUFFIX:-e2e}"
FILTERS=("$@")

PASS=0 FAIL=0 SKIP=0
FAILED_NAMES=()

# ---------------------------------------------------------------- output helpers
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G= R= Y= B= N=; fi

section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
pass() { printf '  %sPASS%s  %-34s %s\n' "$G" "$N" "$1" "${2:-}"; PASS=$((PASS + 1)); }
fail() { printf '  %sFAIL%s  %-34s %s\n' "$R" "$N" "$1" "${2:-}"; FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }
skip() { printf '  %sSKIP%s  %-34s %s\n' "$Y" "$N" "$1" "${2:-}"; SKIP=$((SKIP + 1)); }

# A check runs only if it matches one of the command-line filters (prefix match), or
# if no filter was given.
selected() {
	[ ${#FILTERS[@]} -eq 0 ] && return 0
	for f in "${FILTERS[@]}"; do case "$1" in "$f"*) return 0 ;; esac; done
	return 1
}

# check <name> <expected-substring> <command...>
#
# Runs the command, and passes when its output contains the expected substring. An
# empty expectation means "any output, exit 0". Output is captured either way and
# printed on failure, because a failing e2e check with no evidence is not actionable.
check() {
	local name="$1" expect="$2"
	shift 2
	selected "$name" || return 0
	local out rc
	out="$("$@" 2>&1)"
	rc=$?
	if [ $rc -ne 0 ] && [ -z "$expect" ]; then
		fail "$name" "exit $rc"
		printf '        %s\n' "$(echo "$out" | tail -4 | tr '\n' '\n')"
		return
	fi
	if [ -n "$expect" ] && [[ "$out" != *"$expect"* ]]; then
		fail "$name" "expected [$expect]"
		printf '        %s\n' "$(echo "$out" | tail -4)"
		return
	fi
	pass "$name" "${out:0:60}"
}

# Most checks run inside a container, so the service is reached by its compose DNS name
# rather than through a published port. That is on purpose: a published port can work
# while service-to-service traffic does not.
dex() { docker exec "$@"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- container state
CORE_SERVICES="zookeeper kafka kafka-schema-registry kafka-rest kafka-connect kafka-cat kafka-ui hive-metastore hive-server spark-master spark-worker postgres minio mc"
ALL_EXTRA="trino jupyter-notebook mysql"

SERVICES="$CORE_SERVICES"
[ "$PROFILE" = "all" ] && SERVICES="$CORE_SERVICES $ALL_EXTRA"

section "containers ($PROFILE profile)"
for svc in $SERVICES; do
	selected "container:$svc" || continue
	if ! running "$svc"; then
		fail "container:$svc" "not running"
		continue
	fi
	# A container in start_period has not failed, it just has not answered yet, and
	# the stack is usually only seconds old when this runs. Wait it out rather than
	# racing it; kafka-connect alone asks for 300s.
	h="$(health "$svc")"
	waited=0
	while [ "$h" = "starting" ] && [ "$waited" -lt 420 ]; do
		sleep 10
		waited=$((waited + 10))
		h="$(health "$svc")"
	done
	case "$h" in
	healthy | none) pass "container:$svc" "$h${waited:+ (after ${waited}s)}" ;;
	starting) fail "container:$svc" "still starting after ${waited}s" ;;
	*) fail "container:$svc" "$h" ;;
	esac
done


# ---------------------------------------------------------------- image ownership
# The stack must not pull any third-party image directly. Every image it starts is one
# this repo builds, so an upstream retag or retirement cannot change what runs here.
section "image ownership"
if selected "images:no-upstream"; then
	compose_file="$REPO_DIR/docker_run/docker-compose.yml"
	[ "$PROFILE" = "all" ] && compose_file="$REPO_DIR/docker_run/docker-compose_all.yml"
	foreign="$(grep -E '^\s+image:' "$compose_file" | grep -vc 'rangareddy1988/')"
	if [ "$foreign" = "0" ]; then
		pass "images:no-upstream" "every image is rangareddy1988/*"
	else
		fail "images:no-upstream" "$foreign image(s) still point upstream"
		grep -E '^\s+image:' "$compose_file" | grep -v 'rangareddy1988/'
	fi
fi
if selected "images:running"; then
	# Scoped to this compose project by label. Looking at every running container
	# meant an unrelated one on the same daemon - a ruby:2.7 from another repo -
	# failed a check that is about what *this* stack runs.
	ids="$(docker ps -q --filter "label=com.docker.compose.project=docker_run")"
	if [ -z "$ids" ]; then
		fail "images:running" "no containers from this compose project are running"
	else
		# shellcheck disable=SC2086
		foreign="$(docker inspect $ids --format '{{.Config.Image}}' 2>/dev/null | grep -v '^rangareddy1988/' | sort -u)"
		if [ -z "$foreign" ]; then pass "images:running" "no upstream image is running"; else fail "images:running" "$(echo "$foreign" | tr '\n' ' ')"; fi
	fi
fi

# ---------------------------------------------------------------- object store
section "minio"
check "minio:health" "" \
	dex minio curl -fsS http://localhost:9000/minio/health/live
check "minio:buckets" "warehouse" \
	dex mc mc ls minio
check "minio:write-read" "hello-datalake" \
	dex mc sh -c "echo hello-datalake > /tmp/e2e.txt && mc cp /tmp/e2e.txt minio/datalake/e2e.txt >/dev/null && mc cat minio/datalake/e2e.txt"

# ---------------------------------------------------------------- databases
section "postgres"
check "postgres:query" "1 row" \
	dex postgres psql -U postgres -c "SELECT 1"
check "postgres:seed-data" "employees" \
	dex postgres psql -U postgres -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public'"
# Debezium cannot decode row changes without this; the server default is "replica".
check "postgres:wal-level-logical" "logical" \
	dex postgres psql -U postgres -tAc "SHOW wal_level"

# ---------------------------------------------------------------- kafka
section "kafka"
check "kafka:zookeeper-ruok" "imok" \
	dex zookeeper sh -c "echo ruok | nc localhost 2181"
check "kafka:broker-api" "$SUFFIX" \
	dex kafka sh -c "kafka-topics --bootstrap-server kafka:29092 --create --if-not-exists --topic e2e-$SUFFIX --partitions 1 --replication-factor 1 >/dev/null 2>&1; kafka-topics --bootstrap-server kafka:29092 --list | grep e2e-$SUFFIX"
# A real round trip: produce one record, then consume it back from the beginning.
check "kafka:produce-consume" "e2e-message" \
	dex kafka sh -c "echo e2e-message | kafka-console-producer --bootstrap-server kafka:29092 --topic e2e-$SUFFIX >/dev/null 2>&1; kafka-console-consumer --bootstrap-server kafka:29092 --topic e2e-$SUFFIX --from-beginning --max-messages 1 --timeout-ms 20000 2>/dev/null"
check "kafka:kcat-metadata" "broker" \
	dex kafka-cat kafkacat -b kafka:29092 -L

section "schema registry"
check "schema-registry:subjects" "" \
	dex kafka-schema-registry curl -fsS http://localhost:8081/subjects
check "schema-registry:register" "id" \
	dex kafka-schema-registry curl -fsS -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
	--data '{"schema":"{\"type\":\"record\",\"name\":\"E2E\",\"fields\":[{\"name\":\"id\",\"type\":\"int\"}]}"}' \
	"http://localhost:8081/subjects/e2e-value/versions"

section "kafka rest proxy"
check "kafka-rest:topics" "e2e-$SUFFIX" \
	dex kafka-rest curl -fsS http://localhost:8082/topics

section "kafka connect"
check "kafka-connect:rest" "version" \
	dex kafka-connect curl -fsS http://localhost:8083/
# The plugin list is what actually proves the image built correctly: a connector that
# failed to install is invisible until someone tries to create it.
check "kafka-connect:debezium-plugin" "PostgresConnector" \
	dex kafka-connect curl -fsS http://localhost:8083/connector-plugins
check "kafka-connect:s3-plugin" "S3SinkConnector" \
	dex kafka-connect curl -fsS http://localhost:8083/connector-plugins
check "kafka-connect:jdbc-plugin" "JdbcSinkConnector" \
	dex kafka-connect curl -fsS http://localhost:8083/connector-plugins

# Full CDC round trip: create a Debezium connector against Postgres, insert a row, and
# read it back off the topic Debezium writes to. This is the one check that proves
# Connect, Postgres logical decoding, Schema Registry and Kafka all work together.
if selected "kafka-connect:cdc"; then
	name="e2e-pg-$SUFFIX"
	topic_prefix="e2e${SUFFIX}"
	dex kafka-connect curl -fsS -X DELETE "http://localhost:8083/connectors/$name" >/dev/null 2>&1
	cfg='{"name":"'"$name"'","config":{
    "connector.class":"io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname":"postgres","database.port":"5432",
    "database.user":"postgres","database.password":"postgres","database.dbname":"postgres",
    "topic.prefix":"'"$topic_prefix"'","table.include.list":"public.employees",
    "plugin.name":"pgoutput","slot.name":"e2e_'"$SUFFIX"'",
    "key.converter":"org.apache.kafka.connect.json.JsonConverter",
    "value.converter":"org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable":"false","value.converter.schemas.enable":"false"}}'
	created="$(dex kafka-connect curl -sS -X POST -H "Content-Type: application/json" --data "$cfg" http://localhost:8083/connectors 2>&1)"
	if [[ "$created" != *"$name"* ]]; then
		fail "kafka-connect:cdc" "connector not created"
		printf '        %s\n' "${created:0:200}"
	else
		# Debezium snapshots the table on start, so the existing rows arrive without
		# any insert. Poll rather than sleep a fixed time: the snapshot is quick on an
		# idle machine and slow when the whole stack just started.
		got=""
		for _ in $(seq 1 20); do
			got="$(dex kafka kafka-console-consumer --bootstrap-server kafka:29092 \
				--topic "${topic_prefix}.public.employees" --from-beginning --max-messages 1 \
				--timeout-ms 5000 2>/dev/null)"
			[ -n "$got" ] && break
		done
		if [ -n "$got" ]; then pass "kafka-connect:cdc" "snapshot row on ${topic_prefix}.public.employees"; else fail "kafka-connect:cdc" "no CDC record within ~100s"; fi
		dex kafka-connect curl -fsS -X DELETE "http://localhost:8083/connectors/$name" >/dev/null 2>&1
		dex postgres psql -U postgres -tAc "SELECT pg_drop_replication_slot('e2e_$SUFFIX')" >/dev/null 2>&1
	fi
fi

section "kafka ui"
check "kafka-ui:health" "UP" \
	dex kafka-ui wget -qO- http://localhost:8080/actuator/health
# Proves the UI reached the broker, not just that Spring started.
check "kafka-ui:cluster" "local" \
	dex kafka-ui wget -qO- http://localhost:8080/api/clusters

# ---------------------------------------------------------------- hive
section "hive"
check "hive:metastore-port" "" \
	dex hive-metastore bash -c "exec 6<>/dev/tcp/localhost/9083"
check "hive:server-query" "e2e_ok" \
	dex hive-server beeline -u "jdbc:hive2://localhost:10000/" -n hive --silent=true --outputformat=csv2 -e "SELECT 'e2e_ok'"
check "hive:metastore-catalog" "" \
	dex hive-server beeline -u "jdbc:hive2://localhost:10000/" -n hive --silent=true --outputformat=csv2 -e "SHOW DATABASES"

# ---------------------------------------------------------------- spark
section "spark"
check "spark:master-ui" "Spark Master" \
	dex spark-master curl -fsS http://localhost:8080/
# The worker count, not the string ALIVE: the master reports its own state as ALIVE too,
# so grepping for that would pass with no worker attached at all.
check "spark:worker-registered" '"aliveworkers":1' \
	dex spark-master sh -c "curl -fsS http://localhost:8080/json/ | tr -d ' '"
check "spark:worker-ui" "Spark Worker" \
	dex spark-worker curl -fsS http://localhost:8081/
# Submitted to the cluster rather than local[*], so a broken master/worker link fails
# here. bash -c because $SPARK_HOME and the jar glob have to expand inside the container.
check "spark:submit-job" "Pi is roughly" \
	dex spark-master bash -c 'spark-submit --master spark://spark-master:7077 \
	--class org.apache.spark.examples.SparkPi \
	$SPARK_HOME/examples/jars/spark-examples_*.jar 10'
check "spark:s3a-write" "e2e-s3a" \
	dex spark-master spark-sql --master "local[2]" -e \
	"CREATE DATABASE IF NOT EXISTS e2e LOCATION 's3a://warehouse/e2e'; DROP TABLE IF EXISTS e2e.plain_$SUFFIX; CREATE TABLE e2e.plain_$SUFFIX (v STRING) USING parquet; INSERT INTO e2e.plain_$SUFFIX VALUES ('e2e-s3a'); SELECT v FROM e2e.plain_$SUFFIX;"

# ---------------------------------------------------------------- table formats
# The slow part: a write, an update and a read back for each format this Spark line
# ships. Formats absent from the image (Spark 4.1 carries Iceberg only) are skipped by
# smoke_test_formats.sh itself, not failed.
section "table formats"
if [ "${SKIP_FORMATS:-0}" = "1" ]; then
	skip "formats:hudi-iceberg-delta" "SKIP_FORMATS=1"
elif selected "formats"; then
	out="$(dex spark-master bash /opt/demos/smoke_test_formats.sh 2>&1)"
	echo "$out" | sed -n '/^== /,$p' | sed 's/^/    /'
	f="$(echo "$out" | grep -c '  FAIL')"
	p="$(echo "$out" | grep -c '  PASS')"
	if [ "$f" = "0" ] && [ "$p" != "0" ]; then
		pass "formats:hudi-iceberg-delta" "$p table checks"
	elif [ "$p" = "0" ]; then
		# Distinguish "the formats are broken" from "the script never ran", which is
		# what a stopped spark-master looks like if only FAIL lines are counted.
		fail "formats:hudi-iceberg-delta" "smoke test produced no results at all"
	else
		fail "formats:hudi-iceberg-delta" "$f of $((f + p)) table checks failed"
	fi
fi


# ---------------------------------------------------------------- all profile
if [ "$PROFILE" = "all" ]; then
	section "trino"
	check "trino:catalogs" "iceberg" \
		dex trino trino --execute "SHOW CATALOGS"
	# A literal that cannot appear in a Trino error message or query id. "1" did:
	# the failure text "Query 20260926_063400_00001_t6teq failed" contains it, so a
	# refused query passed.
	check "trino:query" "trino-e2e-ok" \
		dex trino trino --execute "SELECT 'trino-e2e-ok'"
	check "trino:hive-schemas" "" \
		dex trino trino --execute "SHOW SCHEMAS FROM hive"

	section "jupyter"
	check "jupyter:api" "version" \
		dex jupyter-notebook curl -fsS http://localhost:8888/api
	check "jupyter:kernels" "spylon" \
		dex jupyter-notebook jupyter kernelspec list
	# It runs from the Spark image now, so Spark has to be there to be worth running.
	check "jupyter:has-spark" "version " \
		dex jupyter-notebook bash -lc "spark-submit --version 2>&1 | grep -o 'version [0-9.]*' | head -1"

	section "mysql"
	check "mysql:query" "mysql-e2e-ok" \
		dex mysql mysql -uroot -ppassword -N -e "SELECT 'mysql-e2e-ok'"
fi

# ---------------------------------------------------------------- summary
printf '\n%s== summary%s\n' "$B" "$N"
printf '  %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -ne 0 ]; then
	printf '  failing: %s\n' "${FAILED_NAMES[*]}"
	printf '\n  Do not push images while this is red.\n'
	exit 1
fi

# Record which images this green run actually exercised. publish-to-dockerhub.sh reads
# this and refuses to push an image whose ID is not listed, so "rebuilt the Dockerfile
# and pushed without retesting" stops being a thing that can happen by accident.
ATTEST="$REPO_DIR/.e2e-passed"
{
	echo "# Written by demos/e2e_test.sh on a fully green run. Do not edit by hand."
	echo "# date=$(date -u +%Y-%m-%dT%H:%M:%SZ) profile=$PROFILE checks=$PASS version=$IMAGE_VERSION"
	docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E "/ranga-[a-z0-9-]+:($IMAGE_VERSION|latest) " | sort
} >"$ATTEST"

printf '\n  Stack is end-to-end green; images are safe to publish.\n'
printf '  Recorded %d image IDs in %s\n' "$(grep -c '/ranga-' "$ATTEST")" "${ATTEST#"$REPO_DIR/"}"
