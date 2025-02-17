#!/bin/bash
#
# Copyright (c) 2023 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

# Description of the test:
# This test runs the 'fio benchmark' on kata containers
# https://fio.readthedocs.io/en/latest/

set -o pipefail

SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_PATH}/../lib/common.bash"

CONTAINER_ID="fio_bench_${RANDOM}"
IMAGE="docker.io/library/fio-bench:latest"
DOCKERFILE="${SCRIPT_PATH}/fio-dockerfile/Dockerfile"
PAYLOAD_ARGS="${PAYLOAD_ARGS:-tail -f /dev/null}"
TEST_NAME="fio"

# Fio default number of jobs
nj=4

function release_resources() {
	sudo -E "${CTR_EXE}" t exec --exec-id "$(random_name)" ${CONTAINER_ID} sh -c "./fio_bench.sh delete-workload"
	sleep 0.5
	clean_env_ctr
	info "fio test end"
}

trap release_resources EXIT

function setup() {
	info "setup fio test"
	clean_env_ctr
	check_cmds "${cmds[@]}"
	check_ctr_images "$IMAGE" "$DOCKERFILE"
	init_env

	# drop caches
	sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

	# launch container
	sudo -E "${CTR_EXE}" run -d --runtime "${CTR_RUNTIME}" "${IMAGE}" "${CONTAINER_ID}" sh -c "${PAYLOAD_ARGS}"
}

function parse_results() {
	local data="${1}"
	local bw=0
	local bw_stddev=0
	local iops=0
	local iops_stddev=0

	[ -z "${data}" ] && die "Data results are missing when trying to parsing them."

	local io_type="$(echo "${data}" | jq -r '.jobs[0]."job options".rw')"

	if [ "${io_type}" = "read" ] || [ "${io_type}" = "randread" ]; then
		# Bandwidth
		bw="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .read.bw] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
		bw_stddev="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .read.bw_dev] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
		# IOPS
		iops="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .read.iops] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
		iops_stddev="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .read.iops_stddev] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
	elif [ "${io_type}" = "write" ] || [ "${io_type}" = "randwrite" ]; then
		# Bandwidth
		bw="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .write.bw] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
		bw_stddev="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .write.bw_dev] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
		# IOPS
		iops="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .write.iops] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
		iops_stddev="$(echo "${data}" | num_jobs="$nj" jq '[.jobs[] | .write.iops_stddev] | add/(env.num_jobs|tonumber) | .*1000|round/1000')"
	else
		die "io type ${io_type} is not valid when parsing results"
	fi

	convert_results_to_json "${io_type}" "${bw}" "${bw_stddev}" "${iops}" "${iops_stddev}"
}

function extract_test_params() {
	local data="${1}"
	[ -z "${data}" ] && die "Missing fio parameters when trying to convert to json format."

	local json_params="$(echo "${data}" | jq -r '.jobs[0]."job options" | del(.name) | del(.rw) | del(.filename)')"
	local json="$(cat << EOF
        {
		"Parameters" : ${json_params}
	}
EOF
)"
	metrics_json_add_array_element "${json}"
}

function convert_results_to_json() {
	local io_type="${1}"
	local bw="${2}"
	local bw_stddev="${3}"
	local iops="${4}"
	local iops_stddev="${5}"

	[ -z "${io_type}" ] || [ -z "${bw}" ] || [ -z "${bw_stddev}" ] || [ -z "${iops}" ] || [ -z "${iops_stddev}" ] && die "Results are missing when trying to convert to json format."

	local json="$(cat << EOF
	{
	"${io_type}" : {
		"bw" : "${bw}",
		"bw_stddev" : "${bw_stddev}",
		"iops" : "${iops}",
		"iops_stddev" : "${iops_stddev}",
		"units" : "Kb"
		}
	}
EOF
)"
	metrics_json_add_array_element "${json}"
}

function store_results() {
	local data_r="${1}"
	local data_w="${2}"
	local title="${3}"

	[ -z "${data_r}" ] || [ -z "${data_w}" ] || [ -z "${title}" ] && die "Missing data and/or title when trying storing results."

	metrics_json_start_array
	extract_test_params "${data_r}"
	parse_results "${data_r}"
	parse_results "${data_w}"
	metrics_json_end_array "${title}"
}

function main() {
	setup

	# Collect bs=4K, num_jobs=4, io-direct, io-depth=2
	info "Processing sequential type workload"
	sudo -E "${CTR_EXE}" t exec --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh run-read-4k ${nj}" >/dev/null 2>&1
	local results_read_4K="$(sudo -E "${CTR_EXE}" t exec -t --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh print-latest-results")"

	sleep 0.5
	sudo -E "${CTR_EXE}" t exec --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh run-write-4k ${nj}" >/dev/null 2>&1
	local results_write_4K="$(sudo -E "${CTR_EXE}" t exec -t --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh print-latest-results")"

	# Collect bs=64K, num_jobs=4, io-direct, io-depth=2
	info "Processing random type workload"
	sleep 0.5
	sudo -E "${CTR_EXE}" t exec --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh run-randread-64k ${nj}" >/dev/null 2>&1
	local results_rand_read_64K="$(sudo -E "${CTR_EXE}" t exec -t --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh print-latest-results")"

	sleep 0.5
	sudo -E "${CTR_EXE}" t exec --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh run-randwrite-64k ${nj}" >/dev/null 2>&1
	local results_rand_write_64K="$(sudo -E "${CTR_EXE}" t exec -t --exec-id "${RANDOM}" ${CONTAINER_ID} sh -c "./fio_bench.sh print-latest-results")"

	# parse results
	metrics_json_init
	store_results "${results_read_4K}" "${results_write_4K}" "Results sequential"
	store_results "${results_rand_read_64K}" "${results_rand_write_64K}" "Results random"
	metrics_json_save
}

main "$@"
