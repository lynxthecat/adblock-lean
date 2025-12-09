#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060,SC3057

# silence shellcheck warnings
: "${max_file_part_size_KB:=}" "${whitelist_mode:=}" "${list_part_failed_action:=}" "${test_domains:=}" \
	"${max_download_retries:=}" "${deduplication:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" \
	"${intermediate_compression_options:=}" "${final_compression_options:=}" \
	"${blue:=}" "${green:=}" "${n_c:=}"

PROCESSED_PARTS_DIR="${ABL_TMP_DIR}/list_parts"

SCHEDULE_DIR="${ABL_TMP_DIR}/schedule"

PROCESSING_TIMEOUT_S=900 # 15 minutes
IDLE_TIMEOUT_S=300 # 5 minutes

ABL_TEST_DOMAIN="adblocklean-test123.totallybogus"

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


# UTILITY FUNCTIONS

try_compress()
{
	${COMPR_CMD} ${2} "${1}" || { rm -f "${1}${COMPR_EXT}"; reg_failure "Failed to compress '${1}'."; return 1; }
}

try_extract()
{
	case "${1}" in
		*.gz)
			case "${EXTR_CMD}" in *gzip*|*pigz*) ;; *)
				local EXTR_CMD="gzip -fd"
			esac ;;
		*.zst)
			case "${EXTR_CMD}" in *zstd*) ;; *)
				local EXTR_CMD="zstd -fd --rm -q --no-progress"
			esac ;;
		*) reg_failure "try_extract: file '${1}' has unexpected extension."; false
	esac &&
	${EXTR_CMD} "${1}" || { rm -f "${1%.*}"; reg_failure "Failed to extract '${1}'."; return 1; }
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

# 1 - var name for output
get_uptime_s()
{
	local __uptime
	read -r __uptime _ < /proc/uptime &&
	__uptime="${__uptime%.*}" &&
	case "${__uptime}" in
		''|*[!0-9]*) false ;;
		*) :
	esac || { reg_failure "Failed to get uptime from /proc/uptime."; eval "${1}"=0; return 1; }
	eval "${1}"='${__uptime:-0}'
}

# To use, first get initial uptime: 'get_uptime_s INITIAL_UPTIME_S'
# Then call this function to get elapsed time string at desired intervals, e.g.:
# get_elapsed_time_s elapsed_time "${INITIAL_UPTIME_S}"
# 1 - var name for output
# 2 - initial uptime in seconds
get_elapsed_time_s()
{
	local ge_uptime_s
	get_uptime_s ge_uptime_s || return 1
	eval "${1}"=$(( ge_uptime_s-${2:-ge_uptime_s} ))
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

	are_var_names_safe "${out_var}" || return 1

	case "${list_format}" in raw|dnsmasq|hosts) ;; *) reg_failure "Unexpected list format '${list_format}'."; return 1; esac

	case "${list_id}" in
		*[A-Z]*) list_id_lc="$(printf '%s' "${list_id}" | tr 'A-Z' 'a-z')" ;;
		*) list_id_lc="${list_id}"
	esac
	case "${list_id_lc}" in hagezi:*|oisd:*|stevenblack:*) ;; *)
		eval "${out_var}=\"${list_id}\""
		return 0
	esac
	list_id="${list_id_lc}"

	eval "${out_var}=''"

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
	eval "${out_var}=\"${res_url}\""
}

check_confscript_support()
{
	dnsmasq --help | grep -qe "--conf-script" ||
	{
		reg_failure "The version of dnsmasq installed on this system is too old." \
			"To use adblock-lean, upgrade this system to OpenWrt 23.05 or later."
		return 1
	}
	:
}

# exports PROCESS_UTILS_SET COMPR_CMD COMPR_CMD_STDOUT COMPR_EXT EXTR_CMD EXTR_CMD_STDOUT
detect_processing_utils()
{
	[ -n "${PROCESS_UTILS_SET}" ] && return 0

	unset PROCESS_UTILS_SET COMPR_CMD COMPR_CMD_STDOUT COMPR_EXT EXTR_CMD EXTR_CMD_STDOUT

	local compr_cmd_opts='' compr_util_path='' extr_cmd_opts=''
	: "${compression_util:=gzip}"
	case "${compression_util}" in
		gzip)
			detect_util compr_util_path gzip "" "/usr/libexec/gzip-gnu" -b &&
			COMPR_EXT=.gz ;;
		pigz)
			detect_util compr_util_path "" pigz "/usr/bin/pigz" &&
			COMPR_EXT=.gz ;;
		zstd)
			detect_util compr_util_path "" zstd "/usr/bin/zstd" &&
			COMPR_EXT=.zst &&
			compr_cmd_opts="--rm -q --no-progress" &&
			extr_cmd_opts="--rm -q --no-progress" ;;
		none) : ;;
		*) reg_failure "Unexpected compression utility '${compression_util}'."; false
	esac || return 1

	[ "${compression_util}" != none ] &&
	{
		COMPR_CMD="${compr_util_path} -f ${compr_cmd_opts}"
		COMPR_CMD_STDOUT="${compr_util_path} -c"
		EXTR_CMD="${compr_util_path} -fd ${extr_cmd_opts}"
		EXTR_CMD_STDOUT="${compr_util_path} -cd"
	}
	export PROCESS_UTILS_SET=1 COMPR_CMD COMPR_CMD_STDOUT COMPR_EXT EXTR_CMD EXTR_CMD_STDOUT
}

# exports USE_COMPRESSION, FINAL_COMPRESS, FINAL_BLOCKLIST_FILE, PARALLEL_JOBS, INTERM_COMPR_OPTS,
#    FINAL_COMPR_OR_CAT, FINAL_COMPR_OPTS
set_processing_vars()
{
	local par_opt='' cpu_cnt compression_util="${compression_util:-gzip}" addnmounts_rv missing_addnmounts \
		please_run_setup="Please run 'service adblock-lean setup' to create the required addnmount entries."
	unset USE_COMPRESSION FINAL_COMPRESS PARALLEL_JOBS INTERM_COMPR_OPTS FINAL_COMPR_OPTS

	case "${MAX_PARALLEL_JOBS}" in
		auto)
			cpu_cnt="$(grep -c '^processor\s*:' /proc/cpuinfo)"
			case "${cpu_cnt}" in
				''|*[!0-9]*|0)
					log_msg "Failed to detect CPU core count. Parallel processing will be disabled."
					PARALLEL_JOBS=1 ;;
				*)
					# cap PARALLEL_JOBS to 4 in 'auto' mode
					PARALLEL_JOBS=$(( (cpu_cnt>4)*4 + (cpu_cnt<=4)*cpu_cnt ))
			esac ;;
		*)
			PARALLEL_JOBS="${MAX_PARALLEL_JOBS}"
	esac

	FINAL_COMPR_OR_CAT="/bin/busybox cat"
	FINAL_EXTR_OR_CAT="/bin/busybox cat"
	FINAL_BLOCKLIST_FILE="${SHARED_BLOCKLIST_PATH}"

	case "${compression_util}" in none) ;; *)
		USE_COMPRESSION=1

		# set compression parallelization, unless specified by the user
		case "${COMPR_CMD}" in *zstd*|*pigz*)
			case "${COMPR_CMD}" in
				*zstd*) par_opt=T ;;
				*pigz*) par_opt=p
			esac
			case "${intermediate_compression_options}" in
				*" -${par_opt}"*) INTERM_COMPR_OPTS="${intermediate_compression_options}" ;;
				*) INTERM_COMPR_OPTS="${intermediate_compression_options} -${par_opt}$((PARALLEL_JOBS/2 + (PARALLEL_JOBS/2<1) ))" # not less than 1
			esac
			case "${final_compression_options}" in
				*" -${par_opt}"*) FINAL_COMPR_OPTS="${final_compression_options}" ;;
				*) FINAL_COMPR_OPTS="${final_compression_options} -${par_opt}${PARALLEL_JOBS}"
			esac
		esac
	esac

	if [ -n "${USE_COMPRESSION}" ] || multi_inst_needed
	then
		check_confscript_support || return 1
		check_addnmounts missing_addnmounts
		addnmounts_rv=${?}

		[ -n "${missing_addnmounts}" ] && log_msg -warn "" "Missing addnmount entries in /etc/config/dhcp for paths: ${missing_addnmounts}"

		case ${addnmounts_rv} in
			0)
				if [ -n "${USE_COMPRESSION}" ]
				then
					FINAL_COMPRESS=1
					FINAL_COMPR_OR_CAT="${COMPR_CMD_STDOUT} ${FINAL_COMPR_OPTS}"
					FINAL_EXTR_OR_CAT="${EXTR_CMD_STDOUT}"
					FINAL_BLOCKLIST_FILE="${SHARED_BLOCKLIST_PATH}${COMPR_EXT}"
				fi ;;
			1) return 1 ;;
			2) ! multi_inst_needed && FINAL_BLOCKLIST_FILE="${DNSMASQ_CONF_DIRS%% *}/abl-blocklist" ;;
			3)
				multi_inst_needed &&
				{
					reg_failure "adblock-lean is configured to adblock on multiple dnsmasq instances but required addnmount entries are missing. ${please_run_setup}"
					return 1
				}
				FINAL_BLOCKLIST_FILE="${DNSMASQ_CONF_DIRS%% *}/abl-blocklist"
		esac

		case ${addnmounts_rv} in 2|3)
			[ -n "${USE_COMPRESSION}" ] && log_msg -warn "Final blocklist compression is disabled because of missing addnmount entries." \
				"${please_run_setup}"
		esac
	else
		FINAL_BLOCKLIST_FILE="${DNSMASQ_CONF_DIRS%% *}/abl-blocklist"
	fi

	export USE_COMPRESSION FINAL_COMPRESS FINAL_BLOCKLIST_FILE FINAL_COMPR_OR_CAT FINAL_EXTR_OR_CAT FINAL_COMPR_OPTS \
		INTERM_COMPR_OPTS PARALLEL_JOBS
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
	case "${__pid}" in ''|*[!0-9]*) reg_failure "Failed to get current job PID."; return 1; esac
	eval "${1}=\"${__pid}\""
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
	local ct_curr_time_s ct_total_time_s ct_remaining_time_s
	eval "${1}"=0

	get_uptime_s ct_curr_time_s || return 1
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
	process_list_part "${@}" &

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

	trap 'finalize_scheduler 1' USR1

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
				local list_size_human stats_pad suffix_pad msg1 msg2
				bytes2human list_size_human "${part_size_B}" -p
				get_pad stats_pad "${print_id}" 38
				get_pad suffix_pad "${line_count_human}" 8
				msg1="Successfully processed list:  "
				msg2="${stats_pad}[ ${list_size_human} - ${suffix_pad}${line_count_human} lines ]"
				print_msg "${msg1}${green}${print_id}${n_c} ${msg2}"
				reg_msg -noprint "${msg1}${print_id} ${msg2}" ;;
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
		index="${1}" list_type="${2}" list_format="${3}"

	get_curr_job_pid curr_job_pid || finalize_job 1

	for v in 1 2 3; do
		eval "[ -n \"\${${v}}\" ]" || finalize_job 1 "Missing argument ${v}."
	done

	eval "list_origin=\"\${${list_format}_${list_type}_${index}_origin}\""

	for v in list_origin print_id; do
		eval "[ -n \"\${${v}}\" ]" || finalize_job 1 "Missing param: '${v}'."
	done

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
		size_exceeded_file="${ABL_TMP_DIR}/size_exceeded_${job_id}" \
		part_line_count='' line_count_human min_line_count='' min_line_count_human \
		part_size_B='' retry=1 \
		part_compr_or_cat="cat" fetch_cmd \
		format_conv_or_cat="cat" \
		case_conv_or_cat="cat"

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
		[ -n "${USE_COMPRESSION}" ] &&
		{
			dest_file="${dest_file}${COMPR_EXT}"
			part_compr_or_cat="${COMPR_CMD_STDOUT} ${INTERM_COMPR_OPTS}"
		}
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

		rm -f "${rogue_el_file}" "${list_stats_file}" "${size_exceeded_file}" "${ucl_err_file}"

		msg="Processing ${list_format} ${list_type}list"
		get_pad pad "${msg}" 28

		print_msg "${msg}: ${pad}${blue}${print_id}${n_c}${msg_mirr}"
		reg_msg -noprint "${msg}: ${pad}${print_id}${msg_mirr}"

		# Download or cat the list
		${fetch_cmd} "${list_path}" |

		# Limit size
		{ head -c "${max_file_part_size_KB}k"; read -rn1 -d '' && { touch "${size_exceeded_file}"; cat 1>/dev/null; }; } |

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

		local lines_cnt_low='' dl_completed=''

		[ -f "${ucl_err_file}" ] && grep -q "Download completed" "${ucl_err_file}" && dl_completed=1

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

		read_str_from_file -v "part_line_count part_size_B _" -f "${list_stats_file}" -a 2 -D "list stats" || finalize_job 1
		if [ -f "${size_exceeded_file}" ]
		then
			reg_failure "Size of ${list_type}list part '${print_id}' reached the maximum value set in config (${max_file_part_size_KB} KB)."
			log_msg "Consider either increasing this value in the config or removing the corresponding ${list_type}list part path or URL from config."
			finalize_job 2
		fi

		int2human line_count_human "${part_line_count}"

		if [ "${list_origin}" = DL ] && [ "${part_line_count}" -lt "${min_line_count}" ]
		then
			lines_cnt_low=1
			int2human min_line_count_human "${min_line_count}"
			reg_failure "Line count in downloaded ${list_type}list part '${print_id}' is ${line_count_human}, which is less than configured minimum: ${min_line_count_human}."
		fi

		if [ "${list_origin}" = DL ] && { [ -z "${dl_completed}" ] || [ -n "${lines_cnt_low}" ]; }
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
	local lists schedule_req local_list_path list_format list_type \
		preprocessed_line_count=0 preprocessed_line_count_human \
		invalid_urls bad_hagezi_urls

	[ -n "${raw_block_lists}${dnsmasq_block_lists}${hosts_block_lists}" ] ||
		log_msg -yellow "" "NOTE: No URLs specified for blocklist download."

	# clean up before processing
	rm -rf "${PROCESSED_PARTS_DIR}" "${SCHEDULE_DIR}"

	local file list_line_count list_types
	try_mkdir -p "${SCHEDULE_DIR}" &&
	try_mkdir -p "${PROCESSED_PARTS_DIR}" || return 1

	if [ "${whitelist_mode}" = 1 ]
	then
		# allow test domains
		for d in ${test_domains}
		do
			printf '%s\n' "${d}" >> "${PROCESSED_PARTS_DIR}/allow"
			preprocessed_line_count=$((preprocessed_line_count+1))
		done
		use_allowlist=1
	fi

	reg_action -blue "Downloading and processing blocklist parts (max parallel jobs: ${PARALLEL_JOBS})."

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
			for file in "${PROCESSED_PARTS_DIR}/allow-"*
			do
				case "${file}" in ''|*"*") continue; esac
				cat "${file}" >> "${PROCESSED_PARTS_DIR}/allow" || { reg_failure "Failed to merge allowlist part."; return 1; }
				rm -f "${file}"
			done
		fi

		for list_type in ${list_types}
		do
			# count lines for current list type
			local file part_line_count=0 list_line_count=0
			for file in "${ABL_TMP_DIR}/stats_${list_type}-"*
			do
				case "${file}" in ''|*"*") continue; esac
				read_str_from_file -v "part_line_count _" -f "${file}" -a 1 -V 0 || return 1
				list_line_count=$((list_line_count+part_line_count))
			done

			if [ "${list_line_count}" = 0 ]
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
			preprocessed_line_count="$((preprocessed_line_count+list_line_count))"
		done
	done

	int2human preprocessed_line_count_human "${preprocessed_line_count}"
	reg_msg -green "" "Successfully generated preprocessed blocklist file with ${preprocessed_line_count_human} entries."
	:
}

gen_and_process_blocklist()
{
	convert_entries()
	{
		case "${AWK_CMD}" in
			*gawk) pack_entries_awk "$@" ;;
			*) pack_entries_sed "$@"
		esac
	}

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
		${AWK_CMD} -v ORS="" -v m=${len_lim} -v a="${allow_char}" -v t=${entry_type} '
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
	# 2 - <.gz|.zst|>
	# 3 - decompression command or 'cat'
	print_list_parts()
	{
		local find_name="${1}-*${2}" find_cmd="${3}"
		find "${PROCESSED_PARTS_DIR}/" -type f -name "${find_name}" -exec ${find_cmd} {} \; -exec rm -f {} \;
	}

	# 1 - var name for output
	# 2 - path to file
	read_list_stats()
	{
		read -r "${1?}" 2>/dev/null < "${2}"
		eval ": \"\${${1}:=0}\""
	}

	dedup()
	{
		if [ "${deduplication}" = 1 ]
		then
			${SORT_CMD} -u -
		else
			cat
		fi
	}

	local elapsed_time_s list_type out_f="${ABL_TMP_DIR}/processed-blocklist" \
		dnsmasq_err max_blocklist_file_size_B=$((max_blocklist_file_size_KB*1024)) \
		find_ext='' part_extr_or_cat="cat"

	[ -n "${USE_COMPRESSION}" ] && part_extr_or_cat="${EXTR_CMD_STDOUT}"

	if [ -n "${FINAL_COMPRESS}" ]
	then
		find_ext="${COMPR_EXT}"
		out_f="${out_f}${COMPR_EXT}"
	fi

	get_abl_run_state
	case ${?} in
		1) unload_blocklist_before_update=1 ;;
		3|4) unload_blocklist_before_update=0 ;;
	esac

	if [ "${unload_blocklist_before_update}" = auto ]
	then
		local totalmem
		read -r _ totalmem _ < /proc/meminfo
		case "${totalmem}" in
			''|*[!0-9]*) unload_blocklist_before_update=1 ;;
			*)
				if [ "${totalmem}" -ge 410000 ]
				then
					unload_blocklist_before_update=0
				else
					unload_blocklist_before_update=1
				fi
		esac
	fi

	if [ "${unload_blocklist_before_update}" != 1 ]
	then
		reg_action -nolog -blue "Testing connectivity." || exit 1
		test_url_domains || unload_blocklist_before_update=1
	fi

	if [ "${unload_blocklist_before_update}" = 1 ]
	then
		clean_dnsmasq_dir
		restart_dnsmasq || exit 1
	fi

	get_uptime_s INITIAL_UPTIME_S || return 1

	if ! gen_list_parts
	then
		reg_failure "Failed to generate preprocessed blocklist file with at least one entry."
		return 1
	fi

	reg_action -nolog -blue "Sorting and merging the blocklist parts into a single blocklist file." || return 1

	rm -f "${ABL_TMP_DIR}/dnsmasq_err"

	{
		# print blocklist parts
		print_list_parts block "${find_ext}" "${part_extr_or_cat}" |
		# optional deduplication
		dedup |
		# count entries
		tee >(wc -w > "${ABL_TMP_DIR}/block_entries") |
		# pack entries in 1024 characters long lines
		convert_entries block

		# print ipv4 blocklist parts
		if [ -n "${use_ipv4_blocklist}" ]
		then
			print_list_parts ipv4_block "${find_ext}" "${part_extr_or_cat}" |
			# optional deduplication
			dedup |
			tee >(wc -w > "${ABL_TMP_DIR}/ipv4_block_entries") |
			# add prefix
			${SED_CMD} 's/^/bogus-nxdomain=/'
		fi

		# print allowlist parts
		if [ -n "${use_allowlist}" ]
		then
			# optional deduplication
			dedup < "${PROCESSED_PARTS_DIR}/allow" |
			tee >(wc -w > "${ABL_TMP_DIR}/allow_entries") |
			# pack entries in 1024 characters long lines
			convert_entries allow
			rm -f "${PROCESSED_PARTS_DIR}/allow"
		fi

		# add the optional whitelist entry
		if [ "${whitelist_mode}" = 1 ]
		then
			# add block-everything entry: local=/*a/*b/*c/.../*z/
			printf 'local=/'
			${AWK_CMD} 'BEGIN{for (i=97; i<=122; i++) printf("*%c/",i);exit}'
			printf '\n'
		fi

		# add the blocklist test entry
		printf '%s\n' "address=/${ABL_TEST_DOMAIN}/#"
	} |

	# count bytes
	tee >(wc -c > "${ABL_TMP_DIR}/final_list_bytes") |

	# limit size
	{ head -c "${max_blocklist_file_size_B}"; read -rn1 -d '' && { touch "${ABL_TMP_DIR}/abl-too-big.tmp"; cat 1>/dev/null; }; } |

	# compress or cat
	${FINAL_COMPR_OR_CAT} > "${out_f}" ||
		{ reg_failure "Failed to write to output file '${out_f}'."; rm -f "${out_f}"; return 1; }

	if [ -f "${ABL_TMP_DIR}/abl-too-big.tmp" ]
	then
		rm -f "${out_f}"
		reg_failure "Final uncompressed blocklist exceeded ${max_blocklist_file_size_KB} kiB set in max_blocklist_file_size_KB config option!"
		log_msg "Consider either increasing this value in the config or changing the blocklist URLs."
		return 1
	fi

	reg_action -nolog -blue "Stopping dnsmasq." || return 1
	/etc/init.d/dnsmasq stop || { reg_failure "Failed to stop dnsmasq."; return 1; }

	# check the final blocklist with dnsmasq --test
	reg_action -nolog -blue "Checking the resulting blocklist with 'dnsmasq --test'." || return 1

	${FINAL_EXTR_OR_CAT} "${out_f}" |
	dnsmasq --test -C - 2> "${ABL_TMP_DIR}/dnsmasq_err"
	if [ ${?} != 0 ] || ! grep -q "syntax check OK" "${ABL_TMP_DIR}/dnsmasq_err"
	then
		dnsmasq_err="$(head -n10 "${ABL_TMP_DIR}/dnsmasq_err" | ${SED_CMD} '/^$/d')"
		rm -f "${out_f}" "${ABL_TMP_DIR}/dnsmasq_err"
		reg_failure "The dnsmasq test on the final blocklist failed."
		log_msg "dnsmasq --test errors:" "${dnsmasq_err:-"No specifics: probably killed because of OOM."}"
		return 2
	fi

	rm -f "${ABL_TMP_DIR}/dnsmasq_err"

	local block_entries_cnt ipv4_block_entries_cnt allow_entries_cnt final_list_size_B \
		final_entries_cnt final_entries_cnt_human final_list_size_human min_good_line_count_human

	for list_type in block ipv4_block allow
	do
		read_list_stats "${list_type}_entries_cnt" "${ABL_TMP_DIR}/${list_type}_entries"
	done

	final_entries_cnt=$(( block_entries_cnt + ipv4_block_entries_cnt + allow_entries_cnt ))
	int2human final_entries_cnt_human "${final_entries_cnt}"

	read_list_stats final_list_size_B "${ABL_TMP_DIR}/final_list_bytes"
	bytes2human final_list_size_human "${final_list_size_B}"

	if [ "${final_entries_cnt}" -lt "${min_good_line_count}" ]
	then
		int2human min_good_line_count_human "${min_good_line_count}"
		reg_failure "Entries count (${final_entries_cnt_human}) is below the minimum value set in config (${min_good_line_count_human})."
		return 1
	fi

	reg_msg -green "New blocklist file check passed."
	local msg="Final list uncompressed file size: "
	print_msg "${msg}${blue}${final_list_size_human}${n_c}"
	reg_msg -noprint "${msg}${final_list_size_human}"

	import_blocklist "${out_f}" "${FINAL_BLOCKLIST_FILE}" || return 1

	get_elapsed_time_s elapsed_time_s "${INITIAL_UPTIME_S}"
	reg_msg "" "Processing time for blocklist generation and import: $((elapsed_time_s/60))m:$((elapsed_time_s%60))s."

	if ! check_active_blocklist
	then
		reg_failure "Active blocklist check failed with the new blocklist."
		return 1
	fi

	reg_msg -green "" "Active blocklist check passed with the new blocklist."

	local msg="New blocklist installed with entries count: "
	print_msg -green "${msg}${blue}${final_entries_cnt_human}${n_c}"
	reg_success "${msg}${final_entries_cnt_human}"

	rm -f "${ABL_RUN_DIR}/prev_blocklist"*

	:
}

# return codes:
# 0 - success
# 1 - failure
# 2 - blocklist file not found (nothing to export)
export_blocklist()
{
	export_failed() {
		rm -f "${prev_file}" "${prev_file%.*}" "${prev_file}${COMPR_EXT}" "${bk_path}"
		reg_failure "Failed to export the blocklist."
	}

	reg_export() { reg_action -nolog -blue "Creating ${1} backup of existing blocklist." || return 1; }

	local bk_path="${ABL_RUN_DIR}/prev_blocklist" file prev_file='' prev_file_compat='' prev_file_compressed='' bk_exists=''
	[ -n "${USE_COMPRESSION}" ] && bk_path="${bk_path}${COMPR_EXT}"

	local dir IFS="${_NL_}"
	for dir in ${ALL_CONF_DIRS}
	do
		IFS="${DEFAULT_IFS}"
		rm -f "${dir}"/abl-conf-script "${dir}"/.abl-extract_blocklist
	done
	IFS="${DEFAULT_IFS}"

	if [ -f "${bk_path}" ]
	then
		reg_msg "" "Blocklist backup file already exists."
		bk_exists=1
	fi

	for src_d in "${ABL_RUN_DIR}" ${DNSMASQ_CONF_DIRS}
	do
		for file in "${src_d}/prev_blocklist"* "${src_d}/abl-blocklist"*
		do
			case "${file}" in ''|*"*") continue; esac

			# delete extra copies if any
			[ -n "${prev_file}" ] && { rm -f "${file}"; continue; }

			prev_file="${file}"
			case "${prev_file}" in *".gz"|*".zst") prev_file_compressed=1; esac
			if
				{ [ -n "${USE_COMPRESSION}" ] && case "${prev_file}" in *"${COMPR_EXT:-?}") : ;; *) false; esac; } ||
				{ [ -z "${USE_COMPRESSION}" ] && [ -z "${prev_file_compressed}" ]; }
			then
				prev_file_compat=1
			fi
		done
	done

	[ -n "${bk_exists}" ] && return 0

	[ -n "${prev_file}" ] || { log_msg "" "No existing blocklist found."; return 2; }

	if [ -n "${USE_COMPRESSION}" ]
	then
		reg_export compressed
	else
		reg_export uncompressed
	fi || return 1

	if [ -n "${prev_file_compressed}" ] && { [ -z "${prev_file_compat}" ] || [ -z "${USE_COMPRESSION}" ]; }
	then
		try_extract "${prev_file}" || { export_failed; return 1; }
		prev_file="${prev_file%.*}"
		prev_file_compressed=
	fi

	if [ -n "${USE_COMPRESSION}" ] && [ -z "${prev_file_compressed}" ]
	then
		try_compress "${prev_file}" "${FINAL_COMPR_OPTS}" || { export_failed; return 1; }
		prev_file="${prev_file}${COMPR_EXT}"
	fi

	try_mv "${prev_file}" "${bk_path}" || { export_failed; return 1; }
	:
}

restore_saved_blocklist()
{
	local file backup_file=''
	reg_action -blue "Restoring saved blocklist file." || return 1

	for file in "${ABL_RUN_DIR}/prev_blocklist"*
	do
		case "${file}" in ''|*"*") continue; esac
		[ -n "${backup_file}" ] && { rm -f "${file}"; continue; } # delete extra files if any
		backup_file="${file}"
	done

	[ -z "${backup_file}" ] && { reg_failure "No previous blocklist file found."; return 1; }

	import_blocklist "${backup_file}" ||
	{
		reg_failure "Failed to restore saved blocklist."
		return 1
	}

	:
}

import_blocklist()
{
	local dir
	try_import_blocklist "${@}" ||
	{
		rm -f "${1:-???}"
		for dir in ${DNSMASQ_CONF_DIRS}
		do
			rm -f "${dir}/abl-conf-script" "${dir}/.abl-extract_blocklist" "${dir}/abl-blocklist"
		done
		reg_failure "Failed to import the blocklist file '${1}'."
		return 1
	}
}

# 1 - file to import
try_import_blocklist()
{
	local dir src_compressed='' src_compat='' dest_compressed='' \
		src_file="${1}"

	reg_msg -blue "" "Importing the blocklist file."

	[ -n "${src_file}" ] || { reg_failure "import_blocklist: missing argument."; return 1; }
	[ -n "${FINAL_BLOCKLIST_FILE}" ] || { reg_failure "import_blocklist: \$FINAL_BLOCKLIST_FILE is not set."; return 1; }

	if [ -f "${src_file}" ]
	then
		case "${src_file}" in *.gz|*.zst) src_compressed=1; esac
		case "${src_file}" in *"${COMPR_EXT}") src_compat=1; esac
	else
		reg_failure "import_blocklist: file '${src_file}' not found."
		return 1
	fi

	clean_dnsmasq_dir

	if [ -n "${src_compressed}" ] && { [ -z "${src_compat}" ] || [ -z "${FINAL_COMPRESS}" ]; }
	then
		try_extract "${src_file}" || return 1
		src_file="${src_file%.*}"
		src_compressed=''
	fi

	if [ -z "${src_compressed}" ] && [ -n "${FINAL_COMPRESS}" ]
	then
		try_compress "${src_file}" "${FINAL_COMPR_OPTS}" || return 1
		src_file="${src_file}${COMPR_EXT}"
	fi

	[ "${src_file}" = "${FINAL_BLOCKLIST_FILE}" ] || try_mv "${src_file}" "${FINAL_BLOCKLIST_FILE}" || return 1

	if [ -n "${FINAL_COMPRESS}" ] || multi_inst_needed
	then
		for dir in ${DNSMASQ_CONF_DIRS}
		do
			printf '%s\n' "conf-script=\"busybox sh ${dir}/.abl-extract_blocklist\"" > "${dir}/abl-conf-script" &&
			printf '%s\n%s\n' "${FINAL_EXTR_OR_CAT} \"${FINAL_BLOCKLIST_FILE}\"" "exit 0" > "${dir}/.abl-extract_blocklist" ||
				{ reg_failure "Failed to create conf-script in directory '${dir}'."; return 1; }
		done
	fi

	restart_dnsmasq || return 1

	[ -n "${FINAL_COMPRESS}" ] && dest_compressed="compressed "

	local final_size msg
	final_size=$(get_file_size_human "${FINAL_BLOCKLIST_FILE}")
	msg="Successfully imported new ${dest_compressed}blocklist file for use by dnsmasq with size: "
	print_msg "${msg}${blue}${final_size}${n_c}"
	reg_msg -noprint "${msg}${final_size}"

	:
}

# Get nameservers for dnsmasq instance
# Output via global vars: NS_4_${index}, NS_6_${index}
# 1 - instance index
get_dnsmasq_instance_ns()
{
	local family ip_regex iface line instance_ns instance_ifaces ip ip_tmp \
		ip_regex_4='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])' \
		ip_regex_6='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}' \
		index="${1}"
	: "${ip_regex_4}" "${ip_regex_6}"

	for family in 4 6
	do
		eval "ip_regex=\"\${ip_regex_${family}}\""
		eval "instance_ifaces=\"\${IFACES_${index}}\""
		instance_ns="$(
			ip -o -${family} addr show | ${SED_CMD} -nE '/^\s*[0-9]+:\s*/{s/^\s*[0-9]+\s*:\s+//;s/scope .*//;s/\s+/ /g;p;}' |
			while read -r line
			do
				iface="${line%% *}"
				[ -n "${iface}" ] &&
				is_included "${iface}" "${instance_ifaces}" ", " || continue
				ip_tmp="${line##*inet"${family#4}" }"
				ip="${ip_tmp%%/*}"
				[ -n "${ip}" ] && printf '%s\n' "${ip}"
			done | grep -E "^${ip_regex}$"
		)"
		eval "NS_${family}_${index}=\"${instance_ns}\""
	done
	:
}

# return values:
# 0 - dnsmasq is running, and all checks passed
# 1 - dnsmasq is not running
# 2 - dnsmasq is running, but one of the test domains failed to resolve
# 3 - dnsmasq is running, but one of the test domains resolved to 0.0.0.0
# 4 - dnsmasq is running, but the blocklist test domain failed to resolve (blocklist not loaded)
check_active_blocklist()
{
	reg_action -nolog -blue "Checking the active blocklist." || return 1

	local family ip index instance_ns def_ns ns_ips ns_ips_sp

	check_dnsmasq_instances || return 1

	for index in ${DNSMASQ_INDEXES}
	do
		ns_ips='' ns_ips_sp=''
		get_dnsmasq_instance_ns "${index}"

		for family in 4 6
		do
			case "${family}" in
				4) def_ns=127.0.0.1 ;;
				6) def_ns=::1
			esac
			eval "instance_ns=\"\${NS_${family}_${index}}\""
			for ip in ${instance_ns:-"${def_ns}"}
			do
				add2list ns_ips "${ip}"
				add2list ns_ips_sp "${ip}" ", "
			done
		done

		reg_msg "" "Using following nameservers for DNS resolution verification: ${ns_ips_sp}"
		reg_msg -blue "Testing adblocking."

		try_lookup_domain "${ABL_TEST_DOMAIN}" "${ns_ips}" 15 -n ||
			{ reg_failure "Lookup of test domain '${ABL_TEST_DOMAIN}' failed with the new blocklist."; return 4; }

		reg_msg -blue "Testing DNS resolution."
		for domain in ${test_domains}
		do
			try_lookup_domain "${domain}" "${ns_ips}" 5 ||
				{ reg_failure "Lookup of test domain '${domain}' failed with the new blocklist."; return 1; }
		done
	done

	:
}

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
			ns_res="$(nslookup "${1}" "${ip}" 2>/dev/null)" && { lookup_ok=1; break 2; }
		done
		i=$((i+1))
		[ "${i}" -gt "${3}" ] && break
		sleep 1
	done

	[ -n "${lookup_ok}" ] || return 2

	[ "${4}" = '-n' ] && return 0

	printf %s "${ns_res}" | grep -A1 ^Name | grep -qE '^(Address: *0\.0\.0\.0|Address: *127\.0\.0\.1)$' &&
		{ reg_failure "Lookup of '${1}' resulted in 0.0.0.0 or 127.0.0.1."; return 3; }
	:
}

get_active_entries_cnt()
{
	local cnt

	# ipv4_block prefix doesn't need to be added for counting
	cnt="$(
		if [ -n "${COMPR_EXT}" ] && [ -f "${SHARED_BLOCKLIST_PATH}${COMPR_EXT}" ]
		then
			${EXTR_CMD_STDOUT} "${SHARED_BLOCKLIST_PATH}${COMPR_EXT}"
		elif ! multi_inst_needed && [ -f "${DNSMASQ_CONF_DIRS}/abl-blocklist" ]
		then
			cat "${DNSMASQ_CONF_DIRS}/abl-blocklist"
		else
			rm -f "${SHARED_BLOCKLIST_PATH:-?}"*
			printf ''
		fi |
		${SED_CMD} -E "s~^(server|local)=/~~;/${ABL_TEST_DOMAIN}/d;s~/#{0,1}$~~" | tr '/' '\n' | wc -w
	)"

	: "${cnt:=0}"
	[ "${whitelist_mode}" = 1 ] && cnt=$((cnt-26)) # ignore alphabet entries

	case "${cnt}" in *[!0-9]*|'') printf 0; return 1; esac
	printf %s "${cnt}"
	:
}

:
