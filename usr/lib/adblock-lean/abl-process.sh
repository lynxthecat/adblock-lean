#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060,SC3057,SC3040

# silence shellcheck warnings
: "${max_file_part_size_KB:=}" "${whitelist_mode:=}" "${list_part_failed_action:=}" "${test_domains:=}" "${intermediate_compression_options:=}" "${final_compression_options:=}" \
	"${max_download_retries:=}" "${deduplication:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" \
	"${blue:=}" "${green:=}" "${red:=}" "${n_c:=}"

BUSYBOX_PATH="/bin/busybox"

PROCESSED_PARTS_DIR="${ABL_TMP_DIR}/list_parts"

ERR_F="${ABL_TMP_DIR}/process-errors"

SCHEDULE_DIR="${ABL_TMP_DIR}/schedule"

PROCESSING_TIMEOUT_S=900 # 15 minutes
IDLE_TIMEOUT_S=300 # 5 minutes

ABL_TEST_DOM_BASE="adblocklean-test.totallybogus"

ALL_LIST_FORMATS="raw dnsmasq hosts"

# shellcheck disable=SC2034
hagezi_lists="anti.piracy blocklist-referral doh doh-vpn-proxy-bypass dyndns fake gambling gambling.medium gambling.mini hoster \
light multi native.amazon native.apple native.huawei native.lgwebos native.oppo-realme native.roku native.samsung \
native.tiktok native.tiktok.extended native.vivo native.winoffice native.xiaomi nosafesearch nsfw popupads \
pro pro.mini pro.plus pro.plus.mini social tif tif.medium tif.mini ultimate ultimate.mini urlshortener whitelist-referral" \
hagezi_formats="raw dnsmasq" \
hagezi_mirrors="github gitlab" \
	hagezi_github_url="https://raw.githubusercontent.com/hagezi/dns-blocklists/main" \
	hagezi_gitlab_url="https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists" \
\
oisd_lists="big small nsfw nsfw-small" \
oisd_formats="raw dnsmasq" \
oisd_mirrors="oisd github" \
	oisd_oisd_url="oisd.nl" \
	oisd_github_url="https://raw.githubusercontent.com/sjhgvr/oisd/main" \
\
stevenblack_lists="base fakenews gambling porn social" \
stevenblack_formats="hosts" \
stevenblack_mirrors="github sbc_io" \
	stevenblack_github_url="https://raw.githubusercontent.com/StevenBlack/hosts/master" \
	stevenblack_sbc_io_url="http://sbc.io/hosts"

IP_REGEX_4='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])'
IP_REGEX_6='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}'


# UTILITY FUNCTIONS

# 1 - var name to output extension
# 2 - var name to output compr util (gzip|zstd)
# 3 - path
get_compr_spec()
{
	local gcs_file='' gcs_ext='' gcs_util='' \
		extn_out_var="${1}" util_out_var="${2}" gcs_path="${3}"

	unset_vars "${extn_out_var}" "${util_out_var}" &&
	assert_set F_get_compr_spec extn_out_var util_out_var gcs_path || return 1

	gcs_file="${gcs_path##*"/"}"
	case "${gcs_file}" in
		*.gz) gcs_ext=.gz gcs_util=gzip ;;
		*.zst) gcs_ext=.zst gcs_util=zstd ;;
		*.*) reg_failure "Unexpected extension '${gcs_file##*.}' in file '${gcs_path}'."; return 1
	esac
	: "${gcs_ext}" "${gcs_util}"
	eval "${extn_out_var}"='${gcs_ext}' "${util_out_var}"='${gcs_util}'
}

# 1: input file
# 2: command including options
# 3: (optional) var name to output path to compressed file
try_compress()
{
	local IFS="${DEFAULT_IFS}" tc_cmd opts='' tc_err='' \
		tc_dir tc_fname tc_ext \
		tc_in_file="${1}" tc_cmd="${2}" out_file_var="${3}"

	unset_vars "${out_file_var}" &&
	split_path tc_dir tc_fname _ "${tc_in_file}" && [ -n "${tc_fname}" ] && is_valid_dir "${tc_dir}" &&
	{
		is_dir_writable "${tc_dir}" ||
			{ tc_err="Logic bug: attempted to compress file '${tc_in_file}' to protected dir '${tc_dir}'."; false; }
	} &&

	case "${tc_cmd}" in
		*gzip*|*pigz*) tc_ext=.gz ;;
		*zstd*) tc_ext=.zst ;;
		*) tc_err="unexpected command '${tc_cmd}'."; false
	esac &&

	${tc_cmd} "${tc_in_file}" ||
		{
			reg_failure "try_compress: ${tc_err}${tc_err:+ }Failed to compress '${tc_in_file}'."
			rm_if_writable "${tc_in_file}";
			return 1
		}

	[ -n "${out_file_var}" ] && eval "${out_file_var}"='${tc_in_file}${tc_ext}'

	: "${tc_ext}"
	:
}

# 0 (optional): '-stdout' (does not remove source file)
# 1: path to file to extract
try_extract()
{
	local stdout=
	[ "${1}" = '-stdout' ] && { stdout=1; shift; }

	local IFS="${DEFAULT_IFS}" cmd='' opts='' \
		file_opts='' \
		stdout_opts='' \
		te_dir te_fname te_ext \
		te_err='' \
		te_file="${1}"

	split_path te_dir te_fname te_ext "${te_file}" && [ -n "${te_fname}" ] && is_valid_dir "${te_dir}" &&
	{
		[ -n "${stdout}" ] || is_dir_writable "${te_dir}" ||
			{ te_err="Logic bug: attempted to extract file '${te_file}' to protected dir '${te_dir}'."; false; }
	} &&
	get_compr_spec _ cmd "${te_file}" &&

	case "${te_ext}" in
		gz)
			file_opts="-fd"
			stdout_opts="-cd" ;;
		zst)
			file_opts=" -fd --rm -q --no-progress"
			stdout_opts="-cd" ;;
		'') cmd="${CAT_CMD}" ;;
		*) te_err="file '${te_file}' has unexpected extension."; false
	esac &&

	if [ -n "${stdout}" ]
	then
		opts="${stdout_opts}"
	else
		opts="${file_opts}"
	fi &&

	${cmd} ${opts} "${te_file}" ||

	{
		[ -n "${stdout}" ] || rm_if_writable "${te_fname}"*
		reg_failure "try_extract: ${te_err}${te_err:+ }Failed to extract '${te_file}'."
		return 1
	}
}

# subtract list $1 from list $2, with optional field separator $4 (otherwise uses newline)
# output via optional variable with name $3
# returns status 0 if the result is null, 1 if not
subtract_a_from_b() {
	local sab_out="${3:-___dummy}" IFS="${DEFAULT_IFS}"
	are_var_names_safe "${sab_out}" || return 1
	case "${2}" in '') eval "${sab_out}=''"; return 0; esac
	case "${1}" in '') eval "${sab_out}"='${2}'; [ ! "${2}" ]; return; esac
	local _fs_su="${4:-"${_NL_}"}"
	local e rv_su=0 _subt=
	local IFS="${_fs_su}"
	for e in ${2}; do
		is_included "${e}" "${1}" "${_fs_su}" || { add2list _subt "${e}" "${_fs_su}"; rv_su=1; }
	done
	eval "${sab_out}"='$_subt'
	return ${rv_su}
}

# 1 - var name for ms output
get_uptime_ms()
{
	unset_vars "${1}" || return 1
	local __uptime __s __ms
	read -r __uptime _ < /proc/uptime &&
	case "${__uptime}" in
		''|*.*.*) false ;;
		*) :
	esac &&
	{
		__s="${__uptime%.*}"
		__ms="${__uptime##*.}"
		# normalize ms to 3 digits
		case "${__ms}" in
			'') __ms=000 ;;
			?) __ms="${__ms}00" ;;
			??) __ms="${__ms}0" ;;
			???) ;;
			???*) __ms="${__ms%"${__ms#???}"}"
		esac
	} &&
	is_uint "${__s}" "${__ms}" ||
	{
		reg_failure "Failed to get uptime from /proc/uptime."
		eval "${1:-_}"=0000
		return 1
	}
	eval "${1:-_}"='${__s:-0}${__ms:-000}'
}

# To use, first get initial uptime: 'get_uptime_ms INITIAL_UPTIME_MS'
# Then call this function to get elapsed time string at desired intervals, e.g.:
# get_elapsed_time_ms elapsed_time "${INITIAL_UPTIME_MS}"
# 1 - var name for output
# 2 - initial uptime in ms
get_elapsed_time_ms()
{
	local ge_uptime_ms
	get_uptime_ms ge_uptime_ms || return 1
	: "${ge_uptime_ms}"
	eval "${1}"='$(( ge_uptime_ms - ${2:-ge_uptime_ms} ))'
}

get_elapsed_time_human()
{
	local geh_elapsed _elapsed_ms _elapsed_m _elapsed_s elapsed_fp _elapsed_human
	get_elapsed_time_ms geh_elapsed "${2}" || return 1
	_elapsed_m=$(( geh_elapsed / 60000 ))
	_elapsed_ms=$(( geh_elapsed % 60000 ))
	_elapsed_s=$(( _elapsed_ms / 1000 ))
	elapsed_fp=$(( _elapsed_ms % 1000 ))
	elapsed_fp="${elapsed_fp%0}"
	elapsed_fp="${elapsed_fp%0}"
	: "${elapsed_fp:=0}"
	is_uint "${_elapsed_m}" "${_elapsed_s}" "${elapsed_fp}" && _elapsed_human="${_elapsed_m}m:${_elapsed_s}.${elapsed_fp}s" || _elapsed_human=unknown
	eval "${1}"='${_elapsed_human}'
	: "${_elapsed_m}" "${_elapsed_s}" "${elapsed_fp}" "${_elapsed_human}"
}


# HELPER FUNCTIONS

# 1 - var name for output
# 2 - list URL or short identifier
# 3 - list format (raw|dnsmasq)
# 4 - DL mirror
# shellcheck disable=SC2329
get_list_url()
{
	local base_url='' prefix='' suffix='' raw_suffix='' dnsmasq_suffix='' hosts_suffix='' \
		res_url list_author list_name lists='' list_id_lc list_formats \
		mirrors first_mirror \
		out_var="${1}" list_id="${2}" list_format="${3}" mirror="${4}"

	unset_vars "${out_var}" || return 1

	case "${list_format}" in raw|dnsmasq|hosts) ;; *) reg_failure "Unexpected list format '${list_format}'."; return 1; esac

	tolower list_id_lc "${list_id}"
	case "${list_id_lc}" in hagezi:*|oisd:*|stevenblack:*) ;; *)
		eval "${out_var}"='${list_id}'
		return 0
	esac
	list_id="${list_id_lc}"

	list_author="${list_id%%\:*}" list_name="${list_id#*\:}"

	eval "lists=\"\${${list_author}_lists}\""
	eval "base_url=\"\${${list_author}_${mirror}_url}\""
	[ -n "${base_url}" ] || { reg_failure "Failed to get base URL for ${list_author} mirror '${mirror}'."; return 1; }

	is_included "${list_name}" "${lists}" " " || { reg_failure "Unknown ${list_author} list '${2}'."; return 1; }

	eval "list_formats=\"\${${list_author}_formats}\""
	is_included "${list_format}" "${list_formats}" " " ||
		{ reg_failure "${list_id} is only available in formats: ${list_formats}."; return 1; }

	eval "mirrors=\"\${${list_author}_mirrors}\""
	is_included "${mirror}" "${mirrors}" " " ||
		{ reg_failure "Unexpected mirror '${mirror}' for list author ${list_author}."; return 1; }

	case "${list_author}" in
		hagezi)
			prefix="${base_url}"
			raw_suffix="/wildcard/${list_name}-onlydomains.txt"
			dnsmasq_suffix="/dnsmasq/${list_name}.txt" ;;
		stevenblack)
			prefix="${base_url}"
			case "${list_name}" in
				base) hosts_suffix="/hosts" ;;
				*) hosts_suffix="/alternates/${list_name}-only/hosts"
			esac ;;
		oisd)
			case "${mirror}" in
				oisd)
					prefix="https://${list_name}.${base_url}"
					raw_suffix="/domainswild2"
					dnsmasq_suffix="/dnsmasq2" ;;
				github)
					prefix="${base_url}"
					list_name="${list_name//-/_}"
					raw_suffix="/domainswild2_${list_name}.txt"
					dnsmasq_suffix="/dnsmasq2_${list_name}.txt"
			esac
	esac

	eval "suffix=\"\${${list_format}_suffix}\""
	res_url="${prefix}${suffix}"
	[ -n "${res_url}" ] || { reg_failure "Failed to construct URL for list identifier '${list_id}'."; return 1; }

	: "${raw_suffix}" "${dnsmasq_suffix}" "${hosts_suffix}"
	eval "${out_var}"='${res_url}'
}


# JOB SCHEDULER FUNCTIONS

# get current job PID
# 1 - var name for output
get_curr_job_pid()
{
	local __pid='' pid_line=''
	unset "${1}"
	IFS="${_NL_}" read -r -n512 -d '' _ _ _ _ _ pid_line _ < /proc/self/status
	__pid="${pid_line##*[^0-9]}"
	is_uint "${__pid}" || { reg_failure "Failed to get current job PID."; return 1; }
	eval "${1}"='${__pid}'
}

# 1 - PID of the job throwing the fatal error
# 2 - list path
handle_fatal()
{
	local fatal_pid="${1}" fatal_print_id="${2}"
	if [ -n "${fatal_pid}" ]
	then
		: "${fatal_print_id:=unknown}"
		reg_failure "Processing job (PID: ${fatal_pid}) for list '${fatal_print_id}' reported fatal error."
	else
		reg_failure "Fatal error reported by unknown processing job."
	fi

	[ -n "${SCHEDULER_PID}" ] && [ -d "/proc/${SCHEDULER_PID}" ] && {
		kill -s USR1 "${SCHEDULER_PID}"
		wait_on_pid "${SCHEDULER_PID}" 5
	}

	exit 1
}

# 1 - job PID
# 2 - job return code
handle_done_job()
{
	local done_pid="${1}" done_job_rv="${2}" done_id me=handle_done_job
	[ -n "${done_pid}" ] || { reg_failure "${me}: received empty string for PID."; return 1; }
	[ -n "${done_job_rv}" ] || { reg_failure "${me}: received empty string instead of return code for job ${done_pid}."; return 1; }

	subtract_a_from_b "${done_pid}" "${RUNNING_PIDS}" RUNNING_PIDS " "
	RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT-1))

	if [ "${done_job_rv}" != 0 ]
	then
		eval "done_id=\"\${JOB_PRINT_ID_${done_pid}}\""

		reg_failure "Processing job (PID ${done_pid}) for list '${done_id}' returned error code '${done_job_rv}'."
		[ "${list_part_failed_action}" = "STOP" ] && { log_msg "list_part_failed_action is set to 'STOP', exiting."; return 1; }
		log_msg -yellow "Skipping file and continuing."
	fi
	:
}

# sets var named $1 to remaining time based on $PROCESSING_TIMEOUT_S or to $IDLE_TIMEOUT_S, whichever is lower
# if timeout is hit, returns 1
# 1 - var name to output remaining time
get_remaining_time()
{
	local ct_curr_time_ms ct_curr_time_s ct_total_time_s ct_remaining_time_s
	eval "${1}"=0

	get_uptime_ms ct_curr_time_ms || return 1
	ct_curr_time_s=$((ct_curr_time_ms/1000))
	ct_total_time_s=$((INITIAL_UPTIME_S-ct_curr_time_s))

	ct_remaining_time_s=$((PROCESSING_TIMEOUT_S-ct_total_time_s))
	[ "${ct_remaining_time_s}" -gt 0 ] ||
	{
		reg_failure "Processing timeout (${PROCESSING_TIMEOUT_S} s) for scheduler (PID: ${SCHEDULER_PID})."
		return 1
	}

	case "$(( IDLE_TIMEOUT_S - (ct_curr_time_s-${CT_PREV_TIME_S:-${INITIAL_UPTIME_S}}) ))" in
		0|-*)
			reg_failure "Idle timeout (${IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCHEDULER_PID})."
			return 1
	esac

	case $((IDLE_TIMEOUT_S-ct_remaining_time_s)) in
		-*) ct_remaining_time_s="${IDLE_TIMEOUT_S}"
	esac

	CT_PREV_TIME_S=${ct_curr_time_s}
	eval "${1}"='${ct_remaining_time_s}'
}

# 1 - list origin (DL|LOCAL)
# 2 - list URL or local path
# 3 - list type (block|ipv4_block|allow)
# 4 - list format (raw|dnsmasq|hosts)
# the rest of the args passed as-is to workers
schedule_job()
{
	local remaining_time_s done_pid done_rv print_id
	eval "print_id=\"\${${list_format}_${list_type}_${index}_print_id}\""

	get_remaining_time remaining_time_s || return 1

	# wait for job vacancy
	while [ "${RUNNING_JOBS_CNT}" -ge "${PARALLEL_JOBS}" ] && [ -e "${SCHED_CB_FIFO}" ] &&
		read -t "${remaining_time_s}" -r done_pid done_rv < "${SCHED_CB_FIFO}"
	do
		get_remaining_time remaining_time_s || return 1
		handle_done_job "${done_pid}" "${done_rv}" || return 1
	done

	get_remaining_time remaining_time_s || return 1

	RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT+1))
	process_list_part "${@}" "${print_id}" &

	RUNNING_PIDS="${RUNNING_PIDS} ${!}"
	export "JOB_PRINT_ID_${!}"="${print_id}"

	:
}

# 1 - list types (allow|block|ipv4_block)
schedule_jobs()
{
	finalize_scheduler()
	{
		trap ':' USR1
		[ -n "${USR_TRIG}" ] && log_msg -yellow "" "Job scheduler is stopping on receipt of USR1 signal."
		[ "${1}" != 0 ] && [ -n "${RUNNING_PIDS}" ] &&
		{
			reg_msg -yellow "" "Stopping unfinished jobs (PIDS: ${RUNNING_PIDS})."
			kill_pids_recursive "${RUNNING_PIDS}"
			rm -rf "${PROCESSED_PARTS_DIR}" 2>/dev/null
		}
		rm -f "${SCHED_CB_FIFO}"
		exit "${1}"
	}

	local list_type list_format index indexes \
		SCHEDULER_PID \
		list_types="${1}"
	get_curr_job_pid SCHEDULER_PID || finalize_scheduler 1

	RUNNING_PIDS=
	RUNNING_JOBS_CNT=0

	trap 'USR_TRIG=1 finalize_scheduler 1' USR1

	local SCHED_CB_FIFO="${SCHEDULE_DIR}/scheduler_callback_${SCHEDULER_PID}"
	mkfifo "${SCHED_CB_FIFO}" &&
	exec 3<>"${SCHED_CB_FIFO}" || { reg_failure "Failed to create FIFO '${SCHED_CB_FIFO}'."; finalize_scheduler 1; }

	print_msg ""

	for list_type in ${list_types}
	do
		for list_format in ${ALL_LIST_FORMATS}
		do
			eval "indexes=\"\${${list_format}_${list_type}_indexes}\""
			[ -n "${indexes}" ] || continue

			for index in ${indexes}
			do
				schedule_job "${index}" "${list_type}" "${list_format}" || finalize_scheduler 1
			done
		done
	done

	# wait for jobs to finish and handle errors
	local remaining_time_s done_pid done_rv
	get_remaining_time remaining_time_s || return 1
	while [ "${RUNNING_JOBS_CNT}" -gt 0 ] && [ -e "${SCHED_CB_FIFO}" ] &&
		read -t "${remaining_time_s}" -r done_pid done_rv < "${SCHED_CB_FIFO}"
	do
		get_remaining_time remaining_time_s &&
		handle_done_job "${done_pid}" "${done_rv}" || finalize_scheduler 1
	done
	get_remaining_time remaining_time_s || finalize_scheduler 1
	[ "${RUNNING_JOBS_CNT}" = 0 ] ||
		{ reg_failure "Not all jobs are done: \${RUNNING_JOBS_CNT}=${RUNNING_JOBS_CNT}"; finalize_scheduler 1; }

	finalize_scheduler 0
}

# 1 - list index
# 2 - list type (block|ipv4_block|allow)
# 3 - list format (raw|dnsmasq|hosts)
# 4 - job print id
# the rest of the args passed as-is to workers
#
# return codes:
# 0 - Success
# 1 - Fatal error (stop processing)
# 2 - Download failure
# 3 - Processing failure
# shellcheck disable=SC2317,SC2329
process_list_part()
{
	finalize_job()
	{
		[ -n "${2}" ] && reg_failure "process_list_part: ${2}"
		case "${1}" in
			0)
				local list_size_human stats_pad suffix_pad
				bytes2human list_size_human "${part_size_B}" -p
				get_pad stats_pad "${print_id}" 38
				get_pad suffix_pad "${line_count_human}" 8
				log_msg "Successfully processed list:  ${green}${print_id}${n_c} ${stats_pad}[ ${list_size_human} - ${suffix_pad}${line_count_human} lines ]" ;;
			*)
				rm -f "${dest_file}" "${list_stats_file}"
				[ "${1}" = 1 ] && handle_fatal "${curr_job_pid}" "${print_id}"
		esac

		printf '%s\n' "${curr_job_pid} ${1}" > "${SCHED_CB_FIFO}"
		exit "${1}"
	}

	dl_list() { uclient-fetch "${1}" -O- --timeout=3 2> "${ucl_err_file}"; }

	conv_dnsmasq_to_raw()
	{
		local conv_prefix='s~^[ \t]*(local|server|address)=/~~' conv_suffix=''
		case "${1}" in
			block) conv_suffix='s~/$~~' ;;
			ipv4_block) conv_prefix="s~^[ \t]*bogus-nxdomain=~~" ;;
			allow) conv_suffix='s~/#$~~'
		esac
		${SED_CMD} -E "${conv_prefix};${conv_suffix}" | tr '/' '\n'
	}

	conv_hosts_to_raw()
	{
		${SED_CMD} -nE '
			/^\s*(0[.]0[.]0[.]0|::)\s+(0[.]0[.]0[.]0|::)\s*$/d;
			s/^\s*(0[.]0[.]0[.]0|::)\s+([^. 	]+([.][^. 	]+)+)$/\2/p
		' |
		# subdomains compression - slightly improved variant of code from adblock by Dirk Brenken
		${AWK_CMD} -F "." '{for(f=NF;f>1;f--)printf "%s.",$f;print $1}' | # invert labels order
		${SORT_CMD} |
		${SED_CMD} '/^$/d' |
		${AWK_CMD} '{if(NR==1){DOM=$0}; while(getline){if(index($0,DOM".")==0){print DOM;DOM=$0}}; print DOM}' | # compress subdomains
		${AWK_CMD} -F "." '{for(f=NF;f>1;f--)printf "%s.",$f;print $1}' # invert labels order back
	}

	case_conv() { tr 'A-Z' 'a-z'; }

	local curr_job_pid msg msg_mirr pad \
		list_origin='' list_path='' list_author='' mirrors='' mirror='' curr_mirror='' first_mirror='' loop_prev_mirror='' \
		index="${1}" list_type="${2}" list_format="${3}" print_id="${4}"

	get_curr_job_pid curr_job_pid || finalize_job 1

	eval "list_origin=\"\${${list_format}_${list_type}_${index}_origin}\"" &&
	ASSERT_NOEXIT=1 assert_set F_process_list_part index list_type list_format print_id list_origin || finalize_job 1

	list_path="${print_id}"

	if [ "${list_origin}" = DL ] &&
		list_author="${print_id%:*}" &&
		case "${list_author}" in
			hagezi|oisd|stevenblack) : ;;
			*) false
		esac
	then
		eval "mirrors=\"\${${list_author}_mirrors}\"" &&
		trim_spaces mirrors &&
		[ -n "${mirrors}" ] &&
		first_mirror="${mirrors%% *}" &&
		[ -n "${first_mirror}" ] || finalize_job 1 "Failed to process download mirrors for list author ${list_author}."

		eval "curr_mirror=\"\${${list_author}_default_mirror}\""
		: "${curr_mirror:="${first_mirror}"}"
	fi

	local list_id="${list_type}-${list_origin}-${list_format}"
	local job_id="${list_id}-${curr_job_pid}"
	local dest_file="${PROCESSED_PARTS_DIR}/${job_id}" \
		ucl_err_file="${ABL_TMP_DIR}/ucl_err_${job_id}" \
		rogue_el_file="${ABL_TMP_DIR}/rogue_el_${job_id}" \
		list_stats_file="${ABL_TMP_DIR}/stats_${job_id}" \
		part_line_count='' line_count_human min_line_count='' min_line_count_human \
		part_size_B='' retry=1 \
		part_compr_or_cat="cat" fetch_cmd \
		format_conv_or_cat="cat" \
		case_conv_or_cat="cat" \
		pipeline_rv

	case "${list_origin}" in
		DL) fetch_cmd=dl_list ;;
		LOCAL) fetch_cmd="cat" ;;
		*) finalize_job 1 "Invalid list origin '${list_origin}'."
	esac

	case "${list_type}" in
		allow|block) val_entry_regex='^[[:alnum:]-]+$|^(\*|[[:alnum:]_-]+)([.][[:alnum:]_-]+)+$' ;;
		ipv4_block) val_entry_regex='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$' ;;
		*) finalize_job 1 "Invalid list type '${list_type}'"
	esac

	case ${list_type} in block|ipv4_block)
		dest_file="${dest_file}${INTERM_COMPR_EXT}"
		part_compr_or_cat="${INTERM_COMPR_OR_CAT_STDOUT}"
	esac

	case "${list_format}" in
		dnsmasq|hosts) format_conv_or_cat="conv_${list_format}_to_raw ${list_type}"
	esac

	case "${list_type}" in
		allow|block) case_conv_or_cat="case_conv"
	esac

	eval "min_line_count=\"\${min_${list_type}list_part_line_count}\""

	while :
	do
		# use forced mirror for this list author if set
		if [ "${list_origin}" = DL ] && [ -n "${list_author}" ]
		then
			read_str_from_file -v curr_mirror -f "${SCHEDULE_DIR}/${list_author}-forced-mirror" -a 1 -q -n 128 -V "${curr_mirror}"
			get_list_url list_path "${print_id}" "${list_format}" "${curr_mirror}" || finalize_job 1
		fi

		msg_mirr=
		[ -n "${curr_mirror}" ] && msg_mirr=" (mirror: ${curr_mirror})"

		rm -f "${rogue_el_file}" "${list_stats_file}" "${ucl_err_file}"

		msg="Processing ${list_format} ${list_type}list"
		get_pad pad "${msg}" 28

		reg_msg "${msg}: ${pad}${blue}${print_id}${n_c}${msg_mirr}"

		# Download or cat the list
		${fetch_cmd} "${list_path}" |

		# Limit size
		{
			head -c "${max_file_part_size_KB}k"
			if read -rn1 -d ''
			then cat 1>/dev/null; false
			else :
			fi
		} |

		# Remove comment lines and trailing comments, remove whitespaces
		${SED_CMD} 's/#.*$//; s/^[ \t]*//; s/[ \t]*$//; /^$/d' |

		# Convert dnsmasq format to raw format
		${format_conv_or_cat} |

		# Count bytes and entries
		tee >(wc -wc > "${list_stats_file}") |

		# Convert to lowercase
		${case_conv_or_cat} |

		if [ "${list_type}" = block ] && [ "${use_allowlist}" = 1 ]
		then
			case "${whitelist_mode}" in
			0)
				# remove allowlist domains from blocklist
				${AWK_CMD} 'NR==FNR { if ($0 ~ /^\*\./) { allow_wild[substr($0,3)]; next }; allow[$0]; next }
					{ n=split($1,arr,"."); addr = arr[n]; for ( i=n-1; i>=1; i-- )
					{ addr = arr[i] "." addr; if ( (i>1 && addr in allow_wild) || addr in allow ) next } } 1' "${PROCESSED_PARTS_DIR}/allow" - ;;
			1)
				# only print subdomains of allowlist domains
				${AWK_CMD} 'NR==FNR { if ($0 !~ /^\*/) { allow[$0] }; next } { n=split($1,arr,"."); addr = arr[n];
					for ( i=n-1; i>1; i-- ) { addr = arr[i] "." addr; if ( addr in allow ) { print $1; next } } }' "${PROCESSED_PARTS_DIR}/allow" -
			esac
		else
			cat
		fi |

		# check lists for rogue elements
		tee >(${SED_CMD} -nE "/${val_entry_regex}/d;p;:1 n;b1" > "${rogue_el_file}") |

		# compress or cat
		${part_compr_or_cat} > "${dest_file}"

		pipeline_rv=${?}

		# read stats
		read_str_from_file -v "part_line_count part_size_B _" -f "${list_stats_file}" -a 2 -D "list stats" || finalize_job 1

		# size-exceeded check
		if ! [ $(( 1 + part_size_B / 1024)) -lt "${max_file_part_size_KB}" ]
		then
			reg_failure "Size of ${list_type}list part '${print_id}' reached the maximum value set in config (${max_file_part_size_KB} KB)."
			log_msg "Consider either increasing this value in the config or removing the corresponding ${list_type}list part path or URL from config."
			finalize_job 2
		fi

		[ "${pipeline_rv}" = 0 ] || { reg_failure "Processing pipeline for list part '${print_id}' returned error code ${pipeline_rv}."; finalize_job 1; }

		# rogue elements check
		if [ -s "${rogue_el_file}" ]
		then
			read_str_from_file -d -n 512 -v "rogue_element" -f "${rogue_el_file}" -a 2 -D "rogue element"
			local rogue_el_print
			if [ -n "${rogue_element}" ]
			then
				rogue_el_print="Rogue element '${rogue_element}'"
			else
				rogue_el_print="Unknown rogue element"
			fi

			case "${rogue_element}" in
				*"${CR_LF}"*)
					log_msg -warn "${list_type}list part '${print_id}' contains Windows-format (CR LF) newlines." \
						"This file needs to be converted to Unix newline format (LF)." ;;
				*) log_msg -warn "${rogue_el_print} identified in ${list_type}list part '${print_id}'."
			esac
			finalize_job 3
		fi

		# min_line_count check
		int2human line_count_human "${part_line_count}" || finalize_job 1    # ${line_count_human} also used in finalize_job()

		local lines_cnt_low=''
		if [ "${list_origin}" = DL ] && [ "${part_line_count}" -lt "${min_line_count}" ]
		then
			lines_cnt_low=1
			int2human min_line_count_human "${min_line_count}" || finalize_job 1
			reg_failure "Line count in downloaded ${list_type}list part '${print_id}' is ${line_count_human}, which is less than configured minimum: ${min_line_count_human}."
		fi

		if [ "${list_origin}" = DL ] && { ! grep -q "Download completed" "${ucl_err_file}" || [ -n "${lines_cnt_low}" ]; }
		then
			reg_failure "Failed download attempt for list '${print_id}'."
			[ -s "${ucl_err_file}" ] && log_msg "uclient-fetch output: ${_NL_}'$(cat "${ucl_err_file}")'."
			rm -f "${ucl_err_file}"
		else
			rm -f "${ucl_err_file}"
			# set this mirror as forced if this is not the first DL attempt
			[ "${list_origin}" = DL ] && [ -n "${list_author}" ] && [ "${retry}" != 1 ] &&
				printf '%s\n' "${curr_mirror}" > "${SCHEDULE_DIR}/${list_author}-forced-mirror"
			finalize_job 0
		fi

		retry=$((retry + 1))
		if [ "${retry}" -gt "${max_download_retries}" ]
		then
			finalize_job 2 "${max_download_retries} download attempts failed for list '${print_id}'."
		fi

		log_msg -yellow "" "Processing job for list '${print_id}' is sleeping for 5 seconds after failed download attempt."
		sleep 5 &
		wait ${!}

		if [ "${list_origin}" = DL ] && [ -n "${list_author}" ]
		then
			# cycle to the next mirror
			next_mirror='' loop_prev_mirror=''
			for mirror in ${mirrors}
			do
				[ "${loop_prev_mirror}" = "${curr_mirror}" ] && { next_mirror="${mirror}"; break; }
				loop_prev_mirror="${mirror}"
			done
			curr_mirror="${next_mirror:-"${first_mirror}"}"
		fi
	done
}

gen_list_parts()
{
	# shellcheck disable=SC2329
	read_stats_cb()
	{
		read_str_from_file -v "part_line_count part_size_B" -f "${1}" -V 0 &&
		is_uint "${part_line_count}" "${part_size_B}" || return 1
		list_line_count=$((list_line_count+part_line_count))
		list_size_B=$((list_size_B+part_size_B))
	}

	# shellcheck disable=SC2329
	concat_allow_cb()
	{
		${CAT_CMD} "${1}" >> "${PROCESSED_PARTS_DIR}/allow"
		local rv=${?}
		rm -f "${1}"
		return "${rv}"
	}

	local lists schedule_req local_list_path list_format list_type \
		preproc_cnt=0 preproc_cnt_human \
		preproc_size_B=0 preproc_size_human \
		invalid_urls bad_hagezi_urls \
		list_line_count list_types


	[ -n "${raw_block_lists}${dnsmasq_block_lists}${hosts_block_lists}" ] ||
		log_msg -yellow "" "NOTE: No URLs specified for blocklist download."

	# clean up before processing
	rm -rf "${PROCESSED_PARTS_DIR}" "${SCHEDULE_DIR}"

	try_mkdir -p "${SCHEDULE_DIR}" &&
	try_mkdir -p "${PROCESSED_PARTS_DIR}" || return 1

	if [ "${whitelist_mode}" = 1 ]
	then
		# allow test domains
		for d in ${test_domains}
		do
			printf '%s\n' "${d}" >> "${PROCESSED_PARTS_DIR}/allow"
			preproc_cnt=$((preproc_cnt+1))
		done
		use_allowlist=1
	fi

	reg_action -1 -blue "" "Downloading and processing blocklist parts (max parallel jobs: ${PARALLEL_JOBS})."

	# Asynchronously download and process parts, allowlist must be processed separately and first
	for list_types in allow "block ipv4_block"
	do
		schedule_req=''
		for list_type in ${list_types}
		do
			for list_format in ${ALL_LIST_FORMATS}
			do
				eval "lists=\"\${${list_format}_${list_type}_lists}\""
				local_list_path=
				[ "${list_format}" = raw ] && eval "local_list_path=\"\${local_${list_type}list_path}\""
				[ -n "${lists}" ] || [ -f "${local_list_path}" ] || continue

				invalid_urls="$(printf %s "${lists}" | tr ' ' '\n' | grep -E '^(http[s]*://)*(www\.)*github\.com')" &&
				{
					reg_failure "Invalid URLs detected:" "${invalid_urls}"
					return 1
				}

				if [ "${list_format}" = raw ]
				then
					bad_hagezi_urls="$(printf %s "${lists}" | tr ' ' '\n' | grep '/hagezi/.*/dnsmasq/')" &&
					{
						reg_failure "Following Hagezi URLs are in dnsmasq format and should be either changed to raw list URLs" \
							"or moved to one of the 'dnsmasq_' config entries:" "${bad_hagezi_urls}"
						return 1
					}
					case "${list_type}" in block|allow)
						bad_hagezi_urls="$(printf %s "${lists}" | tr ' ' '\n' |
							${SED_CMD} -n '/^hagezi:/n;/\/hagezi\//{/onlydomains\./d;/^$/d;p;}')"
						[ -z "${bad_hagezi_urls}" ] ||
						{
							reg_failure "Following Hagezi URLs are missing the '-onlydomains' suffix in the filename:" \
								"${bad_hagezi_urls}"
							return 1
						}
					esac
				fi

				index=0
				for list in ${lists}
				do
					index=$((index+1))
					schedule_req=1
					add2list "${list_format}_${list_type}_indexes" "${index}"
					eval "${list_format}_${list_type}_${index}_origin=DL
						${list_format}_${list_type}_${index}_print_id=\"${list}\""
				done

				if [ "${list_format}" = raw ] && [ -n "${local_list_path}" ]
				then
					if [ ! -f "${local_list_path}" ]
					then
						reg_msg "No local ${list_type}list identified."
					elif [ ! -s "${local_list_path}" ]
					then
						log_msg -warn "" "Local ${list_type}list file is empty."
					else
						index=$((index+1))
						schedule_req=1
						add2list "${list_format}_${list_type}_indexes" "${index}"
						eval "raw_${list_type}_${index}_origin=LOCAL
							raw_${list_type}_${index}_print_id=\"${local_list_path}\""
					fi
				fi
			done
		done

		if [ -n "${schedule_req}" ]
		then
			schedule_jobs "${list_types}" &
			SCHEDULER_PID=${!}

			wait "${SCHEDULER_PID}"
			local sched_rv=${?}			
			SCHEDULER_PID=
			[ ${sched_rv} = 0 ] || return ${sched_rv}
		fi

		if [ "${list_types}" = allow ]
		then
			# consolidate allowlist parts into one file
			FF_EXEC="concat_allow_cb {}" \
				find_files _ "${PROCESSED_PARTS_DIR}" "allow-" || [ ${?} != 1 ] ||
					{ reg_failure "Failed to merge allowlist part."; return 1; }
		fi

		# process results
		for list_type in ${list_types}
		do
			# count lines for current list type
			local part_line_count=0 list_line_count=0 part_size_B=0 list_size_B=0
			FF_EXEC="read_stats_cb {}" \
				find_files _ "${ABL_TMP_DIR}" "stats_${list_type}-" || [ ${?} != 1 ] ||
					{ reg_failure "Failed to read processed ${list_type}list parts stats."; return 1; }

			if ! [ "${list_line_count}" -gt 0 ] || ! [ "${list_size_B}" -gt 0 ]
			then
				case "${list_type}" in
					block)
						[ "${whitelist_mode}" = 0 ] && return 1
						log_msg -yellow "Whitelist mode is on - accepting empty blocklist." ;;
					allow)
						reg_msg "Not using any allowlist for blocklist processing."
				esac
			elif [ "${list_type}" = ipv4_block ]
			then
				use_ipv4_blocklist=1
			elif [ "${list_type}" = allow ]
			then
				reg_msg "Will remove any (sub)domain matches present in the allowlist from the blocklist and append corresponding server entries to the blocklist."
				use_allowlist=1
			fi
			preproc_cnt=$((preproc_cnt+list_line_count))
			preproc_size_B=$((preproc_size_B+list_size_B))
		done
	done

	int2human preproc_cnt_human "${preproc_cnt}" &&
	bytes2human preproc_size_human "${preproc_size_B}" || return 1
	reg_msg "" "${green}Successfully generated preprocessed blocklist files${n_c} (total uncompressed size: ${blue}${preproc_size_human}${n_c}, entries count: ${blue}${preproc_cnt_human}${n_c})."
	:
}

gen_blocklists()
{
	local \
		me=gen_blocklists \
		processed_bl_file \
		bl_inst \
		run_state \
		ram_bl_file_curr \
		persist_bl_file_curr \
		conn_check_req \
		restore_from_persist='' \
		file_to_bk \
		bk_file \
		inst_force_unload \
		location \
		install_path \
		persist_dir \
		index \
		dnsmasq_indexes \
		totalmem \
		blocklists_out_var="${1:?}" failed_blocklists_out_var="${2:?}" bl_instances="${3:?}" initial_uptime_ms="${4:?}"

	if [ "${unload_blocklist_before_update}" = auto ] # global var
	then
		read -r _ totalmem _ < /proc/meminfo
		if is_uint "${totalmem}" && [ "${totalmem}" -ge 410000 ]
		then
			unload_blocklist_before_update=0
		else
			unload_blocklist_before_update=1
		fi
	fi

	for bl_inst in ${bl_instances}
	do
		# TODO: where is RUN_STATE_ set?
		unset "RESTORE_FROM_PERSIST_${bl_inst}" "SKIP_LOAD_STOP_${bl_inst}"
		eval "run_state=\"\${RUN_STATE_${bl_inst}}\"" \
			"persist_dir=\"\${PERSIST_DIR_${bl_inst}}\"" \
			"install_path=\"\${INSTALL_PATH_${bl_inst}}\"" \
			"dnsmasq_indexes=\"\${DNSMASQ_INDEXES_${bl_inst}}\"" \
			"bk_file=\"\${BK_FILE_${bl_inst}}\""

		assert_set "F_${me}" install_path || exit 1

		location=RAM
		[ "${install_path%/*}" = "$persist_dir" ] && location=PERSIST

		get_curr_bl_path ram_bl_file_curr "${bl_inst}" BL RAM &&
		get_curr_bl_path persist_bl_file_curr "${bl_inst}" BL RAM || exit 1

		case "${run_state}" in
			0|3|4) ;;
			1)
				stop 1 -noexit # TODO: stop individual indexes
				get_abl_run_state run_state "${bl_inst}" ;;
			*) inval_run_state "${run_state}"; exit 1 # TODO: inval_run_state per-inst
		esac

		conn_check_req=1
		inst_force_unload=${unload_blocklist_before_update}

		case ${run_state} in
			0) ;;
			3|4) inst_force_unload=0 conn_check_req='' ;;
			*) exit 1
		esac

		if [ "${inst_force_unload}" != 1 ] && [ -n "${conn_check_req}" ]
		then
			test_url_domains || inst_force_unload=1 # TODO: test per-bl-inst domains
		fi

		file_to_bk=
		if [ -n "${ram_bl_file_curr}" ]
		then
			file_to_bk=${ram_bl_file_curr}
		elif [ -n "${persist_bl_file_curr}" ] && eval "[ -z \"\${PERSIST_BL_FILE_BAD_${bl_inst}}\" ]"
		then
			file_to_bk=${persist_bl_file_curr}
		else
			reg_msg -2 "" "No valid existing blocklist found for blocklist instance '${bl_inst}'."
		fi

		[ -n "${file_to_bk}" ] &&
		{
			if is_dir_writable "${file_to_bk%/*}"
			then
				export_blocklist "${file_to_bk}" "${bk_file}" "${INTERM_COMPR_TO_FILE}"
			elif [ -f "${file_to_bk}" ]
			then
				# for persistent blocklist in 'manual' mode, the original file is used as a backup
				bk_file=${file_to_bk}
				restore_from_persist=1
			fi

			eval "RESTORE_FROM_PERSIST_${bl_inst}"='${restore_from_persist}'

		}

		rm_main_bl "${bl_inst}" "ram"

		if [ "${inst_force_unload}" = 1 ]
		then
			reg_action -blue "Unloading current blocklist."
			restart_dnsmasq "${dnsmasq_indexes}" || exit 1
			eval "SKIP_LOAD_STOP_${bl_inst}=1"
		fi

		processed_bl_file="${ABL_TMP_DIR}/processed-blocklist${FINAL_COMPR_EXT}"

		if gen_blocklist "BL_CNT_${location}_${bl_inst}" "${processed_bl_file}" "${initial_uptime_ms}" &&
			get_md5 "BL_MD5_${location}_${bl_inst}" "${processed_bl_file}" &&
			mv_blocklist "${processed_bl_file}" "${install_path}" "${FINAL_COMPR_TO_FILE}"
		then
			eval "BL_PATH_${location}_${bl_inst}"='${install_path}'
			add2list "${blocklists_out_var}" "${bl_inst}" " "
		else
			reg_failure "Failed to generate new blocklist."
			add2list "${failed_blocklists_out_var}" "${bl_inst}" " "
		fi
	done
}


# shellcheck disable=SC2329
gen_blocklist()
{
	# convert to dnsmasq format and pack 4 input lines into 1 output line
	# intput from STDIN, output to STDOUT
	# 1 - block|allow
	pack_entries_sed()
	{
		case "$1" in
			block)
				# packs 4 domains in one 'local=/.../' line
				${SED_CMD} "/^$/d;s~^.*$~local=/&/~;\$!{n;a /${_NL_}};\$!{n;a /${_NL_}};\$!{n; a /${_NL_}};a @" ;;
			allow)
				# packs 4 domains in one 'server=/.../#'' line
				{ cat; printf '\n'; } | ${SED_CMD} '/^$/d;$!N;$!N;$!N;s~\n~/~g;s~^~server=/~;s~/*$~/#@~' ;;
			*) printf ''; return 1
		esac | tr -d '\n' | tr "@" '\n'
	}

	# convert to dnsmasq format and pack input lines into 1024 characters-long lines
	# intput from STDIN, output to STDOUT
	# 1 - block|allow
	pack_entries_awk()
	{
		local entry_type len_lim=1024 allow_char=''
		case "$1" in
			block) entry_type=local ;;
			allow) entry_type=server allow_char="#" ;;
		esac

		len_lim=$((len_lim-${#entry_type}-${#allow_char}-2))
		# shellcheck disable=SC2016
		${AWK_CMD} -v ORS="" -v m="${len_lim}" -v a="${allow_char}" -v t="${entry_type}" '
			BEGIN {al=0; r=0; s=""}
			NF {
				r=r+1
				if (r==1) {print t "=/"}
				l=length($0)
				n=al+1+l
				if (n<=m) {al=n; print $0 "/"; next}
				else {print a "\n" t "=/" $0 "/"; al=l+1}
			}
			END {print a "\n"}'
	}

	# 1 - list type (block|ipv4_block)
	# 2 - <.gz|.zst|''>
	# 3 - decompression command or 'cat'
	print_list_parts()
	{
		local prefix="${1}" suffix="${2}" print_cmd="${3}"

		# shellcheck disable=SC2329
		print_file_cb()
		{
			local rv=1
			${print_cmd} "${1}"
			rv=${?}
			rm -f "${1}"
			return "${rv}"
		}

		FF_EXEC="print_file_cb {}" \
			find_files _ "${PROCESSED_PARTS_DIR}" "${prefix}-" "${suffix}" || printf ''
	}

	# 1 - var name for output
	# 2 - path to file
	read_list_stats()
	{
		read -r "${1?}" 2>/dev/null < "${2}"
		eval ": \"\${${1}:=0}\""
	}

	local me=gen_blocklist \
		gen_cnt \
		gen_cnt_human min_good_line_count_human \
		list_type \
		errors \
		max_size_b=$((max_blocklist_file_size_KB*1024)) \
		dedup_cmd_or_cat="${CAT_CMD}" \
		pack_cmd="pack_entries_sed" \
		\
		cnt_out_var="${2}" \
		out_f="${3}" \
		INITIAL_UPTIME_S="$(( ${4} / 1000 ))"

	unset_vars cnt_out_var &&
	assert_set "F_${me}" cnt_out_var out_f PART_EXTR_OR_CAT_STDOUT FINAL_EXTR_OR_CAT_STDOUT FINAL_COMPR_OR_CAT_STDOUT &&
	case "${PART_EXTR_OR_CAT_STDOUT}" in
		cat|*" cat") ;;
		*) assert_set "F_${me}" INTERM_COMPR_EXT || false
	esac || return 1

	[ "${deduplication}" = 1 ] && dedup_cmd_or_cat="${SORT_CMD} -u -"

	case "${AWK_CMD}" in
		*gawk) pack_cmd="pack_entries_awk"
	esac

	gen_list_parts ||
	{
		reg_failure "Failed to generate preprocessed blocklist file with at least one entry."
		return 1
	}

	reg_action -blue "" "Sorting and merging the blocklist parts into a single blocklist file." || return 1
	{
		{
			# print blocklist parts
			print_list_parts block "${INTERM_COMPR_EXT}" "${PART_EXTR_OR_CAT_STDOUT}" |
			# optional deduplication
			${dedup_cmd_or_cat} |
			# count entries
			tee >(wc -w > "${ABL_TMP_DIR}/block_stats") |
			# pack entries in 1024 characters long lines
			${pack_cmd} block || exit 1

			# print ipv4 blocklist parts
			if [ -n "${use_ipv4_blocklist}" ]
			then
				print_list_parts ipv4_block "${INTERM_COMPR_EXT}" "${PART_EXTR_OR_CAT_STDOUT}" |
				# optional deduplication
				${dedup_cmd_or_cat} |
				tee >(wc -w > "${ABL_TMP_DIR}/ipv4_block_stats") |
				# add prefix
				${SED_CMD} 's/^/bogus-nxdomain=/' || exit 1
			fi

			# print allowlist parts
			if [ -n "${use_allowlist}" ]
			then
				# optional deduplication
				${dedup_cmd_or_cat} < "${PROCESSED_PARTS_DIR}/allow" |
				tee >(wc -w > "${ABL_TMP_DIR}/allow_stats") |
				# pack entries in 1024 characters long lines
				${pack_cmd} allow || exit 1

				rm -f "${PROCESSED_PARTS_DIR}/allow"
			fi

			# add the optional whitelist entry
			if [ "${whitelist_mode}" = 1 ]
			then
				# add block-everything entry: local=/*a/*b/*c/.../*z/
				printf 'local=/'
				${AWK_CMD} 'BEGIN{for (i=97; i<=122; i++) printf("*%c/",i);exit}' || exit 1
				printf '\n'
			fi
			:
		} |

		# limit size
		{ head -c "${max_size_b}"; read -rn1 -d '' && { touch "${ABL_TMP_DIR}/abl-too-big.tmp"; cat 1>/dev/null; } || true; } |

		# compress or cat
		${FINAL_COMPR_OR_CAT_STDOUT} > "${out_f}"
	} 2>"${ERR_F}" ||
		{
			reg_failure "Failed to merge blocklist parts into output file '${out_f}'."
			errors="$(head -n10 "${ERR_F}" 2>/dev/null | ${SED_CMD} '/^$/d')"
			rm -f "${out_f}" "${ERR_F}"
			[ -n "${errors}" ] && log_msg "STDERR output:${_NL_}${errors}"
			return 1
		}
	rm -f "${ERR_F}"

	if [ -f "${ABL_TMP_DIR}/abl-too-big.tmp" ]
	then
		rm -f "${out_f}"
		reg_failure "Final uncompressed blocklist exceeded ${max_blocklist_file_size_KB} kiB set in max_blocklist_file_size_KB config option!"
		log_msg "Consider either increasing this value in the config or changing the blocklist URLs."
		return 1
	fi

	# check total entries count vs min_good_line_count
	local block_cnt ipv4_block_cnt allow_cnt
	for list_type in block ipv4_block allow
	do
		read_list_stats "${list_type}_cnt" "${ABL_TMP_DIR}/${list_type}_stats"
	done

	gen_cnt=$(( block_cnt + ipv4_block_cnt + allow_cnt ))

	[ "${whitelist_mode}" = 1 ] && gen_cnt=$((gen_cnt-26)) # ignore alphabet entries

	is_uint "${gen_cnt}" || gen_cnt=0

	if [ "${gen_cnt}" -lt "${min_good_line_count}" ]
	then
		int2human gen_cnt_human "${gen_cnt}" &&
		int2human min_good_line_count_human "${min_good_line_count}" || return 1
		reg_failure "Entries count (${gen_cnt_human}) is below the minimum value set in config (${min_good_line_count_human})."
		return 1
	fi

	# check the final blocklist with dnsmasq --test
	reg_action -blue "Checking the processed blocklist file with 'dnsmasq --test'." || return 1

	rm -f "${ERR_F}"

	{
		try_extract -stdout "${out_f}" |
		dnsmasq --test -C -
	} 2> "${ERR_F}"

	if [ ${?} != 0 ] || ! grep -q "syntax check OK" "${ERR_F}"
	then
		errors="$(head -n10 "${ERR_F}" | ${SED_CMD} '/^$/d')"
		rm -f "${ERR_F}" "${out_f}"
		reg_failure "dnsmasq test on the processed blocklist failed."
		log_msg "Errors:" "${errors:-"No specifics: probably killed because of OOM."}"
		return 2
	fi

	rm -f "${ERR_F}"

	reg_msg -green "Blocklist file check passed." ""

	eval "${cnt_out_var}"='${gen_cnt}'

	:
}

install_blocklists()
{
	local \
		dnsmasq_indexes \
		start_rv_inst \
		location \
		install_path \
		bl_path_ram \
		install_desc \
		some_succeeded \
		skip_load_stop \
		retry_blocklists_out_var="${1}" bl_instances="${2}"

	for bl_inst in ${bl_instances}
	do
		start_rv_inst=1
		eval \
			"persist_dir=\"\${PERSIST_DIR_${bl_inst}}\"" \
			"install_path=\"\${INSTALL_PATH_${bl_inst}}\"" \
			"bl_path_ram=\"\${INSTALL_PATH_RAM_${bl_inst}}\"" \
			"dnsmasq_indexes=\"\${DNSMASQ_INDEXES_${bl_inst}}\"" \
			"skip_load_stop=\"\${SKIP_LOAD_STOP_${bl_inst}}\""

		get_curr_bl_path ram_bl_file_curr "${bl_inst}" BL RAM &&
		get_curr_bl_path persist_bl_file_curr "${bl_inst}" BL RAM &&

		location=RAM
		[ "${install_path%/*}" = "$persist_dir" ] &&
			location=PERSIST install_desc=persistent

		assert_set F_start install_path dnsmasq_indexes || exit 1

		[ -n "${ram_bl_file_curr}" ] || rm_main_bl "${bl_inst}" "ram" # TODO: specify ram|persist to rm_main_bl

		[ -n "${skip_load_stop}" ] || stop_dnsmasq "${dnsmasq_indexes}" || exit 1

		if install_blocklist "${install_path}" "${install_desc}"
		then
			start_rv_inst=0
			some_succeeded=1
			add2list INSTALLED_INSTANCES "${bl_inst}"
		else
			reg_failure "Failed to install blocklist '${bl_inst}'"
			[ "$location" = "PERSIST" ] &&
			install_path=${bl_path_ram} &&
			[ -n "${install_path}" ] && [ -d "${install_path%/*}" ] || continue
			eval "INSTALL_PATH_${bl_inst}"='${install_path}'

			log_msg "Will try to generate a new blocklist."
			KEEP_PERSIST=0 stop -noexit # TODO
			add2list "${retry_blocklists_out_var}" "${bl_inst}" " "
		fi
		eval "START_RV_${bl_inst}"='${start_rv_inst}'
	done
	[ -n "${some_succeeded}" ]
}

# Args:
# 1: final blocklist path
# 2: blocklist size
# 3: entries count
# 4: description
install_blocklist()
{
	local me=install_blocklist \
		compr_ext final_extr_or_cat_stdout \
		cnt cnt_human md5 \
		dnsmasq_conf_dirs \
		conf_script_log_avail \
		inst_size_b inst_size_human compr_pr="uncompressed" compr_util dir errors \
		bl_file="${1}" desc="${2}" cnt="${3}" bl_inst="${4}" meta_location="${5}"

	eval "dnsmasq_conf_dirs=\"\${DNSMASQ_CONF_DIRS_${bl_inst}}\"" \
		"final_extr_or_cat_stdout=\"\${FINAL_EXTR_OR_CAT_STDOUT_${bl_inst}}\"" \
		"conf_script_log_avail=\"\${CONF_SCRIPT_LOG_${bl_inst}}\"" \
		"md5=\"BL_MD5_${meta_location}_${bl_inst}\""

	assert_set "F_${me}" bl_file desc cnt bl_inst dnsmasq_conf_dirs final_extr_or_cat_stdout || return 1

	reg_action -blue "Installing ${desc} blocklist file."

	int2human cnt_human "${cnt}" &&
	inst_size_b="$(get_file_size "${bl_file}")" &&
	bytes2human inst_size_human "${inst_size_b}" &&
	get_compr_spec compr_ext compr_util "${bl_file}" || return 1

	[ -n "${compr_ext}" ] && compr_pr="${compr_util}${compr_util:+"-"}compressed"

	for dir in ${dnsmasq_conf_dirs}
	do
		is_valid_dir "${dir}" || return 1

		cat <<-EOF | ${SED_CMD} -E 's/\s+/ /g' > "${dir}/abl-conf-script" ||
			conf-script= \
			${final_extr_or_cat_stdout} "${bl_file}" && \
			printf '%s\n' "address=/${md5}-${ABL_TEST_DOM_BASE}/#"; \
			${conf_script_log_avail:+"${LOG_CMD} -t adblock-lean-conf-script 'conf-script at '${dir}/abl-conf-script' failed.';"} \
			exit 0
		EOF
			{ reg_failure "Failed to create conf-script in directory '${dir}'."; return 1; }
	done

	:
}

# 1: src path
# 2: dst path
# 3: compression command with options
# 4: blocklist index
export_blocklist()
{
	local IFS="${DEFAULT_IFS}" exp_err \
		src_f="${1}" dst_f="${2}" compr_cmd="${3}" bl_inst="${4}"

	assert_set "F_export_blocklist" src_f dst_f ALL_CONF_DIRS &&
	reg_action -blue "" "Creating backup of current blocklist." &&
	mv_blocklist "${src_f}" "${dst_f}" "${compr_cmd}" "${bl_inst}" &&
	return 0

	reg_failure "${exp_err}${exp_err:+ }Failed to export blocklist '${src_f}' to '${dst_f}'."
	return 1
}

# 1 - src file
# 2 - dst file
restore_saved_blocklist()
{
	local me="restore_saved_blocklist" \
		src_f="${1}" dst_f="${2}" bl_inst="${3}"

	assert_set "F_${me}" src_f dst_f &&
	reg_action -1 "" "${blue}Restoring saved blocklist file: ${n_c}'${src_f}'." &&
	rm_conf_scripts &&
	rm_main_bl &&
	mv_blocklist "${src_f}" "${dst_f}" "${FINAL_COMPR_TO_FILE}" "${bl_inst}" &&
	install_blocklist "${dst_f}" "saved" &&
	return 0

	rm_conf_scripts
	rm_main_bl

	reg_failure "Failed to restore saved blocklist: '${src_f}'."
	BL_FILE_CURR=
	return 1
}

# TODO: Parallelize domains lookup
test_url_domains()
{
	local list lists list_author url mirror mirrors all_urls='' list_type list_format dom IFS="${DEFAULT_IFS}"
	for list_type in block ipv4_block allow
	do
		for list_format in ${ALL_LIST_FORMATS}
		do
			eval "lists=\"\${${list_format}_${list_type}_lists}\""
			[ -z "${lists}" ] && continue
			for list in ${lists}
			do
				case "${list}" in
					'') continue ;;
					hagezi:*|oisd:*|stevenblack:*)
						list_author="${list%%":"*}"
						eval "mirror=\"\${${list_author}_default_mirror}\""
						eval "url=\"\${${list_author}_${mirror}_url}\""
						[ -n "${url}" ] && all_urls="${all_urls:+"${all_urls}${_NL_}"}${url}" ;;
					*) all_urls="${all_urls:+"${all_urls}${_NL_}"}${list}"
				esac
			done
		done
	done

	[ -n "${all_urls}" ] || return 0

	reg_action -blue "Testing connectivity." || exit 1

	printf '%s\n' "${all_urls}" |
	${SED_CMD} -n '/http/{s~^http[s]*[:]*[/]*~~g;s~/.*~~;/^$/d;p;}' |
	${SORT_CMD} -u |
	while IFS="${_NL_}" read -r dom || [ -n "${dom}" ]
	do
		[ -n "${dom}" ] || continue
		try_lookup_domain "${dom}" "127.0.0.1" 2 || { reg_failure "Lookup of '${dom}' failed."; exit 1; }
	done || return 1
	:
}

# 1 - domain
# 2 - nameservers
# 3 - max attempts
# 4 - (optional) '-n': don't check if result is 127.0.0.1 or 0.0.0.0
try_lookup_domain()
{
	local ns_res ip lookup_ok='' i=0 IFS="${DEFAULT_IFS}"

	while :
	do
		for ip in ${2}
		do
			ns_res="$(${NSLOOKUP_CMD} "${1}" "${ip}" 2>/dev/null)" && { lookup_ok=1; break 2; }
		done
		i=$((i+1))
		[ "${i}" -ge "${3}" ] && break
		sleep 1
	done

	[ -n "${lookup_ok}" ] || return 2

	[ "${4}" = '-n' ] && return 0

	printf %s "${ns_res}" | grep -A1 ^Name | grep -qE '^Address: *(0\.0\.0\.0|127\.0\.0\.1)$' &&
		{ reg_failure "Lookup of '${1}' resulted in 0.0.0.0 or 127.0.0.1."; return 3; }
	:
}

:
