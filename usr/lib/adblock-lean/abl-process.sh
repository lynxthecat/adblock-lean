#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060

# silence shellcheck warnings
: "${max_file_part_size_KB:=}" "${whitelist_mode:=}" "${list_part_failed_action:=}" "${test_domains:=}" \
	"${max_download_retries:=}" "${deduplication:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" "${local_allowlist_path:=}" \
	"${intermediate_compression_options:=}" "${final_compression_options:=}" \
	"${blue:=}" "${green:=}" "${n_c:=}"

PROCESSED_PARTS_DIR="${ABL_TMP_DIR}/list_parts"

SCHEDULE_DIR="${ABL_TMP_DIR}/schedule"

PROCESSING_TIMEOUT_S=900 # 15 minutes
IDLE_TIMEOUT_S=300 # 5 minutes

ABL_TEST_DOMAIN="adblocklean-test123.totallybogus"

OISD_DL_URL="oisd.nl/domainswild2"
HAGEZI_DL_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard"
OISD_LISTS="big small nsfw nsfw-small"
HAGEZI_LISTS="anti.piracy blocklist-referral doh doh-vpn-proxy-bypass dyndns fake gambling gambling.medium gambling.mini hoster \
light multi native.amazon native.apple native.huawei native.lgwebos native.oppo-realme native.roku native.samsung \
native.tiktok native.tiktok.extended native.vivo native.winoffice native.xiaomi nosafesearch nsfw popupads \
pro pro.mini pro.plus pro.plus.mini tif tif.medium tif.mini ultimate ultimate.mini urlshortener whitelist-referral"


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
	case "${2}" in '') unset "${sab_out}"; return 0; esac
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
	[ -n "${compression_util}" ] || { reg_failure "detect_processing_utils: \$compression_util is not set."; return 1; }
	[ -n "${PROCESS_UTILS_SET}" ] && return 0

	unset PROCESS_UTILS_SET COMPR_CMD COMPR_CMD_STDOUT COMPR_EXT EXTR_CMD EXTR_CMD_STDOUT

	local compr_cmd_opts='' compr_util_path='' extr_cmd_opts=''
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
	[ -n "${compression_util}" ]  || { reg_failure "set_processing_vars: \$compression_util is not set."; return 1; }

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

# 1 - var name for output
# 2 - list identifier in the form [hagezi|oisd]:[list_name]
get_list_url()
{
	local res_url out_var="${1}" list_id="${2}" list_author list_name lists=''

	are_var_names_safe "${out_var}" || return 1
	eval "${out_var}=''"
	case "${list_id}" in *:*) ;; *) reg_failure "Invalid list identifier '${list_id}'."; return 1; esac
	case "${list_id}" in *[A-Z]*) list_id="$(printf '%s' "${list_id}" | tr 'A-Z' 'a-z')"; esac
	list_author="${list_id%%\:*}" list_name="${list_id#*\:}"
	case "${list_author}" in
		hagezi) lists="${HAGEZI_LISTS}" res_url="${HAGEZI_DL_URL}/${list_name}-onlydomains.txt" ;;
		oisd) lists="${OISD_LISTS}" res_url="https://${list_name}.${OISD_DL_URL}" ;;
		*) reg_failure "Unknown list '${2}'."; return 1
	esac
	is_included "${list_name}" "${lists}" " " || { reg_failure "Unknown ${list_author} list '${2}'."; return 1; }

	: "${res_url}"
	eval "${out_var}=\"\${res_url}\""
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
	local fatal_pid="${1}" fatal_path="${2}"
	if [ -n "${fatal_pid}" ]
	then
		: "${fatal_path:=unknown}"
		reg_failure "Processing job (PID: ${fatal_pid}) for list '${fatal_path}' reported fatal error."
	else
		reg_failure "Fatal error reported by unknown processing job."
	fi

	[ -n "${SCHEDULER_PID}" ] && [ -d "/proc/${SCHEDULER_PID}" ] && kill -s USR1 "${SCHEDULER_PID}"

	exit 1
}

# 1 - job PID
# 2 - job return code
handle_done_job()
{
	local done_pid="${1}" done_job_rv="${2}" done_path me=handle_done_job
	[ -n "${done_pid}" ] || { reg_failure "${me}: received empty string for PID."; return 1; }
	[ -n "${done_job_rv}" ] || { reg_failure "${me}: received empty string instead of return code for job ${done_pid}."; return 1; }

	subtract_a_from_b "${done_pid}" "${RUNNING_PIDS}" RUNNING_PIDS " "
	RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT-1))

	if [ "${done_job_rv}" != 0 ]
	then
		eval "done_path=\"\${JOB_URL_${done_pid}}\""

		reg_failure "Processing job (PID ${done_pid}) for list '${done_path}' returned error code '${done_job_rv}'."
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
# 3 - list type (blocklist|blocklist_ipv4|allowlist)
# 4 - list format (raw|dnsmasq)
# the rest of the args passed as-is to workers
schedule_job()
{
	local list_origin="${1}" list_path="${2}" list_type="${3}" list_format="${4}"

	# wait for job vacancy
	local remaining_time_s done_pid done_rv
	get_remaining_time remaining_time_s || return 1

	while [ "${RUNNING_JOBS_CNT}" -ge "${PARALLEL_JOBS}" ] && [ -e "${SCHED_CB_FIFO}" ] &&
		read -t "${remaining_time_s}" -r done_pid done_rv < "${SCHED_CB_FIFO}"
	do
		get_remaining_time remaining_time_s || return 1
		handle_done_job "${done_pid}" "${done_rv}" || return 1
	done
	get_remaining_time remaining_time_s || return 1

	RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT+1))
	process_list_part "${@}" &

	RUNNING_PIDS="${RUNNING_PIDS}${!} "

	:
}

# 1 - list types (allowlist|blocklist|blocklist_ipv4)
schedule_jobs()
{
	finalize_scheduler()
	{
		trap ':' USR1
		[ "${1}" != 0 ] && [ -n "${RUNNING_PIDS}" ] &&
		{
			log_msg "" "Stopping unfinished jobs (PIDS: ${RUNNING_PIDS})."
			kill_pids_recursive "${RUNNING_PIDS}"
			rm -rf "${PROCESSED_PARTS_DIR}" 2>/dev/null
		}
		rm -f "${SCHED_CB_FIFO}"
		exit "${1}"
	}

	local list_type list_types="${1}" list_format list_url SCHEDULER_PID
	get_curr_job_pid SCHEDULER_PID || finalize_scheduler 1

	RUNNING_PIDS=
	RUNNING_JOBS_CNT=0

	trap 'finalize_scheduler 1' USR1

	local SCHED_CB_FIFO="${SCHEDULE_DIR}/scheduler_callback_${SCHEDULER_PID}"
	mkfifo "${SCHED_CB_FIFO}" &&
	exec 3<>"${SCHED_CB_FIFO}" || { reg_failure "Failed to create FIFO '${SCHED_CB_FIFO}'."; finalize_scheduler 1; }

	for list_type in ${list_types}
	do
		for list_format in raw dnsmasq
		do
			local list_urls invalid_urls='' bad_hagezi_urls='' d=''
			[ "${list_format}" = dnsmasq ] && d="dnsmasq_"

			eval "list_urls=\"\${${d}${list_type}_urls}\""
			[ -z "${list_urls}" ] && continue

			log_msg -blue "" "Starting ${list_format} ${list_type} part(s) download."

			invalid_urls="$(printf %s "${list_urls}" | tr ' ' '\n' | grep -E '^(http[s]*://)*(www\.)*github\.com')" &&
				log_msg -warn "" "Invalid URLs detected:" "${invalid_urls}"

			if [ "${list_format}" = raw ]
			then
				bad_hagezi_urls="$(printf %s "${list_urls}" | tr ' ' '\n' | grep '/hagezi/.*/dnsmasq/')" &&
				log_msg -warn "" "Following Hagezi URLs are in dnsmasq format and should be either changed to raw list URLs" \
					"or moved to one of the 'dnsmasq_' config entries:" "${bad_hagezi_urls}"
				case "${list_type}" in blocklist|allowlist)
					bad_hagezi_urls="$(printf %s "${list_urls}" | tr ' ' '\n' | ${SED_CMD} -n '/^hagezi:/n;/\/hagezi\//{/onlydomains\./d;/^$/d;p;}')"
					[ -n "${bad_hagezi_urls}" ] && log_msg -warn "" \
						"Following Hagezi URLs are missing the '-onlydomains' suffix in the filename:" "${bad_hagezi_urls}"
				esac
			fi

			for list_url in ${list_urls}
			do
				case "${list_url}" in
					hagezi:*|oisd:*)
						local short_id="${list_url}"
						if ! get_list_url list_url "${short_id}"
						then
							[ "${list_part_failed_action}" = "STOP" ] &&
								{ log_msg "list_part_failed_action is set to 'STOP', exiting."; finalize_scheduler 1; }
							log_msg -yellow "Skipping list '${short_id}' and continuing."
							continue
						fi
				esac
				part_line_count=0
				schedule_job DL "${list_url}" "${list_type}" "${list_format}" || finalize_scheduler 1
				export "JOB_URL_${!}"="${list_url}"
			done
		done

		# schedule local jobs
		if [ "${list_type}" != blocklist_ipv4 ]
		then
			local local_list_path
			eval "local_list_path=\"\${local_${list_type}_path}\""
			if [ ! -f "${local_list_path}" ]
			then
				log_msg "No local ${list_type} identified."
			elif [ ! -s "${local_list_path}" ]
			then
				log_msg -warn "" "Local ${list_type} file is empty."
			else
				schedule_job LOCAL "${local_list_path}" "${list_type}" raw || finalize_scheduler 1
				export "JOB_URL_${!}"="${local_list_path}"
			fi
		fi
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

# 1 - list origin (DL|LOCAL)
# 2 - list URL or local path
# 3 - list type (blocklist|blocklist_ipv4|allowlist)
# 4 - list format (raw|dnsmasq)
# the rest of the args passed as-is to workers
#
# return codes:
# 0 - Success
# 1 - Fatal error (stop processing)
# 2 - Download failure
# 3 - Processing failure
process_list_part()
{
	finalize_job()
	{
		[ -n "${2}" ] && reg_failure "process_list_part: ${2}"
		case "${1}" in
			0)
				local list_size_human
				list_size_human="$(bytes2human "${part_size_B}")"
				print_msg -green "Successfully processed list: ${blue}${list_path}${n_c} (${line_count_human} lines, ${list_size_human})."
				log_msg -noprint "Successfully processed list: ${list_path} (${line_count_human} lines, ${list_size_human})." ;;
			*)
				rm -f "${dest_file}" "${list_stats_file}"
				[ "${1}" = 1 ] && handle_fatal "${curr_job_pid}" "${list_path}"
		esac

		printf '%s\n' "${curr_job_pid} ${1}" > "${SCHED_CB_FIFO}"
		exit "${1}"
	}

	# shellcheck disable=SC2317
	dl_list()
	{
		uclient-fetch "${1}" -O- --timeout=3 2> "${ucl_err_file}"
	}

	local list_origin="${1}" list_path="${2}" list_type="${3}" list_format="${4}" curr_job_pid

	get_curr_job_pid curr_job_pid || finalize_job 1

	for v in 1 2 3 4; do
		eval "[ -z \"\${${v}}\" ]" && finalize_job 1 "Missing argument ${v}."
	done

	case "${list_type}" in
		allowlist|blocklist) val_entry_regex='^[[:alnum:]-]+$|^(\*|[[:alnum:]_-]+)([.][[:alnum:]_-]+)+$' ;;
		blocklist_ipv4) val_entry_regex='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$' ;;
		*) finalize_job 1 "Invalid list type '${list_type}'"
	esac

	local list_id="${list_type}-${list_origin}-${list_format}"
	local job_id="${list_id}-${curr_job_pid}"
	local dest_file="${PROCESSED_PARTS_DIR}/${job_id}" \
		ucl_err_file="${ABL_TMP_DIR}/ucl_err_${job_id}" \
		rogue_el_file="${ABL_TMP_DIR}/rogue_el_${job_id}" \
		list_stats_file="${ABL_TMP_DIR}/stats_${job_id}" \
		size_exceeded_file="${ABL_TMP_DIR}/size_exceeded_${job_id}" \
		part_line_count='' line_count_human min_line_count='' min_line_count_human \
		part_size_B='' retry=1 \
		part_compr_or_cat="cat" fetch_cmd

	case "${list_origin}" in
		DL) fetch_cmd=dl_list ;;
		LOCAL) fetch_cmd="cat" ;;
		*) reg_failure "Invalid list origin '${list_origin}'."; finalize_job 1
	esac

	case ${list_type} in blocklist|blocklist_ipv4)
		[ -n "${USE_COMPRESSION}" ] &&
		{
			dest_file="${dest_file}${COMPR_EXT}"
			part_compr_or_cat="${COMPR_CMD_STDOUT} ${INTERM_COMPR_OPTS}"
		}
	esac
	eval "min_line_count=\"\${min_${list_type}_part_line_count}\""

	while :
	do
		rm -f "${rogue_el_file}" "${list_stats_file}" "${size_exceeded_file}" "${ucl_err_file}"

		print_msg "Processing ${list_format} ${list_type}: ${blue}${list_path}${n_c}"
		log_msg -noprint "Processing ${list_format} ${list_type}: ${list_path}"

		# Download or cat the list
		local lines_cnt_low='' dl_completed=''

		${fetch_cmd} "${list_path}" |
		# limit size
		{ head -c "${max_file_part_size_KB}k"; read -rn1 -d '' && { touch "${size_exceeded_file}"; cat 1>/dev/null; }; } |

		# Remove comment lines and trailing comments, remove whitespaces
		${SED_CMD} 's/#.*$//; s/^[ \t]*//; s/[ \t]*$//; /^$/d' |

		# Convert dnsmasq format to raw format
		if [ "${list_format}" = dnsmasq ]
		then
			local rm_prefix_expr="s~^[ \t]*(local|server|address)=/~~" rm_suffix_expr=''
			case "${list_type}" in
				blocklist) rm_suffix_expr='s~/$~~' ;;
				blocklist_ipv4) rm_prefix_expr="s~^[ \t]*bogus-nxdomain=~~" ;;
				allowlist) rm_suffix_expr='s~/#$~~'
			esac
			${SED_CMD} -E "${rm_prefix_expr};${rm_suffix_expr}" | tr '/' '\n'
		else
			cat
		fi |

		# Count bytes and entries
		tee >(wc -wc > "${list_stats_file}") |

		# Convert to lowercase
		case "${list_type}" in allowlist|blocklist) tr 'A-Z' 'a-z' ;; *) cat; esac |

		if [ "${list_type}" = blocklist ] && [ "${use_allowlist}" = 1 ]
		then
			case "${whitelist_mode}" in
			0)
				# remove allowlist domains from blocklist
				${AWK_CMD} 'NR==FNR { if ($0 ~ /^\*\./) { allow_wild[substr($0,3)]; next }; allow[$0]; next }
					{ n=split($1,arr,"."); addr = arr[n]; for ( i=n-1; i>=1; i-- )
					{ addr = arr[i] "." addr; if ( (i>1 && addr in allow_wild) || addr in allow ) next } } 1' "${PROCESSED_PARTS_DIR}/allowlist" - ;;
			1)
				# only print subdomains of allowlist domains
				${AWK_CMD} 'NR==FNR { if ($0 !~ /^\*/) { allow[$0] }; next } { n=split($1,arr,"."); addr = arr[n];
					for ( i=n-1; i>1; i-- ) { addr = arr[i] "." addr; if ( addr in allow ) { print $1; next } } }' "${PROCESSED_PARTS_DIR}/allowlist" -
			esac
		else
			cat
		fi |

		# check lists for rogue elements
		tee >(${SED_CMD} -nE "/${val_entry_regex}/d;p;:1 n;b1" > "${rogue_el_file}") |

		# compress or cat
		${part_compr_or_cat} > "${dest_file}"

		read_str_from_file -v "part_line_count part_size_B _" -f "${list_stats_file}" -a 2 -D "list stats" || finalize_job 1
		if [ -f "${size_exceeded_file}" ]
		then
			reg_failure "Size of ${list_type} part from '${list_path}' reached the maximum value set in config (${max_file_part_size_KB} KB)."
			log_msg "Consider either increasing this value in the config or removing the corresponding ${list_type} part path or URL from config."
			finalize_job 2
		fi

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
					log_msg -warn "${list_type} file from '${list_path}' contains Windows-format (CR LF) newlines." \
						"This file needs to be converted to Unix newline format (LF)." ;;
				*) log_msg -warn "${rogue_el_print} identified in ${list_type} file from: ${list_path}."
			esac
			finalize_job 3
		fi

		int2human line_count_human "${part_line_count}"

		if [ "${list_origin}" = DL ] && [ "${part_line_count}" -lt "${min_line_count}" ]
		then
			lines_cnt_low=1
			int2human min_line_count_human "${min_line_count}"
			reg_failure "Line count in downloaded ${list_type} part from '${list_path}' is ${line_count_human}, which is less than configured minimum: ${min_line_count_human}."
		fi

		if [ "${list_origin}" = DL ] && { [ -z "${dl_completed}" ] || [ -n "${lines_cnt_low}" ]; }
		then
			reg_failure "Failed download attempt for URL '${list_url}'."
			[ -s "${ucl_err_file}" ] && log_msg "uclient-fetch output: ${_NL_}'$(cat "${ucl_err_file}")'."
			rm -f "${ucl_err_file}"
		else
			rm -f "${ucl_err_file}"
			finalize_job 0
		fi

		retry=$((retry + 1))
		if [ "${retry}" -gt "${max_download_retries}" ]
		then
			finalize_job 2 "${max_download_retries} download attempts failed for URL '${list_url}'."
		fi

		log_msg -yellow "" "Processing job for URL '${list_url}' is sleeping for 5 seconds after failed download attempt."
		sleep 5 &
		local sleep_pid=${!}
		wait ${sleep_pid}
	done
}

gen_list_parts()
{
	local list_type preprocessed_line_count=0 preprocessed_line_count_human

	[ -z "${blocklist_urls}${dnsmasq_blocklist_urls}" ] && log_msg -yellow "" "NOTE: No URLs specified for blocklist download."

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
			printf '%s\n' "${d}" >> "${PROCESSED_PARTS_DIR}/allowlist"
			preprocessed_line_count=$((preprocessed_line_count+1))
		done
		use_allowlist=1
	fi

	reg_action -blue "Downloading and processing blocklist parts (max parallel jobs: ${PARALLEL_JOBS})."
	print_msg ""

	# Asynchronously download and process parts, allowlist must be processed separately and first
	for list_types in allowlist "blocklist blocklist_ipv4"
	do
		local schedule_req=''
		for list_type in ${list_types}
		do
			eval "list_urls=\"\${${list_type}_urls}\""
			if eval "[ -n \"\${${list_type}_urls}\${dnsmasq_${list_type}_urls}\" ]"
			then
				schedule_req=1
			fi
			if eval "[ -f \"\${local_${list_type}_path}\" ]"
			then
				schedule_req=1
			fi
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

		if [ "${list_types}" = allowlist ]
		then
			# consolidate allowlist parts into one file
			for file in "${PROCESSED_PARTS_DIR}/allowlist-"*
			do
				[ -e "${file}" ] || break
				cat "${file}" >> "${PROCESSED_PARTS_DIR}/allowlist" || { reg_failure "Failed to merge allowlist part."; return 1; }
				rm -f "${file}"
			done
		fi

		for list_type in ${list_types}
		do
			# count lines for current list type
			local file part_line_count=0 list_line_count=0
			for file in "${ABL_TMP_DIR}/stats_${list_type}-"*
			do
				[ -e "${file}" ] || break
				read_str_from_file -v "part_line_count _" -f "${file}" -a 1 -V 0 || return 1
				list_line_count=$((list_line_count+part_line_count))
			done

			if [ "${list_line_count}" = 0 ]
			then
				case "${list_type}" in
					blocklist)
						[ "${whitelist_mode}" = 0 ] && return 1
						log_msg -yellow "Whitelist mode is on - accepting empty blocklist." ;;
					allowlist)
						log_msg "Not using any allowlist for blocklist processing."
				esac
			elif [ "${list_type}" = blocklist_ipv4 ]
			then
				use_blocklist_ipv4=1
			elif [ "${list_type}" = allowlist ]
			then
				log_msg "Will remove any (sub)domain matches present in the allowlist from the blocklist and append corresponding server entries to the blocklist."
				use_allowlist=1
			fi
			preprocessed_line_count="$((preprocessed_line_count+list_line_count))"
		done
	done

	int2human preprocessed_line_count_human "${preprocessed_line_count}"
	log_msg -green "" "Successfully generated preprocessed blocklist file with ${preprocessed_line_count_human} entries."
	:
}

gen_and_process_blocklist()
{
	convert_entries()
	{
		if [ "${AWK_CMD}" = gawk ]
		then
			pack_entries_awk "$@"
		else
			pack_entries_sed "$@"
		fi
	}

	# convert to dnsmasq format and pack 4 input lines into 1 output line
	# intput from STDIN, output to STDOUT
	# 1 - blocklist|allowlist
	pack_entries_sed()
	{
		case "$1" in
			blocklist)
				# packs 4 domains in one 'local=/.../' line
				${SED_CMD} "/^$/d;s~^.*$~local=/&/~;\$!{n;a /${_NL_}};\$!{n;a /${_NL_}};\$!{n; a /${_NL_}};a @" ;;
			allowlist)
				# packs 4 domains in one 'server=/.../#'' line
				{ cat; printf '\n'; } | ${SED_CMD} '/^$/d;$!N;$!N;$!N;s~\n~/~g;s~^~server=/~;s~/*$~/#@~' ;;
			*) printf ''; return 1
		esac | tr -d '\n' | tr "@" '\n'
	}

	# convert to dnsmasq format and pack input lines into 1024 characters-long lines
	# intput from STDIN, output to STDOUT
	# 1 - blocklist|allowlist
	pack_entries_awk()
	{
		local entry_type len_lim=1024 allow_char=''
		case "$1" in
			blocklist) entry_type=local ;;
			allowlist) entry_type=server allow_char="#" ;;
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

	# 1 - list type (blocklist|blocklist_ipv4)
	# 2 - <.gz|.zst|>
	# 3 - decompression command or 'cat'
	print_list_parts()
	{
		local find_name="${1}-*${2}" find_cmd="${3}"
		find "${ABL_TMP_DIR}/list_parts/" -type f -name "${find_name}" -exec ${find_cmd} {} \; -exec rm -f {} \;
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
		reg_action -blue "Testing connectivity." || exit 1
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

	reg_action -blue "Sorting and merging the blocklist parts into a single blocklist file." || return 1

	rm -f "${ABL_TMP_DIR}/dnsmasq_err"

	{
		# print blocklist parts
		print_list_parts blocklist "${find_ext}" "${part_extr_or_cat}" |
		# optional deduplication
		dedup |
		# count entries
		tee >(wc -w > "${ABL_TMP_DIR}/blocklist_entries") |
		# pack entries in 1024 characters long lines
		convert_entries blocklist

		# print ipv4 blocklist parts
		if [ -n "${use_blocklist_ipv4}" ]
		then
			print_list_parts blocklist_ipv4 "${find_ext}" "${part_extr_or_cat}" |
			# optional deduplication
			dedup |
			tee >(wc -w > "${ABL_TMP_DIR}/blocklist_ipv4_entries") |
			# add prefix
			${SED_CMD} 's/^/bogus-nxdomain=/'
		fi

		# print allowlist parts
		if [ -n "${use_allowlist}" ]
		then
			# optional deduplication
			dedup < "${PROCESSED_PARTS_DIR}/allowlist" |
			tee >(wc -w > "${ABL_TMP_DIR}/allowlist_entries") |
			# pack entries in 1024 characters long lines
			convert_entries allowlist
			rm -f "${PROCESSED_PARTS_DIR}/allowlist"
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

	reg_action -blue "Stopping dnsmasq." || return 1
	/etc/init.d/dnsmasq stop || { reg_failure "Failed to stop dnsmasq."; return 1; }

	# check the final blocklist with dnsmasq --test
	reg_action -blue "Checking the resulting blocklist with 'dnsmasq --test'." || return 1

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

	local blocklist_entries_cnt blocklist_ipv4_entries_cnt allowlist_entries_cnt final_list_size_B \
		final_entries_cnt final_entries_cnt_human min_good_line_count_human

	for list_type in blocklist blocklist_ipv4 allowlist
	do
		read_list_stats "${list_type}_entries_cnt" "${ABL_TMP_DIR}/${list_type}_entries"
	done

	final_entries_cnt=$(( blocklist_entries_cnt + blocklist_ipv4_entries_cnt + allowlist_entries_cnt ))
	int2human final_entries_cnt_human "${final_entries_cnt}"

	read_list_stats final_list_size_B "${ABL_TMP_DIR}/final_list_bytes"
	final_list_size_human="$(bytes2human "${final_list_size_B}")"

	if [ "${final_entries_cnt}" -lt "${min_good_line_count}" ]
	then
		int2human min_good_line_count_human "${min_good_line_count}"
		reg_failure "Entries count (${final_entries_cnt_human}) is below the minimum value set in config (${min_good_line_count_human})."
		return 1
	fi

	log_msg -green "New blocklist file check passed."
	log_msg "Final list uncompressed file size: ${final_list_size_human}."

	import_blocklist "${out_f}" "${FINAL_BLOCKLIST_FILE}" || return 1

	get_elapsed_time_s elapsed_time_s "${INITIAL_UPTIME_S}"
	log_msg "" "Processing time for blocklist generation and import: $((elapsed_time_s/60))m:$((elapsed_time_s%60))s."

	if ! check_active_blocklist
	then
		reg_failure "Active blocklist check failed with the new blocklist."
		return 1
	fi

	log_msg -green "" "Active blocklist check passed with the new blocklist."

	print_msg -green "New blocklist installed with entries count: ${blue}${final_entries_cnt_human}${n_c}."
	reg_success "New blocklist installed with entries count: ${final_entries_cnt_human}."

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

	reg_export() { reg_action -blue "Creating ${1} backup of existing blocklist." || return 1; }

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
		log_msg "" "Blocklist backup file already exists."
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

	log_msg -blue "" "Importing the blocklist file."

	[ -n "${src_file}" ] || { reg_failure "import_blocklist: missing argument."; return 1; }
	[ -n "${FINAL_BLOCKLIST_FILE}" ] || { reg_failure "import_blocklist: \$FINAL_BLOCKLIST_FILE  is not set."; return 1; }

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

	log_msg "" "Successfully imported new ${dest_compressed}blocklist file for use by dnsmasq with size: $(get_file_size_human "${FINAL_BLOCKLIST_FILE}")."

	:
}

# Get nameservers for dnsmasq instance
# Output via global vars: ${instance}_NS_4, ${instance}_NS_6
# 1 - instance id
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
	reg_action -blue "Checking the active blocklist." || return 1

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

		log_msg "" "Using following nameservers for DNS resolution verification: ${ns_ips_sp}"
		log_msg -blue "Testing adblocking."

		try_lookup_domain "${ABL_TEST_DOMAIN}" "${ns_ips}" 15 -n ||
			{ reg_failure "Lookup of test domain '${ABL_TEST_DOMAIN}' failed with the new blocklist."; return 4; }

		log_msg -blue "Testing DNS resolution."
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
	local urls list_type list_format d domains='' dom IFS="${DEFAULT_IFS}"
	for list_type in allowlist blocklist blocklist_ipv4
	do
		for list_format in raw dnsmasq
		do
			d=
			[ "${list_format}" = dnsmasq ] && d="dnsmasq_"
			eval "urls=\"\${${d}${list_type}_urls}\""
			[ -z "${urls}" ] && continue
			domains="${domains}$(printf %s "${urls}" | tr ' \t' '\n' | ${SED_CMD} -n '/http/{s~^http[s]*[:]*[/]*~~g;s~/.*~~;/^$/d;p;}')${_NL_}"
		done
	done
	[ -z "${domains}" ] && return 0

	for dom in $(printf %s "${domains}" | ${SORT_CMD} -u)
	do
		try_lookup_domain "${dom}" "127.0.0.1" 2 || { reg_failure "Lookup of '${dom}' failed."; return 1; }
	done
	:
}

# 1 - domain
# 2 - nameservers
# 3 - max attempts
# 4 - (optional) '-n': don't check if result is 127.0.0.1 or 0.0.0.0
try_lookup_domain()
{
	local ns_res ip lookup_ok='' i=0

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
	local cnt entry_type list_prefix list_prefixes=

	# 'blocklist_ipv4' prefix doesn't need to be added for counting
	for entry_type in blocklist allowlist
	do
		eval "[ ! \"\${${entry_type}_urls}\" ] && [ ! -s \"\${local_${entry_type}_path}\" ]" && continue
		case ${entry_type} in
			blocklist) list_prefix=local ;;
			allowlist) list_prefix=server
		esac
		add2list list_prefixes "${list_prefix}" "|"
	done
	[ "${whitelist_mode}" = 1 ] && [ -n "${test_domains}" ] && add2list list_prefixes "server" "|"

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
		${SED_CMD} -E "s~^(${list_prefixes})=/~~;/${ABL_TEST_DOMAIN}/d;s~/#{0,1}$~~" | tr '/' '\n' | wc -w
	)"

	: "${cnt:=0}"
	[ "${whitelist_mode}" = 1 ] && cnt=$((cnt-26)) # ignore alphabet entries

	case "${cnt}" in *[!0-9]*|'') printf 0; return 1; esac
	printf %s "${cnt}"
	:
}

: