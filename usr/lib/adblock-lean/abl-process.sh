#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060,SC3057,SC3040

# silence shellcheck warnings
: "${list_part_failed_action:=}" \
	"${max_download_retries:=}" "${deduplication:=}" \
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


# UTILITY FUNCTIONS

# 1 - var name for centiseconds output
get_uptime_cs() {
	local __uptime i_cs gu_cs gu_s
	unset_vars "${1}" || return 1

	read -r __uptime _ < /proc/uptime &&
	case "${__uptime}" in
		''|*.*.*) false ;;
		*.*) ;;
		*) false ;;
	esac &&
	i_cs="${__uptime##*.}" &&
	case "${i_cs}" in
		'') gu_cs=00 ;;
		?) gu_cs="${i_cs}0" ;;
		??) gu_cs="${i_cs}" ;;
		??*) gu_cs="${i_cs%"${i_cs#??}"}"
	esac &&
	gu_s="${__uptime%.*}" &&
	is_uint "${gu_s}" "${gu_cs}" ||
	{
		reg_failure "Failed to get uptime from /proc/uptime."
		eval "${1}"=0
		return 1
	}
	gu_cs="${gu_s:-0}${gu_cs:-00}"
	gu_cs="${gu_cs#"${gu_cs%%[!0]*}"}"
	eval "${1}"='${gu_cs:-0}'
}

# To use, first get initial uptime: 'get_uptime_cs INITIAL_UPTIME'
# Then call this function to get elapsed time string at desired intervals, e.g.:
# get_elapsed_time_cs elapsed_time_cs "${INITIAL_UPTIME}"
# 1 - var name for centiseconds output
# 2 - initial uptime in centiseconds
get_elapsed_time_cs() {
	local ge_uptime_cs
	: "${ge_uptime_cs}"
	unset_vars "${1}" &&
	get_uptime_cs ge_uptime_cs &&
	eval "${1}"='$(( ge_uptime_cs - ${2:-ge_uptime_cs} ))'
}

# 1: var name for output
# 2: reference time in centiseconds
get_elapsed_time_human() {
	local _e_m _e_s _e_cs _e_elapsed _elapsed_human=''
	unset_vars "${1}" &&
	get_elapsed_time_cs _e_elapsed "${2}" || return 1
	_e_m=$(( _e_elapsed / 6000 ))
	[ "$_e_m" -gt 0 ] || _e_m=
	_e_cs=$(( _e_elapsed % 6000 ))
	_e_s=$(( _e_cs / 100 ))
	case "${_e_cs}" in
		'') _e_cs=00 ;;
		?) _e_cs="0${_e_cs}" ;;
		??) ;;
		??*) _e_cs="${_e_cs#"${_e_cs%??}"}"
	esac
	is_uint "${_e_m:-0}" "${_e_s}" "${_e_cs}" &&
		_elapsed_human="${_e_m:+"${_e_m}m:"}${_e_s}.${_e_cs}s"
	eval "${1}"='${_elapsed_human}'
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

	is_included "${list_name}" "${lists}" || { reg_failure "Unknown ${list_author} list '${2}'."; return 1; }

	eval "list_formats=\"\${${list_author}_formats}\""
	is_included "${list_format}" "${list_formats}" ||
		{ reg_failure "${list_id} is only available in formats: ${list_formats}."; return 1; }

	eval "mirrors=\"\${${list_author}_mirrors}\""
	is_included "${mirror}" "${mirrors}" ||
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

# 1 - job PID
# 2 - job return code
handle_done_job()
{
	local done_pid="${1}" done_job_rv="${2}" done_id me=handle_done_job
	[ -n "${done_pid}" ] || { reg_failure "${me}: received empty string for PID."; return 1; }
	[ -n "${done_job_rv}" ] || { reg_failure "${me}: received empty string instead of return code for job ${done_pid}."; return 1; }

	subtract_a_from_b "${done_pid}" "${RUNNING_PIDS}" RUNNING_PIDS
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
	local ct_curr_time_cs ct_curr_time_s ct_total_time_s ct_remaining_time_s
	eval "${1}"=0

	get_uptime_cs ct_curr_time_cs || return 1
	ct_curr_time_s=$((ct_curr_time_cs/100))
	ct_total_time_s=$((INITIAL_UPTIME_S-ct_curr_time_s))

	ct_remaining_time_s=$((PROCESSING_TIMEOUT_S-ct_total_time_s))
	[ "${ct_remaining_time_s}" -gt 0 ] ||
	{
		reg_failure "Processing timeout (${PROCESSING_TIMEOUT_S} s) for scheduler (PID: ${scheduler_pid})."
		return 1
	}

	case "$(( IDLE_TIMEOUT_S - (ct_curr_time_s-${CT_PREV_TIME_S:-${INITIAL_UPTIME_S}}) ))" in
		0|-*)
			reg_failure "Idle timeout (${IDLE_TIMEOUT_S} s) for scheduler (PID: ${scheduler_pid})."
			return 1
	esac

	case $((IDLE_TIMEOUT_S-ct_remaining_time_s)) in
		-*) ct_remaining_time_s="${IDLE_TIMEOUT_S}"
	esac

	CT_PREV_TIME_S=${ct_curr_time_s}
	eval "${1}"='${ct_remaining_time_s}'
}

# 1: blocklist ID
# 2: list types (allow|block|ipv4_block)
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
		rm -f "${sched_cb_fifo}"
		exit "${1}"
	}

	local list_type list_format index indexes \
		remaining_time_s \
		done_pid done_rv print_id \
		scheduler_pid \
		RUNNING_PIDS='' \
		RUNNING_JOBS_CNT=0 \
		bl_id="${1:?}" list_types="${2:?}"

	get_curr_job_pid scheduler_pid || finalize_scheduler 1

	trap 'USR_TRIG=1 finalize_scheduler 1' USR1

	local sched_cb_fifo="${SCHEDULE_DIR:?}/scheduler_callback_${scheduler_pid}"
	mkfifo "${sched_cb_fifo}" &&
	exec 3<>"${sched_cb_fifo}" || { reg_failure "Failed to create FIFO '${sched_cb_fifo}'."; finalize_scheduler 1; }

	print_msg ""

	for list_type in ${list_types}
	do
		for list_format in ${ALL_LIST_FORMATS}
		do
			eval "indexes=\"\${${list_format}_${list_type}_indexes}\""
			[ -n "${indexes}" ] || continue

			for index in ${indexes}
			do
				eval "print_id=\"\${${list_format}_${list_type}_${index}_print_id}\""

				get_remaining_time remaining_time_s || finalize_scheduler 1

				# wait for job vacancy
				while [ "${RUNNING_JOBS_CNT}" -ge "${PARALLEL_JOBS}" ] && [ -e "${sched_cb_fifo}" ] &&
					read -t "${remaining_time_s}" -r done_pid done_rv < "${sched_cb_fifo}"
				do
					get_remaining_time remaining_time_s &&
					handle_done_job "${done_pid}" "${done_rv}" || finalize_scheduler 1
				done

				get_remaining_time remaining_time_s || finalize_scheduler 1

				RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT+1))
				process_list_part "${index}" "${list_type}" "${list_format}" "${print_id}" "${bl_id}" "${scheduler_pid}" &

				RUNNING_PIDS="${RUNNING_PIDS} ${!}"
				export "JOB_PRINT_ID_${!}"="${print_id}"
			done
		done
	done

	# wait for jobs to finish and handle errors
	get_remaining_time remaining_time_s || return 1
	while [ "${RUNNING_JOBS_CNT}" -gt 0 ] && [ -e "${sched_cb_fifo}" ] &&
		read -t "${remaining_time_s}" -r done_pid done_rv < "${sched_cb_fifo}"
	do
		get_remaining_time remaining_time_s &&
		handle_done_job "${done_pid}" "${done_rv}" || finalize_scheduler 1
	done
	get_remaining_time remaining_time_s || finalize_scheduler 1
	[ "${RUNNING_JOBS_CNT}" = 0 ] ||
		{ reg_failure "Not all jobs are done: RUNNING_JOBS_CNT=${RUNNING_JOBS_CNT}"; finalize_scheduler 1; }

	finalize_scheduler 0
}

# 1: list index
# 2: list type (block|ipv4_block|allow)
# 3: list format (raw|dnsmasq|hosts)
# 4: job print ID
# 5: blocklist ID
# 6: scheduler PID
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
		[ -n "${2}" ] && reg_failure "${me}: ${2}"
		case "${1}" in
			0)
				local list_size_human stats_pad suffix_pad
				bytes2human list_size_human "${part_size_B}" -p
				get_pad stats_pad "${print_id}" 38
				get_pad suffix_pad "${line_count_human}" 8
				log_msg "Successfully processed list:  ${green}${print_id}${n_c} ${stats_pad}[ ${list_size_human} - ${suffix_pad}${line_count_human} lines ]" ;;
			*)
				rm -f "${dest_file}" "${list_stats_file}"
				[ "${1}" = 1 ] &&
				{
					if [ -n "${curr_job_pid}" ]
					then
						: "${print_id:=unknown}"
						reg_failure "Fatal error in processing job (PID: ${curr_job_pid}) for list '${print_id}'."
					else
						reg_failure "Fatal error reported by unknown processing job."
					fi

					[ -n "${scheduler_pid}" ] && [ -d "/proc/${scheduler_pid}" ] && {
						kill -s USR1 "${scheduler_pid}"
						wait_on_pid "${scheduler_pid}" 5
					}

					exit 1
				}
		esac

		printf '%s\n' "${curr_job_pid} ${1}" > "${sched_cb_fifo}"
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

	local me=process_list_part \
		curr_job_pid msg msg_mirr pad \
		list_origin='' list_path='' list_author='' mirrors='' mirror='' curr_mirror='' first_mirror='' loop_prev_mirror='' \
		whitelist_mode min_line_count max_file_part_size_KB \
		index="${1}" list_type="${2}" list_format="${3}" print_id="${4}" bl_id="${5}" scheduler_pid="${6}"

	get_curr_job_pid curr_job_pid || finalize_job 1

	eval "list_origin=\"\${${list_format}_${list_type}_${index}_origin}\"" &&
	ASSERT_NOEXIT=1 assert_set "F_${me}" index list_type list_format print_id bl_id scheduler_pid list_origin &&
	get_bl_params -f "${me}" "${bl_id}" whitelist_mode max_file_part_size_KB "min_line_count=min_${list_type}list_part_line_count" || finalize_job 1

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
		part_line_count='' line_count_human min_line_count_human \
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
			1)
				# only print subdomains of allowlist domains
				${AWK_CMD} 'NR==FNR { if ($0 !~ /^\*/) { allow[$0] }; next } { n=split($1,arr,"."); addr = arr[n];
					for ( i=n-1; i>1; i-- ) { addr = arr[i] "." addr; if ( addr in allow ) { print $1; next } } }' "${PROCESSED_PARTS_DIR}/allow" - ;;
			*)
				# remove allowlist domains from blocklist
				${AWK_CMD} 'NR==FNR { if ($0 ~ /^\*\./) { allow_wild[substr($0,3)]; next }; allow[$0]; next }
					{ n=split($1,arr,"."); addr = arr[n]; for ( i=n-1; i>=1; i-- )
					{ addr = arr[i] "." addr; if ( (i>1 && addr in allow_wild) || addr in allow ) next } } 1' "${PROCESSED_PARTS_DIR}/allow" - ;;
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

	# shellcheck disable=SC2034
	local lists schedule_req local_list_path list_format list_type \
		preproc_cnt=0 preproc_cnt_human \
		preproc_size_B=0 preproc_size_human \
		invalid_urls bad_hagezi_urls \
		test_domains \
		list_line_count list_types \
		raw_block_lists raw_allow_lists raw_ipv4_block_lists \
		dnsmasq_block_lists dnsmasq_allow_lists dnsmasq_ipv4_block_lists \
		hosts_block_lists \
		local_allowlist_path local_blocklist_path \
		bl_id="${1}"

	get_bl_params "${bl_id}" \
		test_domains \
		whitelist_mode \
		raw_block_lists raw_allow_lists raw_ipv4_block_lists \
		dnsmasq_block_lists dnsmasq_allow_lists dnsmasq_ipv4_block_lists \
		hosts_block_lists \
		local_allowlist_path local_blocklist_path

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
			schedule_jobs "${bl_id}" "${list_types}" &
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
				find_files _ "${PROCESSED_PARTS_DIR}" "allow-" "" "${bl_id}" || [ ${?} != 1 ] ||
					{ reg_failure "Failed to merge allowlist part."; return 1; }
		fi

		# process results
		for list_type in ${list_types}
		do
			# count lines for current list type
			local part_line_count=0 list_line_count=0 part_size_B=0 list_size_B=0
			FF_EXEC="read_stats_cb {}" \
				find_files _ "${ABL_TMP_DIR}" "stats_${list_type}-" "" "${bl_id}" || [ ${?} != 1 ] ||
					{ reg_failure "Failed to read processed ${list_type}list parts stats."; return 1; }

			if ! [ "${list_line_count}" -gt 0 ] || ! [ "${list_size_B}" -gt 0 ]
			then
				case "${list_type}" in
					block)
						[ "${whitelist_mode}" = 1 ] || return 1
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
		bl_id \
		run_state \
		curr_path \
		curr_persist_path \
		conn_check_req \
		file_to_bk \
		bk_file \
		bk_ext \
		final_compr_ext \
		force_unload \
		install_path install_cnt \
		index \
		dnsmasq_indexes \
		totalmem \
		blocklists_out_var="${1:?}" bl_ids="${2:?}" initial_uptime_cs="${3:?}"
	
	: "${install_cnt}"

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

	for bl_id in ${bl_ids}
	do
		unset "RESTORE_FROM_PERSIST_${bl_id}" "SKIP_LOAD_STOP_${bl_id}"

		get_bl_params -f "${me}" "${bl_id}" run_state dnsmasq_indexes install_path || return 1

		get_bl_params "${bl_id}" curr_path curr_persist_path persist_dir bk_ext final_compr_ext

		case "${run_state}" in
			0|3|4) ;;
			*)
				KEEP_PERSIST=1 do_stop "${bl_id}"
				CA_NOERR=1 get_bl_run_state "${bl_id}"
				run_state=${?}
				set_bl_params "${bl_id}" run_state ;;
		esac

		conn_check_req=1
		force_unload=${unload_blocklist_before_update}

		case ${run_state} in
			0) ;;
			3|4) force_unload=0 conn_check_req='' ;;
			*) exit 1
		esac

		if [ "${force_unload}" != 1 ] && [ -n "${conn_check_req}" ]
		then
			test_url_domains || force_unload=1 # TODO: test per-bl-inst domains
		fi

		bk_file=
		file_to_bk=
		if [ -n "${curr_path}" ]
		then
			file_to_bk=${curr_path}
		elif [ -n "${curr_persist_path}" ]
		then
			file_to_bk=${curr_persist_path}
		fi

		[ -f "${file_to_bk}" ] || file_to_bk=

		if [ -n "${file_to_bk}" ] && is_dir_writable "${bl_id}" "${file_to_bk%/*}"
		then
			bk_file="${BK_BL_BASE_PATH:?}-${bl_id}${bk_ext}"
			reg_action -blue "" "Creating backup of current blocklist '${bl_id}'." &&
			mv_blocklist "${file_to_bk}" "${bk_file}" "${INTERM_COMPR_TO_FILE}" "${bl_id}" ||
			{
				reg_failure "Failed to create backup of current blocklist file '${file_to_bk}'."
				rm_if_writable "${bl_id}" "${file_to_bk}"
				bk_file=
			}
		elif [ -n "${file_to_bk}" ]
		then
			# for persistent blocklist in 'manual' mode, the original file is used as a backup
			bk_file="${file_to_bk}"
		else
			reg_msg -2 "" "No existing file found for blocklist '${bl_id}'."
		fi
		set_bl_params "${bl_id}" bk_file
		debug_msg "bk_file: '${bk_file}'"

		KEEP_BK=1 KEEP_PERSIST=0 rm_blocklists "${bl_id}"

		if [ "${force_unload}" = 1 ]
		then
			reg_action -blue "Unloading current blocklist '${bl_id}'."
			restart_dnsmasq "${dnsmasq_indexes}" || exit 1
			set_bl_params "${bl_id}" skip_load_stop=1
		fi

		processed_bl_file="${ABL_TMP_DIR}/processed-blocklist-${bl_id}${final_compr_ext}"

		if gen_blocklist "${bl_id}" install_cnt "${processed_bl_file}" "${initial_uptime_cs}" &&
			try_mv "${processed_bl_file}" "${install_path}"
		then
			add2list "${blocklists_out_var}" "${bl_id}"
			set_bl_params "${bl_id}" install_cnt
		else
			rm -f "${processed_bl_file}"
			reg_failure "Failed to generate new blocklist file for blocklist '${bl_id}'."
		fi
	done
}


# 1: blocklist ID
# 2: out var for elements count
# 3: output file path
# 4: initial uptime in centiseconds
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
			find_files _ "${PROCESSED_PARTS_DIR}" "${prefix}-" "${suffix}" "${bl_id}" || printf ''
	}

	# 1 - var name for output
	# 2 - path to file
	read_list_stats()
	{
		read -r "${1?}" 2>/dev/null < "${2}"
		eval ": \"\${${1}:=0}\""
	}

	local me=gen_blocklist \
		list_type \
		gen_cnt gen_cnt_human \
		min_good_line_count min_good_line_count_human \
		max_blocklist_file_size_KB \
		errors \
		dedup_cmd_or_cat="${CAT_CMD}" \
		pack_cmd="pack_entries_sed" \
		part_extr_or_cat_stdout \
		final_compr_or_cat_stdout \
		new_single_instance \
		\
		bl_id="${1:?}" \
		cnt_out_var="${2:?}" \
		out_f="${3:?}" \
		INITIAL_UPTIME_S="$(( ${4} / 100 ))"

	unset_vars "${cnt_out_var}" &&

	get_bl_params -f "${me}" "${bl_id}" \
		part_extr_or_cat_stdout \
		max_blocklist_file_size_KB \
		min_good_line_count\
		final_compr_or_cat_stdout &&

	get_bl_params "${bl_id}" \
		new_single_instance &&

	case "${part_extr_or_cat_stdout}" in
		"${CAT_CMD}") ;;
		*) assert_set "F_${me}" INTERM_COMPR_EXT || false
	esac || return 1

	local max_size_b=$((max_blocklist_file_size_KB*1024))
	[ "${deduplication}" = 1 ] && dedup_cmd_or_cat="${SORT_CMD} -u -"

	case "${AWK_CMD}" in
		*gawk) pack_cmd="pack_entries_awk"
	esac

	gen_list_parts "${bl_id}" ||
	{
		reg_failure "Failed to generate preprocessed blocklist file with at least one entry."
		return 1
	}

	reg_action -blue "" "Sorting and merging blocklist parts into a single blocklist file." || return 1

	{
		{
			# print blocklist parts
			print_list_parts block "${INTERM_COMPR_EXT}" "${part_extr_or_cat_stdout}" |
			# optional deduplication
			${dedup_cmd_or_cat} |
			# count entries
			tee >(wc -w > "${ABL_TMP_DIR}/block_stats") |
			# pack entries in 1024 characters long lines
			${pack_cmd} block || exit 1

			# print ipv4 blocklist parts
			if [ -n "${use_ipv4_blocklist}" ]
			then
				print_list_parts ipv4_block "${INTERM_COMPR_EXT}" "${part_extr_or_cat_stdout}" |
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

			# add the test domain in single-instance mode
			[ -n "${new_single_instance}" ] &&
				printf '%s\n' "address=/${ABL_TEST_DOM_BASE}/#"
			:
		} |

		# limit size
		{ head -c "${max_size_b}"; read -rn1 -d '' && { touch "${ABL_TMP_DIR}/abl-too-big.tmp"; cat 1>/dev/null; } || true; } |

		# compress or cat
		${final_compr_or_cat_stdout} > "${out_f}"
	} 2>"${ERR_F}" ||
		{
			reg_failure "Failed to merge blocklist parts into output file '${out_f}'."
			errors="$(cat "${ERR_F}" 2>/dev/null | ${SED_CMD} '/^$/d')"
			rm -f "${out_f}" "${ERR_F}"
			[ -n "${errors}" ] && log_msg "STDERR output:${_NL_}${errors}"
			return 1
		}
	rm -f "${ERR_F}"

	if [ -f "${ABL_TMP_DIR}/abl-too-big.tmp" ]
	then
		rm -f "${out_f}"
		reg_failure "Final uncompressed size for blocklist ${bl_id} exceeded ${max_blocklist_file_size_KB} kiB set in max_blocklist_file_size_KB config option!"
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
		try_extract -stdout "${bl_id}" "${out_f}" |
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

:
