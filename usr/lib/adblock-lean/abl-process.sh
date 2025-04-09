#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003
# ABL_VERSION=dev

# silence shellcheck warnings
: "${use_compression:=}" "${max_file_part_size_KB:=}" "${whitelist_mode:=}" "${list_part_failed_action:=}" "${test_domains:=}"
: "${max_download_retries:=}" "${deduplication:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" "${local_allowlist_path:=}"
: "${blue:=}" "${green:=}" "${n_c:=}"

PROCESSED_PARTS_DIR="${ABL_DIR}/list_parts"

SCHEDULE_DIR="${ABL_DIR}/schedule"

PROCESSING_TIMEOUT_S=900 # 15 minutes
IDLE_TIMEOUT_S=300 # 5 minutes

ABL_TEST_DOMAIN="adblocklean-test123.info"


# UTILITY FUNCTIONS

try_gzip()
{
	busybox gzip -f "${1}" || { rm -f "${1}.gz"; reg_failure "Failed to compress '${1}'."; return 1; }
}

try_gunzip()
{
	busybox gunzip -f "${1}" || { rm -f "${1%.gz}"; reg_failure "Failed to extract '${1}'."; return 1; }
}

# subtract list $1 from list $2, with optional field separator $4 (otherwise uses newline)
# output via optional variable with name $3
# returns status 0 if the result is null, 1 if not
subtract_a_from_b() {
	local sab_out="${3:-___dummy}"
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
check_for_timeout()
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
	check_for_timeout remaining_time_s || return 1

	while [ "${RUNNING_JOBS_CNT}" -ge "${PARALLEL_JOBS}" ] && [ -e "${SCHED_CB_FIFO}" ] &&
		read -t "${remaining_time_s}" -r done_pid done_rv < "${SCHED_CB_FIFO}"
	do
		check_for_timeout remaining_time_s || return 1
		handle_done_job "${done_pid}" "${done_rv}" || return 1
	done
	check_for_timeout remaining_time_s || return 1

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
					bad_hagezi_urls="$(printf %s "${list_urls}" | tr ' ' '\n' | $SED_CMD -n '/\/hagezi\//{/onlydomains\./d;/^$/d;p;}')"
					[ -n "${bad_hagezi_urls}" ] && log_msg -warn "" \
						"Following Hagezi URLs are missing the '-onlydomains' suffix in the filename:" "${bad_hagezi_urls}"
				esac
			fi

			for list_url in ${list_urls}
			do
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
	check_for_timeout remaining_time_s || return 1
	while [ "${RUNNING_JOBS_CNT}" -gt 0 ] && [ -e "${SCHED_CB_FIFO}" ] &&
		read -t "${remaining_time_s}" -r done_pid done_rv < "${SCHED_CB_FIFO}"
	do
		check_for_timeout remaining_time_s || finalize_scheduler 1
		handle_done_job "${done_pid}" "${done_rv}" || finalize_scheduler 1
	done
	check_for_timeout remaining_time_s || finalize_scheduler 1
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
				log_msg -green "Successfully processed list: ${blue}${list_path}${n_c} (${line_count_human} lines, $(bytes2human "${part_size_B}"))." ;;
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
		ucl_err_file="${ABL_DIR}/ucl_err_${job_id}" \
		rogue_el_file="${ABL_DIR}/rogue_el_${job_id}" \
		list_stats_file="${ABL_DIR}/stats_${job_id}" \
		size_exceeded_file="${ABL_DIR}/size_exceeded_${job_id}" \
		part_line_count='' line_count_human compress_part='' min_line_count='' min_line_count_human \
		part_size_B='' retry=1

	case ${list_type} in
		blocklist|blocklist_ipv4) [ "${use_compression}" = 1 ] && { dest_file="${dest_file}.gz"; compress_part=1; }
	esac
	eval "min_line_count=\"\${min_${list_type}_part_line_count}\""

	while :
	do
		rm -f "${rogue_el_file}" "${list_stats_file}" "${size_exceeded_file}" "${ucl_err_file}"

		# Download or cat the list
		local fetch_cmd lines_cnt_low='' dl_completed=''
		case "${list_origin}" in
			DL) fetch_cmd=dl_list ;;
			LOCAL) fetch_cmd="cat" ;;
			*) reg_failure "Invalid list origin '${list_origin}'."; finalize_job 1
		esac

		log_msg "Processing ${list_format} ${list_type}: ${blue}${list_path}${n_c}"

		${fetch_cmd} "${list_path}" |
		# limit size
		{ head -c "${max_file_part_size_KB}k"; grep . 1>/dev/null && touch "${size_exceeded_file}"; } |

		# Remove comment lines and trailing comments, remove whitespaces
		$SED_CMD 's/#.*$//; s/^[ \t]*//; s/[ \t]*$//; /^$/d' |

		# Convert dnsmasq format to raw format
		if [ "${list_format}" = dnsmasq ]
		then
			local rm_prefix_expr="s~^[ \t]*(local|server|address)=/~~" rm_suffix_expr=''
			case "${list_type}" in
				blocklist) rm_suffix_expr='s~/$~~' ;;
				blocklist_ipv4) rm_prefix_expr="s~^[ \t]*bogus-nxdomain=~~" ;;
				allowlist) rm_suffix_expr='s~/#$~~'
			esac
			$SED_CMD -E "${rm_prefix_expr};${rm_suffix_expr}" | tr '/' '\n'
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
		tee >($SED_CMD -nE "/${val_entry_regex}/d;p;:1 n;b1" > "${rogue_el_file}") |

		# compress parts
		if [ -n "${compress_part}" ]
		then
			busybox gzip
		else
			cat
		fi > "${dest_file}"

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

	case "${MAX_PARALLEL_JOBS}" in
		auto)
			local cpu_cnt
			cpu_cnt="$(grep -c '^processor\s*:' /proc/cpuinfo)"
			case "${cpu_cnt}" in
				''|*[!0-9]*|0)
					log_msg "Failed to detect CPU core count. Parallel processing will be disabled."
					PARALLEL_JOBS=1 ;;
				*)
					# cap PARALLEL_JOBS to 4 in 'auto' mode
					if [ "${cpu_cnt}" -ge 4 ]
					then
						PARALLEL_JOBS=4
					else
						PARALLEL_JOBS=${cpu_cnt}
					fi
			esac ;;
		*)
			PARALLEL_JOBS="${MAX_PARALLEL_JOBS}"
	esac

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
			for file in "${ABL_DIR}/stats_${list_type}-"*
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
				$SED_CMD "/^$/d;s~^.*$~local=/&/~;\$!{n;a /${_NL_}};\$!{n;a /${_NL_}};\$!{n; a /${_NL_}};a @" ;;
			allowlist)
				# packs 4 domains in one 'server=/.../#'' line
				{ cat; printf '\n'; } | $SED_CMD '/^$/d;$!N;$!N;$!N;s~\n~/~g;s~^~server=/~;s~/*$~/#@~' ;;
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
		$AWK_CMD -v ORS="" -v m=${len_lim} -v a="${allow_char}" -v t=${entry_type} '
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
	print_list_parts()
	{
		local find_name="${1}-*" find_cmd="cat"
		[ "${use_compression}" = 1 ] && { find_name="${1}-*.gz" find_cmd="busybox zcat"; }
		find "${ABL_DIR}" -name "${find_name}" -exec ${find_cmd} {} \; -exec rm -f {} \;
		printf ''
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
			$SORT_CMD -u -
		else
			cat
		fi
	}

	local elapsed_time_s list_type out_f="${ABL_DIR}/abl-blocklist"
	local dnsmasq_err max_blocklist_file_size_B=$((max_blocklist_file_size_KB*1024))

	local final_compress=
	if [ "${use_compression}" = 1 ]
	then
		check_blocklist_compression_support
		case ${?} in
			0) final_compress=1 ;;
			2) exit 1
		esac
	fi

	get_abl_run_state
	case ${?} in
		1) unload_blocklist_before_update=1 ;;
		4) unload_blocklist_before_update=0 ;;
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

	[ -n "${final_compress}" ] && out_f="${out_f}.gz"

	rm -f "${ABL_DIR}/dnsmasq_err"

	{
		# print blocklist parts
		print_list_parts blocklist |
		# optional deduplication
		dedup |

		# count entries
		tee >(wc -w > "${ABL_DIR}/blocklist_entries") |
		# pack entries in 1024 characters long lines
		convert_entries blocklist

		# print ipv4 blocklist parts
		if [ -n "${use_blocklist_ipv4}" ]
		then
			print_list_parts blocklist_ipv4 |
			# optional deduplication
			dedup |
			tee >(wc -w > "${ABL_DIR}/blocklist_ipv4_entries") |
			# add prefix
			$SED_CMD 's/^/bogus-nxdomain=/'
		fi

		# print allowlist parts
		if [ -n "${use_allowlist}" ]
		then
			# optional deduplication
			dedup < "${PROCESSED_PARTS_DIR}/allowlist" |
			tee >(wc -w > "${ABL_DIR}/allowlist_entries") |
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
	tee >(wc -c > "${ABL_DIR}/final_list_bytes") |

	# limit size
	{ head -c "${max_blocklist_file_size_B}"; grep . 1>/dev/null && touch "${ABL_DIR}/abl-too-big.tmp"; } |
	if  [ -n "${final_compress}" ]
	then
		busybox gzip
	else
		cat
	fi > "${out_f}" || { reg_failure "Failed to write to output file '${out_f}'."; rm -f "${out_f}"; return 1; }

	if [ -f "${ABL_DIR}/abl-too-big.tmp" ]; then
		rm -f "${out_f}"
		reg_failure "Final uncompressed blocklist exceeded ${max_blocklist_file_size_KB} kiB set in max_blocklist_file_size_KB config option!"
		log_msg "Consider either increasing this value in the config or changing the blocklist URLs."
		return 1
	fi

	reg_action -blue "Stopping dnsmasq." || return 1
	/etc/init.d/dnsmasq stop || { reg_failure "Failed to stop dnsmasq."; return 1; }

	# check the final blocklist with dnsmasq --test
	reg_action -blue "Checking the resulting blocklist with 'dnsmasq --test'." || return 1
	if  [ -n "${final_compress}" ]
	then
		busybox zcat -f "${out_f}"
	else
		cat "${out_f}"
	fi |
	dnsmasq --test -C - 2> "${ABL_DIR}/dnsmasq_err"
	if [ ${?} != 0 ] || ! grep -q "syntax check OK" "${ABL_DIR}/dnsmasq_err"
	then
		dnsmasq_err="$(head -n10 "${ABL_DIR}/dnsmasq_err" | $SED_CMD '/^$/d')"
		rm -f "${out_f}" "${ABL_DIR}/dnsmasq_err"
		reg_failure "The dnsmasq test on the final blocklist failed."
		log_msg "dnsmasq --test errors:" "${dnsmasq_err:-"No specifics: probably killed because of OOM."}"
		return 2
	fi

	rm -f "${ABL_DIR}/dnsmasq_err"

	local blocklist_entries_cnt blocklist_ipv4_entries_cnt allowlist_entries_cnt final_list_size_B \
		final_entries_cnt final_entries_cnt_human min_good_line_count_human

	for list_type in blocklist blocklist_ipv4 allowlist
	do
		read_list_stats "${list_type}_entries_cnt" "${ABL_DIR}/${list_type}_entries"
	done

	final_entries_cnt=$(( blocklist_entries_cnt + blocklist_ipv4_entries_cnt + allowlist_entries_cnt ))
	int2human final_entries_cnt_human "${final_entries_cnt}"

	read_list_stats final_list_size_B "${ABL_DIR}/final_list_bytes"
	final_list_size_human="$(bytes2human "${final_list_size_B}")"

	if [ "${final_entries_cnt}" -lt "${min_good_line_count}" ]
	then
		int2human min_good_line_count_human "${min_good_line_count}"
		reg_failure "Entries count (${final_entries_cnt_human}) is below the minimum value set in config (${min_good_line_count_human})."
		return 1
	fi

	log_msg -green "New blocklist file check passed."
	log_msg "Final list uncompressed file size: ${final_list_size_human}."

	if ! import_blocklist_file "${final_compress}"
	then
		reg_failure "Failed to import new blocklist file."
		return 1
	fi

	restart_dnsmasq || return 1

	get_elapsed_time_s elapsed_time_s "${INITIAL_UPTIME_S}"
	log_msg "" "Processing time for blocklist generation and import: $((elapsed_time_s/60))m:$((elapsed_time_s%60))s."

	if ! check_active_blocklist
	then
		reg_failure "Active blocklist check failed with new blocklist file."
		return 1
	fi

	log_msg -green "" "Active blocklist check passed with the new blocklist file."
	log_success "${green}New blocklist installed with entries count: ${blue}${final_entries_cnt_human}${n_c}."
	rm -f "${ABL_DIR}/prev_blocklist"*

	:
}

try_export_existing_blocklist()
{
	export_existing_blocklist
	case ${?} in
		1) reg_failure "Failed to export the blocklist."; return 1 ;;
		2) return 2
	esac
	:	
}

# return codes:
# 0 - success
# 1 - failure
# 2 - blocklist file not found (nothing to export)
export_existing_blocklist()
{
	reg_export()
	{
		reg_action -blue "Creating ${1} backup of existing blocklist." || return 1
	}

	local src src_d="${DNSMASQ_CONF_D}" dest="${ABL_DIR}/prev_blocklist"
	if [ -f "${src_d}/.abl-blocklist.gz" ]
	then
		case ${use_compression} in
			1)
				src="${src_d}/.abl-blocklist.gz" dest="${dest}.gz"
				reg_export compressed || return 1 ;;
			*)
				reg_export uncompressed || return 1
				try_gunzip "${src_d}/.abl-blocklist.gz" || { rm -f "${src_d}/.abl-blocklist.gz"; return 1; }
				src="${src_d}/.abl-blocklist"
		esac
	elif [ -f "${src_d}/abl-blocklist" ]
	then
		if [ "${use_compression}" = 1 ]
		then
			reg_export compressed || return 1
			try_mv "${src_d}/abl-blocklist" "${src_d}/.abl-blocklist" || return 1
			try_gzip "${src_d}/.abl-blocklist" || return 1
			src="${src_d}/.abl-blocklist.gz" dest="${dest}.gz"
		else
			reg_export uncompressed || return 1
			src="${src_d}/abl-blocklist"
		fi
	else
		log_msg "" "No existing compressed or uncompressed blocklist identified."
		return 2
	fi
	try_mv "${src}" "${dest}" || return 1
	:
}

restore_saved_blocklist()
{
	restore_failed()
	{
		reg_failure "Failed to restore saved blocklist."
	}

	local mv_src="${ABL_DIR}/prev_blocklist" mv_dest="${ABL_DIR}/abl-blocklist"
	reg_action -blue "Restoring saved blocklist file." || { restore_failed; return 1; }

	local final_compress=
	if [ "${use_compression}" = 1 ]
	then
		check_blocklist_compression_support
		case ${?} in
			0) final_compress=1 ;;
			2) exit 1
		esac
	fi

	if [ -f "${mv_src}.gz" ]
	then
		try_mv "${mv_src}.gz" "${mv_dest}.gz" || { restore_failed; return 1; }
		if [ -z "${final_compress}" ]
		then
			try_gunzip "${mv_dest}.gz" || { restore_failed; return 1; }
		fi
	elif [ -f "${mv_src}" ]
	then
		try_mv "${mv_src}" "${mv_dest}" || { restore_failed; return 1; }
		if [ -n "${final_compress}" ]
		then
			try_gzip -f "${mv_dest}" || { restore_failed; return 1; }
		fi
	else
		reg_failure "No previous blocklist file found."
		restore_failed
		return 1
	fi
	import_blocklist_file "${final_compress}" || { reg_failure "Failed to import the blocklist file."; restore_failed; return 1; }

	restart_dnsmasq || { restore_failed; return 1; }

	:
}

# 1 (optional): if set, compresses the file unless already compressed
import_blocklist_file()
{
	local src src_compressed='' src_file="${ABL_DIR}/abl-blocklist" dest_file="${DNSMASQ_CONF_D}/abl-blocklist"
	local final_compress="${1}"
	[ -n "${final_compress}" ] && dest_file="${DNSMASQ_CONF_D}/.abl-blocklist.gz"
	for src in "${src_file}" "${src_file}.gz"
	do
		case "${src}" in *.gz) src_compressed=1; esac
		[ -f "${src}" ] && { src_file="${src}"; break; }
	done || { reg_failure "Failed to find file to import."; return 1; }

	clean_dnsmasq_dir

	if [ -n "${src_compressed}" ] && [ -z "${final_compress}" ]
	then
		try_gunzip "${src_file}" || return 1
		src_file="${src_file%.gz}"
	elif [ -z "${src_compressed}" ] && [ -n "${final_compress}" ]
	then
		try_gzip "${src_file}" || return 1
		src_file="${src_file}.gz"
	fi

	try_mv "${src_file}" "${dest_file}" || return 1
	imported_final_list_size_human=$(get_file_size_human "${dest_file}")

	compressed=
	if [ -n "${final_compress}" ]
	then
		printf '%s\n' "conf-script=\"busybox sh ${DNSMASQ_CONF_D}/.abl-extract_blocklist\"" > "${DNSMASQ_CONF_D}"/abl-conf-script &&
		printf '%s\n%s\n' "busybox zcat ${DNSMASQ_CONF_D}/.abl-blocklist.gz" "exit 0" > "${DNSMASQ_CONF_D}"/.abl-extract_blocklist ||
			{ reg_failure "Failed to create conf-script for dnsmasq."; return 1; }
		compressed=" compressed"
	fi

	log_msg "" "Successfully imported new${compressed} blocklist file for use by dnsmasq with size: ${imported_final_list_size_human}."

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
	reg_action -blue "Checking active blocklist." || return 1

	local family ip instance_ns def_ns ns_ips='' ns_ips_sp=''

	check_dnsmasq_instance "${DNSMASQ_INSTANCE}" || return 1
	get_dnsmasq_instance_ns "${DNSMASQ_INSTANCE}"

	for family in 4 6
	do
		case "${family}" in
			4) def_ns=127.0.0.1 ;;
			6) def_ns=::1
		esac
		eval "instance_ns=\"\${${DNSMASQ_INSTANCE}_NS_${family}}\""
		for ip in ${instance_ns:-"${def_ns}"}
		do
			add2list ns_ips "${ip}"
			add2list ns_ips_sp "${ip}" ", "
		done
	done

	log_msg "" "Using following nameservers for DNS resolution verification: ${ns_ips_sp}"
	reg_action -blue "Testing adblocking."

	try_lookup_domain "${ABL_TEST_DOMAIN}" "${ns_ips}" 15 -n ||
		{ reg_failure "Lookup of the bogus test domain failed with new blocklist."; return 4; }

	reg_action -blue "Testing DNS resolution."
	for domain in ${test_domains}
	do
		try_lookup_domain "${domain}" "${ns_ips}" 5 ||
			{ reg_failure "Lookup of test domain '${domain}' failed with new blocklist."; return 1; }
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
			domains="${domains}$(printf %s "${urls}" | tr ' \t' '\n' | $SED_CMD -n '/http/{s~^http[s]*[:]*[/]*~~g;s~/.*~~;/^$/d;p;}')${_NL_}"
		done
	done
	[ -z "${domains}" ] && return 0

	for dom in $(printf %s "${domains}" | $SORT_CMD -u)
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

	if [ -f "${DNSMASQ_CONF_D}"/.abl-blocklist.gz ]
	then
		busybox zcat "${DNSMASQ_CONF_D}"/.abl-blocklist.gz
	elif [ -f "${DNSMASQ_CONF_D}"/abl-blocklist ]
	then
		cat "${DNSMASQ_CONF_D}/abl-blocklist"
	else
		printf ''
	fi |
	$SED_CMD -E "s~^(${list_prefixes})=/~~;/${ABL_TEST_DOMAIN}/d;s~/#{0,1}$~~" | tr '/' '\n' | wc -w > "/tmp/abl_entries_cnt"

	read_str_from_file -d -v cnt -f "/tmp/abl_entries_cnt" -a 2 -D "entries count"

	[ "${whitelist_mode}" = 1 ] && cnt=$((cnt-26)) # ignore alphabet entries

	case "${cnt}" in *[!0-9]*|'') printf 0; return 1; esac
	printf %s "${cnt}"
	:
}
