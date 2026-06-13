#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060,SC3057,SC3040

# silence shellcheck warnings
: "${blockset_part_failed_action:=}" \
	"${max_download_retries:=}" "${deduplication:=}" \
	"${blue:=}" "${lblue:=}" "${green:=}" "${red:=}" "${yellow:=}" "${orange:=}" "${n_c:=}"

PROCESSED_PARTS_DIR="${ABL_TMP_DIR}/blockset_parts"

ERR_F="${ABL_TMP_DIR}/process-errors"

SCHEDULE_DIR="${ABL_TMP_DIR}/schedule"

PROCESSING_TIMEOUT_S=900 # 15 minutes
IDLE_TIMEOUT_S=300 # 5 minutes

ABL_TEST_DOM_BASE="adblocklean-test.totallybogus"

ALL_LIST_FORMATS="raw dnsmasq hosts"
ALL_LIST_TYPES="allow block ipv4_block"


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
	unset_vars "${1}"

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
		export -n "${1}"=0
		return 1
	}
	gu_cs="${gu_s:-0}${gu_cs:-00}"
	gu_cs="${gu_cs#"${gu_cs%%[!0]*}"}"
	export -n "${1}=${gu_cs:-0}"
}

# To use, first get initial uptime: 'get_uptime_cs INITIAL_UPTIME'
# Then call this function to get elapsed time string at desired intervals, e.g.:
# get_elapsed_time_cs elapsed_time_cs "${INITIAL_UPTIME}"
# 1 - var name for centiseconds output
# 2 - initial uptime in centiseconds
get_elapsed_time_cs() {
	local ge_uptime_cs
	unset_vars "${1}"
	get_uptime_cs ge_uptime_cs &&
	export -n "${1}=$(( ge_uptime_cs - ${2:-ge_uptime_cs} ))"
}

# 1: var name for output
# 2: reference time in centiseconds
get_elapsed_time_human() {
	local _e_m _e_s _e_cs _e_elapsed _elapsed_human
	unset_vars "${1}"
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
	export -n "${1}=${_elapsed_human}"
}


# HELPER FUNCTIONS

# Env vars: TESTED_URLS
# TODO: Parallelize domains lookup
test_url_domains()
{
	local list lists list_cat list_author url mirror all_urls type format dom \
		set_id="${1:?}"

	for type in block ipv4_block allow
	do
		for format in ${ALL_LIST_FORMATS:?}
		do
			local list_cat="${format}_${type}_lists"
			get_bl_param_gl_var _ "${list_cat}" || continue # ignore invalid combinations
			local "${list_cat}="
			get_params "${set_id}" lists="${list_cat}"

			[ -z "${lists}" ] && continue
			for list in ${lists}
			do
				case "${list}" in
					'') continue ;;
					hagezi:*|oisd:*|stevenblack:*)
						list_author="${list%%":"*}"
						eval "mirror=\"\${${list_author}_default_mirror}\""
						eval "url=\"\${${list_author}_${mirror}_url}\""
						[ -n "${url}" ] ;;
					*) url="${list}"
				esac &&
				! is_included "${url}" "${TESTED_URLS}" "${_NL_}" &&
				all_urls="${all_urls:+"${all_urls}${_NL_}"}${url}"
			done
		done
	done

	[ -n "${all_urls}" ] || return 0

	reg_action "Testing connectivity." || exit 1
	debug_msg "URLs:${_NL_}${all_urls}"

	printf '%s\n' "${all_urls}" |
	${SED_CMD:?} -n '/http/{s~^http[s]*[:]*[/]*~~g;s~/.*~~;/^$/d;p;}' |
	${SORT_CMD:?} -u |
	while IFS="${_NL_}" read -r dom || [ -n "${dom}" ]
	do
		[ -n "${dom}" ] || continue
		try_lookup_domain "${dom}" "127.0.0.1" 2 ||
			{ reg_failure "Lookup of '${dom}' failed."; exit 1; }
	done || return 1
	TESTED_URLS="${TESTED_URLS:+"${TESTED_URLS}${_NL_}"}${all_urls}"
	:
}

# 1 - var name for output
# 2 - list URL or short identifier
# 3 - list format (raw|dnsmasq)
# 4 - DL mirror
# shellcheck disable=SC2329
get_list_url()
{
	local base_url prefix suffix raw_suffix dnsmasq_suffix hosts_suffix \
		res_url list_author list_name lists list_id_lc formats \
		mirrors first_mirror \
		out_var="${1}" list_id="${2}" format="${3}" mirror="${4}"

	unset_vars "${out_var}"

	case "${format}" in raw|dnsmasq|hosts) ;; *) reg_failure "Unexpected list format '${format}'."; return 1; esac

	tolower list_id_lc "${list_id}"
	case "${list_id_lc}" in hagezi:*|oisd:*|stevenblack:*) ;; *)
		export -n "${out_var}=${list_id}"
		return 0
	esac
	list_id="${list_id_lc}"

	list_author="${list_id%%\:*}" list_name="${list_id#*\:}"

	eval "lists=\"\${${list_author}_lists}\""
	eval "base_url=\"\${${list_author}_${mirror}_url}\""
	[ -n "${base_url}" ] || { reg_failure "Failed to get base URL for ${list_author} mirror '${mirror}'."; return 1; }

	is_included "${list_name}" "${lists}" || { reg_failure "Unknown ${list_author} list '${2}'."; return 1; }

	eval "formats=\"\${${list_author}_formats}\""
	is_included "${format}" "${formats}" ||
		{ reg_failure "${list_id} is only available in formats: ${formats}."; return 1; }

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

	eval "suffix=\"\${${format}_suffix}\""
	res_url="${prefix}${suffix}"
	[ -n "${res_url}" ] || { reg_failure "Failed to construct URL for list identifier '${list_id}'."; return 1; }

	: "${raw_suffix}" "${dnsmasq_suffix}" "${hosts_suffix}"
	export -n "${out_var}=${res_url}"
}


# JOB SCHEDULER FUNCTIONS

# get current job PID
# 1 - var name for output
get_curr_job_pid()
{
	local __pid pid_line
	unset_vars "${1}"
	IFS="${_NL_}" read -r -n512 -d '' _ _ _ _ _ pid_line _ < /proc/self/status
	__pid="${pid_line##*[^0-9]}"
	is_uint "${__pid}" || { reg_failure "Failed to get current job PID."; return 1; }
	export -n "${1}=${__pid}"
}

# sets var named $1 to remaining time based on $PROCESSING_TIMEOUT_S or to $IDLE_TIMEOUT_S, whichever is lower
# if timeout is hit, returns 1
# 1 - var name to output remaining time
get_remaining_time()
{
	local ct_curr_time_cs ct_curr_time_s ct_total_time_s ct_remaining_time_s
	export -n "${1}"=0

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
	export -n "${1}=${ct_remaining_time_s}"
}

# 1 - job PID
# 2 - job return code
handle_done_job()
{
	local me=handle_done_job \
		done_id fail_act_msg \
		done_pid="${1}" done_job_rv="${2}"
	[ -n "${done_pid}" ] || { reg_failure "${me}: received empty string for PID."; return 1; }
	[ -n "${done_job_rv}" ] || { reg_failure "${me}: received empty string instead of return code for job ${done_pid}."; return 1; }

	subtract_a_from_b "${done_pid}" "${RUNNING_PIDS}" RUNNING_PIDS
	RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT-1))

	if [ "${done_job_rv}" != 0 ]
	then
		eval "done_id=\"\${JOB_PRINT_ID_${done_pid}}\""
		fail_act_msg="Skipping file and continuing."
		[ "${blockset_part_failed_action}" = "STOP" ] && fail_act_msg="blockset_part_failed_action is set to 'STOP', exiting."

		reg_failure "" "Processing job (PID ${done_pid:-unknown}) for list '${done_id:-unknown}' returned error code '${done_job_rv}'." "${yellow}${fail_act_msg}${n_c}"
		[ "${blockset_part_failed_action}" = STOP ] && return 1
	fi
	:
}

# 1: list types (allow|block|ipv4_block)
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
			rm -rf "${PROCESSED_PARTS_DIR}"
		}
		rm -f "${sched_cb_fifo}"
		exit "${1}"
	}

	local list_type format index list_indexes \
		remaining_time_s \
		done_pid done_rv \
		origin print_id \
		scheduler_pid \
		RUNNING_PIDS \
		RUNNING_JOBS_CNT=0 \
		list_types="${1:?}"

	get_curr_job_pid scheduler_pid || finalize_scheduler 1

	trap 'USR_TRIG=1 finalize_scheduler 1' USR1

	local sched_cb_fifo="${SCHEDULE_DIR:?}/scheduler_callback_${scheduler_pid}"
	mkfifo "${sched_cb_fifo}" &&
	exec 3<>"${sched_cb_fifo}" || { reg_failure "Failed to create FIFO '${sched_cb_fifo}'."; finalize_scheduler 1; }

	for list_type in ${list_types}
	do
		eval "list_indexes=\"\${proc_indexes_${list_type}}\""
		[ -n "${list_indexes}" ] || continue

		for index in ${list_indexes}
		do
			get_remaining_time remaining_time_s || finalize_scheduler 1

			# wait for job vacancy
			while [ "${RUNNING_JOBS_CNT}" -ge "${PARALLEL_JOBS}" ] && [ -e "${sched_cb_fifo}" ] &&
				read -t "${remaining_time_s}" -r done_pid done_rv < "${sched_cb_fifo}"
			do
				get_remaining_time remaining_time_s &&
				handle_done_job "${done_pid}" "${done_rv}" || finalize_scheduler 1
			done

			get_remaining_time remaining_time_s || finalize_scheduler 1

			eval \
				"format=\"\${FORMAT_${index}}\"" \
				"origin=\"\${ORIGIN_${index}}\"" \
				"print_id=\"\${PRINT_ID_${index}}\""
			assert_set "F_schedule_jobs" format origin print_id || finalize_scheduler 1

			RUNNING_JOBS_CNT=$((RUNNING_JOBS_CNT+1))
			process_set_part "${index}" "${list_type}" "${format}" "${origin}" "${print_id}" "${scheduler_pid}" &

			RUNNING_PIDS="${RUNNING_PIDS} ${!}"
			export -n "JOB_PRINT_ID_${!}"="${print_id}"
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
# 4: blockset ID
# 5: scheduler PID
# the rest of the args passed as-is to workers
#
# return codes:
# 0 - Success
# 1 - Fatal error (stop processing)
# 2 - Download failure
# 3 - Processing failure
# shellcheck disable=SC2317,SC2329
process_set_part()
{
	finalize_job()
	{
		[ -n "${2}" ] && reg_failure "${me}: ${2}"
		case "${1}" in
			0)
				local list_size_human stats_pad suffix_pad
				bytes2human list_size_human "${part_size_B}" -p
				get_pad stats_pad "${print_id}" 42
				get_pad suffix_pad "${cnt_human}" 8
				log_msg "Successfully processed list:    ${green}${print_id}${n_c} ${stats_pad}[ ${orange}${list_size_human}${n_c}  - ${suffix_pad}${orange}${cnt_human} entries${n_c} ]" ;;
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

	dl_list() { ${UCL_CMD:?} "${1}" -O- --timeout=3 2> "${ucl_err_file}"; }

	conv_dnsmasq_to_raw()
	{
		local conv_prefix='s~^[ \t]*(local|server|address)=/~~' conv_suffix
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

	local me=process_set_part \
		curr_job_pid msg msg_mirr \
		pad print_id_pad mirror_pad \
		print_id origin \
		list_path list_author mirrors mirror curr_mirror first_mirror loop_prev_mirror \
		min_entries \
		index="${1:?}" list_type="${2:?}" format="${3:?}" origin="${4:?}" print_id="${5:?}" scheduler_pid="${6:?}"

	debug_msg "${me}: index: ${index}; list_type: ${list_type}; format: ${format}; origin: ${origin}; print_id: ${print_id}; scheduler_pid: ${scheduler_pid}"

	get_curr_job_pid curr_job_pid || finalize_job 1

	eval "min_entries=\"\${min_${list_type}_part_entries}\""

	list_path="${print_id}"

	if [ "${origin}" = DL ] &&
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

	local dest_file="${PROCESSED_PARTS_DIR}/${list_type}_${index}${INTERM_COMPR_EXT}" \
		ucl_err_file="${ABL_TMP_DIR}/ucl_err_${index}" \
		rogue_el_file="${ABL_TMP_DIR}/rogue_el_${index}" \
		list_stats_file="${ABL_TMP_DIR}/${index}_stats" \
		part_cnt cnt_human min_entries_human \
		part_size_B retry=1 \
		fetch_cmd \
		part_compr_or_cat="${INTERM_COMPR_OR_CAT_STDOUT:?}" \
		format_conv_or_cat="${CAT_CMD:?}" \
		case_conv_or_cat="${CAT_CMD:?}" \
		pipeline_msg ucl_err pipeline_rv

	case "${origin}" in
		DL) fetch_cmd=dl_list ;;
		LOCAL) fetch_cmd="${CAT_CMD:?}" ;;
		*) finalize_job 1 "Invalid list origin '${origin}'."
	esac

	case "${list_type}" in
		allow|block) val_entry_regex='^[[:alnum:]-]+$|^(\*|[[:alnum:]_-]+)([.][[:alnum:]_-]+)+$' ;;
		ipv4_block) val_entry_regex='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$' ;;
		*) finalize_job 1 "Invalid list type '${list_type}'"
	esac

	case "${format}" in
		dnsmasq|hosts) format_conv_or_cat="conv_${format}_to_raw ${list_type}"
	esac

	case "${list_type}" in
		allow|block) case_conv_or_cat="case_conv"
	esac

	while :
	do
		# use forced mirror for this list author if set
		if [ "${origin}" = DL ] && [ -n "${list_author}" ]
		then
			read_str_from_file -v curr_mirror -f "${SCHEDULE_DIR}/${list_author}-forced-mirror" -a 1 -q -n 128 -V "${curr_mirror}"
			get_list_url list_path "${print_id}" "${format}" "${curr_mirror}" || finalize_job 1
		fi

		get_pad mirror_pad "${curr_mirror}" 8
		msg_mirr=
		[ -n "${curr_mirror}" ] && msg_mirr=" [   mirror: ${curr_mirror}${mirror_pad} ]"

		rm -f "${rogue_el_file}" "${list_stats_file}" "${ucl_err_file}"

		msg="Processing ${format} ${list_type}list"
		get_pad pad "${msg}" 30
		get_pad print_id_pad "${print_id}" 42

		reg_msg "${msg}: ${pad}${lblue}${print_id}${n_c}${msg_mirr:+"${print_id_pad}"}${msg_mirr}"

		# Download or cat the list
		${fetch_cmd} "${list_path}" |

		# Limit size
		{
			head -c "${max_part_size_KB:?}k"
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

		# check lists for rogue elements
		tee >(${SED_CMD} -nE "/${val_entry_regex}/d;p;:1 n;b1" > "${rogue_el_file}") |

		# compress or cat
		${part_compr_or_cat} > "${dest_file}"

		pipeline_rv=${?}

		# read stats
		read_str_from_file -v "part_cnt part_size_B _" -f "${list_stats_file}" -a 2 -D "list stats" || finalize_job 1

		# size-exceeded check
		if ! [ $(( 1 + part_size_B / 1024)) -lt "${max_part_size_KB}" ]
		then
			reg_failure "" "Size of blockset part '${print_id}' reached the maximum value set in config (${max_part_size_KB} KB)."
			log_msg "Consider either increasing this value in the config or removing the corresponding blockset part identifier or URL from config."
			finalize_job 2
		fi

		if [ "${pipeline_rv}" = 0 ]
		then
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

				case "${rogue_element}" in *"${CR_LF}"*)
					log_msg -warn "blockset part '${print_id}' contains Windows-format (CR LF) newlines." \
						"This file needs to be converted to Unix newline format (LF)."
						finalize_job 3 ;;
				esac

				log_msg -warn "${rogue_el_print} identified in blockset part '${print_id}'."
				[ -n "${rogue_element}" ] || finalize_job 3
			fi

			# min_entries check
			int2human cnt_human "${part_cnt}" || finalize_job 1    # ${cnt_human} also used in finalize_job()

			local lines_cnt_low=
			if [ "${origin}" = DL ] && [ "${part_cnt}" -lt "${min_entries}" ]
			then
				lines_cnt_low=1
				int2human min_entries_human "${min_entries}" || finalize_job 1
				reg_failure "Entries count in downloaded blockset part '${print_id}' is ${cnt_human}, which is less than configured minimum: ${min_entries_human}."
			fi
		fi

		[ "${pipeline_rv}" = 0 ] || pipeline_msg="Processing pipeline returned code ${pipeline_rv}."
		if [ "${origin}" = DL ] &&
		{
			[ "${pipeline_rv}" != 0 ] ||
			[ -n "${lines_cnt_low}" ] ||
			[ -n "${rogue_element}" ] ||
			! grep -q "Download completed" "${ucl_err_file}"
		}
		then
			[ -s "${ucl_err_file}" ] && ucl_err=" uclient-fetch output: ${_NL_}'$(cat "${ucl_err_file}")'."
			rm -f "${ucl_err_file}"
			reg_failure "" "Failed download attempt for list '${print_id}'.${pipeline_msg:+ }${pipeline_msg}${ucl_err}"
			[ -n "${ucl_err}" ] && log_msg "${ucl_err}"
		elif [ "${pipeline_rv}" != 0 ]
		then
			reg_failure "" "${pipeline_msg}"
			finalize_job 1
		else
			rm -f "${ucl_err_file}"
			# set this mirror as forced if this is not the first DL attempt
			[ "${origin}" = DL ] && [ -n "${list_author}" ] && [ "${retry}" != 1 ] &&
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

		if [ "${origin}" = DL ] && [ -n "${list_author}" ]
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

gen_set_parts()
{
	# shellcheck disable=SC2034
	local INITIAL_UPTIME_S="${1:?}" list_types="${2:-"${ALL_LIST_TYPES}"}"

	# clean up before processing
	rm -rf "${PROCESSED_PARTS_DIR}" "${SCHEDULE_DIR}"

	try_mkdir -p "${SCHEDULE_DIR}" &&
	try_mkdir -p "${PROCESSED_PARTS_DIR}" || return 1

	reg_action -1 -purple "" "Downloading and processing blockset parts (max parallel jobs: ${PARALLEL_JOBS})."

	# Asynchronously download and process parts, allowlist must be processed separately and first
	schedule_jobs "${list_types}" &
	SCHEDULER_PID=${!}

	wait "${SCHEDULER_PID}"
	local sched_rv=${?}
	SCHEDULER_PID=
	[ ${sched_rv} = 0 ] || return ${sched_rv}

	reg_msg -green "" "Successfully generated preprocessed blockset files."
	:
}

gen_blocksets()
{
	local \
		me=gen_blocksets \
		IFS="${DEFAULT_IFS}" \
		processed_bl_file \
		set_id \
		run_state \
		curr_path \
		curr_cnt \
		curr_persist_path \
		curr_persist_cnt \
		conn_check_req \
		skip_load_stop \
		file_to_bk \
		bk_file \
		bk_ext \
		final_compr_ext \
		blocksets_to_stop \
		force_unload_bl \
		force_unload="${unload_blockset_before_update:?}" \
		install_path \
		totalmem \
		TESTED_URLS \
		\
		raw_block_lists \
		dnsmasq_block_lists\
		hosts_block_lists \
		local_list \
		\
		all_process_lists \
		dl_lists \
		\
		list_type format \
		proc_index=0 \
		set_indexes \
		proc_set_ids \
		blocksets_out_var="${1:?}" set_ids="${2:?}" initial_uptime_cs="${3:?}"

	: "${skip_load_stop}" "${bk_cnt}"

	reg_msg -fb "${set_ids}" "" "Preparing to generate blockset file{}."

	if [ "${force_unload}" = auto ]
	then
		read -r _ totalmem _ < /proc/meminfo
		if is_uint "${totalmem}" && [ "${totalmem}" -ge 410000 ]
		then
			force_unload=0
		else
			force_unload=1
		fi
	fi

	# Prepare processing for all blocksets
	local no_local_found_msgs
	for set_id in ${set_ids}
	do
		for list_type in ${ALL_LIST_TYPES}
		do
			for format in ${ALL_LIST_FORMATS:?}
			do
				[ "${format}" = raw ] &&
				[ "${list_type}" != ipv4_block ] || continue
				eval "local_list=\"\${local_${list_type}list_path_${set_id}}\""
				{ [ -n "${local_list}" ] && [ -f "${local_list}" ]; } ||
				{
					export -n "local_${list_type}list_path_${set_id}="
					no_local_found_msgs="${no_local_found_msgs}${no_local_found_msgs:+"${_NL_}"}${set_id}:No local ${list_type}list identified{}."
				}
			done
		done
	done

	[ -n "${no_local_found_msgs}" ] &&
	{
		printf '\n' > "${MSGS_DEST}"
		IFS="${_NL_}"
		for msg in ${no_local_found_msgs}
		do
			IFS="${DEFAULT_IFS}"
			set_id="${msg%%:*}"
			reg_msg -fb "${set_id}" "${msg#"${set_id}:"}"
		done
		IFS="${DEFAULT_IFS}"
	}

	for format in ${ALL_LIST_FORMATS:?}
	do
		local "all_process_lists_${format}="
		for list_type in ${ALL_LIST_TYPES}
		do
			local "proc_indexes_${list_type}="

			for set_id in ${set_ids}
			do
				local "set_indexes_${set_id}="

				local_list=
				eval "dl_lists=\"\${${format}_${list_type}_lists_${set_id}}\""
				[ "${format}" = raw ] && eval "local_list=\"\${local_${list_type}list_path_${set_id}}\""
				[ -n "${dl_lists}${local_list}" ] || continue

				[ -n "${dl_lists}" ] &&
				{
					invalid_urls="$(printf %s "${dl_lists}" | tr ' ' '\n' | grep -E '^(http[s]*://)*(www\.)*github\.com')" &&
					{
						reg_failure "Invalid URLs detected:" "${invalid_urls}"
						return 1
					}

					[ "${format}" = raw ] &&
					{
						bad_hagezi_urls="$(printf %s "${dl_lists}" | tr ' ' '\n' | grep '/hagezi/.*/dnsmasq/')" &&
						{
							reg_failure "Following Hagezi URLs are in dnsmasq format and should be either changed to raw list URLs" \
								"or moved to one of the 'dnsmasq_' config entries:" "${bad_hagezi_urls}"
							return 1
						}
						case "${list_type}" in block|allow)
							bad_hagezi_urls="$(
								printf %s "${dl_lists}" |
								tr ' ' '\n' |
								${SED_CMD} -En '/(raw.githubusercontent.com\/hagezi\/dns-blocklists\/|gitlab.com\/hagezi\/mirror\/)/{/onlydomains\./d;p;}'
							)"
							[ -z "${bad_hagezi_urls}" ] ||
							{
								reg_failure "Following Hagezi URLs are missing the '-onlydomains' suffix in the filename:" \
									"${bad_hagezi_urls}"
								return 1
							}
						esac
					}
				}

				for list in ${dl_lists}
				do
					add2list "all_process_lists_${format}" "${list}" "${_NL_}"
				done
				[ -n "${local_list}" ] && add2list "all_process_lists_${format}" "local=${local_list}" "${_NL_}"
			done
		done
	done


	for format in ${ALL_LIST_FORMATS:?}
	do
		eval "all_process_lists=\"\${all_process_lists_${format}}\""
		[ -n "${all_process_lists}" ] || continue

		debug_msg "all_process_lists_${format}: '${all_process_lists}'"

		IFS="${_NL_}"
		for list in ${all_process_lists}
		do
			[ -n "${list}" ] || continue
			IFS="${DEFAULT_IFS}"
			proc_index=$((proc_index+1))
			export -n "INDEX_REFS_${proc_index}="

			origin=DL
			case "${list}" in local=*)
				origin=LOCAL
			esac
			export -n \
				"FORMAT_${proc_index}=${format}" \
				"ORIGIN_${proc_index}=${origin}" \
				"PRINT_ID_${proc_index}=${list#"local="}"

			for list_type in ${ALL_LIST_TYPES:?}
			do
				for set_id in ${set_ids}
				do
					eval "dl_lists=\"\${${format}_${list_type}_lists_${set_id}}\""
					eval "local_list=\"\${local_${list_type}list_path_${set_id}}\""
					[ -n "${dl_lists}${local_list}" ] || continue

					is_included "${list}" "${dl_lists}" ||
					{ [ -n "${local_list}" ] && [ "${list}" = "local=${local_list}" ]; } ||
						continue

					add2list "INDEX_REFS_${proc_index}" "${set_id}"
					add2list "proc_indexes_${list_type}" "${proc_index}"
					add2list proc_set_ids "${set_id}"
					add2list "set_indexes_${set_id}" "${proc_index}"
					export -n "TYPE_${set_id}_${proc_index}=${list_type}"
				done
			done
		done
		IFS="${DEFAULT_IFS}"
	done

	[ -n "${proc_set_ids}" ] || { reg_failure "Nothing to process."; return 1; }

	for set_id in ${set_ids}
	do
		is_included "${set_id}" "${proc_set_ids}" || { reg_failure -fb "${set_id}" "Nothing to process{}."; continue; }
		debug_msg "Processing bockset ${set_id}."
		get_params -f "${me}" "${set_id}" run_state || return 1
		get_params "${set_id}" \
			curr_path \
			curr_cnt \
			curr_persist_path \
			curr_persist_cnt \
			bk_ext \
			raw_block_lists \
			dnsmasq_block_lists\
			hosts_block_lists

		[ -n "${raw_block_lists}${dnsmasq_block_lists}${hosts_block_lists}" ] ||
			log_msg -yellow "" "NOTE: No URLs specified for blocklist download."

		skip_load_stop=
		conn_check_req=1
		force_unload_bl=${force_unload}

		case "${run_state}" in
			0) ;;
			3|4) force_unload_bl=0 conn_check_req='' skip_load_stop=1 ;;
			*) reg_failure -fb "${set_id}" "${me}: unexpected run state '${run_state}'{}."; exit 1
		esac

		[ "${force_unload_bl}" = 1 ] ||
		[ -z "${conn_check_req}" ] ||
		test_url_domains "${set_id}" ||
			force_unload_bl=1

		[ "${force_unload_bl}" = 1 ] &&
			{ add2list blocksets_to_stop "${set_id}"; skip_load_stop=1; }

		set_params "${set_id}" skip_load_stop

		bk_file=
		file_to_bk=
		if [ -n "${curr_path}" ]
		then
			file_to_bk=${curr_path}
			bk_cnt=${curr_cnt}
		elif [ -n "${curr_persist_path}" ]
		then
			file_to_bk=${curr_persist_path}
			bk_cnt=${curr_persist_cnt}
		fi

		if [ -n "${file_to_bk}" ] &&
		{
			[ -f "${file_to_bk}" ] || { file_to_bk=''; false; }
		} &&
		is_dir_writable "${set_id}" "${file_to_bk%/*}"
		then
			bk_file="${BK_SET_BASE_PATH:?}-${set_id}${bk_ext}"
			reg_action -fb "${set_id}" "Creating backup of current blockset file{}." &&
			mv_blockset "${file_to_bk}" "${bk_file}" "${INTERM_COMPR_TO_FILE}" "${set_id}" ||
			{
				reg_failure "Failed to create backup of current blockset file '${file_to_bk}'."
				rm_if_writable "${set_id}" "${file_to_bk}"
				bk_file=
				bk_cnt=
			}
		elif [ -n "${file_to_bk}" ]
		then
			# for persistent blockset in 'manual' mode, the original file is used as a backup
			bk_file="${file_to_bk}"
		else
			reg_msg -2 -fb "${set_id}" "No existing blockset file found{}."
		fi
		set_params "${set_id}" bk_file bk_cnt
	done

	KEEP_BK=1 KEEP_PERSIST=0 rm_blocksets "${proc_set_ids}"
	[ -z "${blocksets_to_stop}" ] || KEEP_BK=1 KEEP_PERSIST=0 do_stop "${blocksets_to_stop}" || return 1

	gen_set_parts "$(( ${initial_uptime_cs:?} / 100 ))" ||
	{
		reg_failure "Failed to generate blockset parts."
		return 1
	}

	for set_id in ${proc_set_ids}
	do
		eval "set_indexes=\"\${set_indexes_${set_id}}\""
		get_params -f "${me}" "${set_id}" install_path || return 1
		get_params "${set_id}" final_compr_ext

		processed_bl_file="${ABL_TMP_DIR}/processed-${set_id}${final_compr_ext}"

		if gen_blockset "${set_id}" "${processed_bl_file}" "${set_indexes}" &&
			try_mv "${processed_bl_file}" "${install_path}"
		then
			add2list "${blocksets_out_var}" "${set_id}"
			debug_msg "install_path: ${install_path};"
		else
			rm -f "${processed_bl_file}"
			reg_failure -fb "${set_id}" "Failed to generate new blockset file{}."
		fi
	done
}


# 1: blockset ID
# 2: output file path
# shellcheck disable=SC2329
gen_blockset()
{
	rm_allow_domains()
	{
		${AWK_CMD:?} 'NR==FNR { if ($0 ~ /^\*\./) { allow_wild[substr($0,3)]; next }; allow[$0]; next }
			{ n=split($1,arr,"."); addr = arr[n]; for ( i=n-1; i>=1; i-- )
			{ addr = arr[i] "." addr; if ( (i>1 && addr in allow_wild) || addr in allow ) next } } 1' "${merged_allow_f:?}" -
	}

	whitelist_filter()
	{
		# only print subdomains of allowlist domains
		${AWK_CMD:?} 'NR==FNR { if ($0 !~ /^\*/) { allow[$0] }; next } { n=split($1,arr,"."); addr = arr[n];
			for ( i=n-1; i>1; i-- ) { addr = arr[i] "." addr; if ( addr in allow ) { print $1; next } } }' "${merged_allow_f:?}" -
	}

	# convert to dnsmasq format and pack 4 input lines into 1 output line
	# input from STDIN, output to STDOUT
	# 1 - block|allow
	pack_entries_sed()
	{
		case "$1" in
			block)
				# packs 4 domains in one 'local=/.../' line
				${SED_CMD:?} "/^$/d;s~^.*$~local=/&/~;\$!{n;a /${_NL_}};\$!{n;a /${_NL_}};\$!{n; a /${_NL_}};a @" ;;
			allow)
				# packs 4 domains in one 'server=/.../#'' line
				{ cat; printf '\n'; } | ${SED_CMD:?} '/^$/d;$!N;$!N;$!N;s~\n~/~g;s~^~server=/~;s~/*$~/#@~' ;;
			*) printf ''; return 1
		esac | tr -d '\n' | tr "@" '\n'
	}

	# convert to dnsmasq format and pack input lines into 1024 characters-long lines
	# input from STDIN, output to STDOUT
	# 1 - block|allow
	pack_entries_awk()
	{
		local entry_type len_lim=1024 allow_char
		case "$1" in
			block) entry_type=local ;;
			allow) entry_type=server allow_char="#" ;;
		esac

		len_lim=$((len_lim-${#entry_type}-${#allow_char}-2))
		${AWK_CMD:?} -v ORS="" -v M="${len_lim}" -v A="${allow_char}" -v T="${entry_type}" '
			BEGIN {al=0; r=0; s=""}
			NF {
				r=r+1
				if (r==1) {print T "=/"}
				l=length($0)
				n=al+1+l
				if (n<=M) {al=n; print $0 "/"; next}
				else {print A "\n" T "=/" $0 "/"; al=l+1}
			}
			END {print A "\n"}'
	}

	# 1 - blockset ID
	# 2 - extension incl '.'
	# 2 - list type (block|ipv4_block)
	# 3 - decompression command or 'cat'
	print_set_parts()
	{
		print_file_cb()
		{
			${PART_EXTR_OR_CAT_STDOUT:?} "${1}"
			local index_refs rv=${?}

			eval "index_refs=\"\${INDEX_REFS_${index}}\""
			[ -z "${index_refs}" ] && rm -f "${1}"
			return "${rv}"
		}

		local index \
			list_type="${1:?}" set_id="${2:?}" set_indexes="${3:?}"

		for index in ${set_indexes}
		do
			FF_EXEC="print_file_cb {}" \
				find_files _ "${PROCESSED_PARTS_DIR}" "${list_type}_${index}" "" "${INTERM_COMPR_EXT}" "${set_id}" && printed=1
		done
		[ -n "${printed}" ] || printf ''
	}

	local me=gen_blockset \
		install_path \
		min_good_entries min_good_entries_human \
		max_blockset_file_size_KB \
		errors \
		dedup_cmd_or_cat="${CAT_CMD:?}" \
		allow_filter_or_cat="${CAT_CMD:?}" \
		pack_cmd="pack_entries_sed" \
		final_compr_or_cat_stdout \
		install_1_instance \
		use_allowlist use_ipv4_blocklist \
		merged_allow_f="${PROCESSED_PARTS_DIR}/allow" \
		test_domains \
		whitelist_mode \
		\
		set_id="${1:?}" \
		out_f="${2:?}" \
		set_indexes="${3:?}"

	reg_action -purple -fb "${set_id}" "" "Generating blockset file{}."

	get_params -f "${me}" "${set_id}" \
		install_path \
		max_blockset_file_size_KB \
		min_good_entries\
		final_compr_or_cat_stdout || return 1

	get_params "${set_id}" \
		install_1_instance \
		test_domains \
		whitelist_mode

	debug_msg "${me}: ${set_id}: set_indexes:${set_indexes}; out_f:${out_f}; install_1_instance: ${install_1_instance};"

	case "${PART_EXTR_OR_CAT_STDOUT:?}" in
		"${CAT_CMD:?}") ;;
		*) assert_set "F_${me}" INTERM_COMPR_EXT || return 1
	esac

	local max_size_b=$((max_blockset_file_size_KB*1024))
	[ "${deduplication}" = 1 ] && dedup_cmd_or_cat="${SORT_CMD} -u -"

	case "${AWK_CMD:?}" in
		*gawk) pack_cmd="pack_entries_awk"
	esac

	# shellcheck disable=SC2034
	# Process results
	local part_cnt part_size_B list_cnt_raw list_size_B index list_type print_id index_refs \
		set_cnt_raw=0 set_size_B_raw=0 allow_cnt_raw=0 block_cnt_raw=0 ipv4_block_cnt_raw=0 \
		set_cnt_raw_human set_size_B_raw_human set_size_B set_size_B_human

	rm -f "${PROCESSED_PARTS_DIR:?}/allow" "${ABL_TMP_DIR:?}/block_stats" "${ABL_TMP_DIR}/ipv4_block_stats" "${ABL_TMP_DIR}/allow_stats" "${ABL_TMP_DIR}/abl-too-big.tmp"

	for index in ${set_indexes}
	do
		eval "index_refs=\"\${INDEX_REFS_${index}}\""
		subtract_a_from_b "${set_id}" "${index_refs}" "INDEX_REFS_${index}"

		[ -s "${ABL_TMP_DIR}/${index}_stats" ] || continue

		eval \
			"list_type=\"\${TYPE_${set_id}_${index}}\"" \
			"print_id=\"\${PRINT_ID_${index}}\"" &&
		[ -n "${list_type}" ] &&
		read_str_from_file -v "part_cnt part_size_B" -f "${ABL_TMP_DIR}/${index}_stats" -V 0 &&
		is_uint "${part_cnt}" "${part_size_B}" &&
		set_cnt_raw=$((set_cnt_raw+part_cnt)) &&
		set_size_B_raw=$((set_size_B_raw + part_size_B)) &&
		eval \
			"${list_type}_cnt_raw=\"\$(( ${list_type}_cnt_raw + part_cnt ))\"" \
			"${list_type}_size_B=\"\$(( ${list_type}_size_B + part_size_B ))\"" ||
				{ reg_failure "Failed to read processed stats for blockset part with index ${index} (ID '${print_id}', type '${list_type}')."; return 1; }
	done

	[ "${set_cnt_raw}" -gt 0 ] ||
		{ reg_failure -fb "${set_id}" "Failed to generate preprocessed files with at least one entry{}."; return 1; }

	bytes2human set_size_B_raw_human "${set_size_B_raw}" &&
	int2human set_cnt_raw_human "${set_cnt_raw}" || return 1

	reg_msg "Uncompressed blockset parts size: ${orange}${set_size_B_raw_human}${n_c}, entries count: ${orange}${set_cnt_raw_human}${n_c}."

	local list_cnt_raw_human list_size_B_human
	for list_type in ${ALL_LIST_TYPES}
	do
		# count entries for current list type
		eval "list_cnt_raw=\"\${${list_type}_cnt_raw:-0}\"" \
			"list_size_B=\"\${${list_type}_size_B:-0}\""

		if ! [ "${list_cnt_raw}" -gt 0 ] || ! [ "${list_size_B}" -gt 0 ]
		then
			[ "${list_type}" = block ] &&
			{
				[ "${whitelist_mode}" = 1 ] || {
					bytes2human list_size_B_raw_human "${list_size_B_raw:-0}"
					int2human list_cnt_raw_human "${list_cnt_raw:-0}"
					reg_failure "Total entries count and size of block-entries: ${list_cnt_raw_human}, ${list_size_B_human}."
					return 1
				}
				log_msg -yellow "Whitelist mode is on - accepting empty blocklist."
			}
		elif [ "${list_type}" = ipv4_block ]
		then
			use_ipv4_blocklist=1
		elif [ "${list_type}" = allow ]
		then
			print_set_parts allow "${set_id}" "${set_indexes}" |
			# optional deduplication
			${dedup_cmd_or_cat} >> "${merged_allow_f}" || return 1
			use_allowlist=1
		fi
	done

	case "${use_allowlist}" in
		1) reg_msg "Will remove any (sub)domain matches present in the allowlist from the blockset and append corresponding server entries to the blockset." ;;
		*) reg_msg "Not using any allowlist for blockset processing."
	esac

	reg_msg "Sorting and merging blockset parts into a single blockset file."

	case "${whitelist_mode}" in
	1)
		# only print subdomains of allowlist domains
		use_allowlist=1
		printf '%s\n' ${test_domains} >> "${merged_allow_f}"
		allow_filter_or_cat=whitelist_filter ;;
	*)
		[ "${use_allowlist}" = 1 ] &&
		# remove allowlist domains from blockset
		allow_filter_or_cat=rm_allow_domains
	esac


	# Blockset generation pipeline
	{
		{
			# print blockset parts
			print_set_parts block "${set_id}" "${set_indexes}" |
			# optional deduplication
			${dedup_cmd_or_cat} |

			# Optionally remove allow domains or enforce whitelist-only mode
			${allow_filter_or_cat} |

			# count entries
			tee >(wc -w > "${ABL_TMP_DIR}/block_stats") |

			# pack entries in 1024 characters long lines
			${pack_cmd} block || exit 1

			# print ipv4 blockset parts
			if [ -n "${use_ipv4_blocklist}" ]
			then
				print_set_parts ipv4_block "${set_id}" "${set_indexes}" |
				# optional deduplication
				${dedup_cmd_or_cat} |
				tee >(wc -w > "${ABL_TMP_DIR}/ipv4_block_stats") |
				# add prefix
				${SED_CMD} 's/^/bogus-nxdomain=/' || exit 1
			fi

			# print allowlist parts
			if [ "${use_allowlist}" = 1 ]
			then
				# optional deduplication
				${dedup_cmd_or_cat} < "${merged_allow_f}" |
				tee >(wc -w > "${ABL_TMP_DIR}/allow_stats") |
				# pack entries in 1024 characters long lines
				${pack_cmd} allow || exit 1

				rm -f "${merged_allow_f}"
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
			[ "${install_1_instance}" = 1 ] &&
				printf '%s\n' "address=/${set_id}-${ABL_TEST_DOM_BASE}/#"
			:
		} |

		# limit size
		{ head -c "${max_size_b}"; read -rn1 -d '' && { touch "${ABL_TMP_DIR}/abl-too-big.tmp"; cat 1>/dev/null; } || true; } |

		# compress or cat
		${final_compr_or_cat_stdout} > "${out_f}"
	} 2>"${ERR_F}" ||
		{
			reg_failure "Failed to merge blockset parts into output file '${out_f}'."
			errors="$(cat "${ERR_F}" 2>/dev/null | ${SED_CMD} '/^$/d')"
			rm -f "${out_f}" "${ERR_F}"
			[ -n "${errors}" ] && log_msg "STDERR output:${_NL_}${errors}"
			return 1
		}
	rm -f "${ERR_F}"

	if [ -f "${ABL_TMP_DIR}/abl-too-big.tmp" ]
	then
		rm -f "${out_f}"
		reg_failure -fb "${set_id}" "Final uncompressed blockset file size{} exceeded ${max_blockset_file_size_KB} kiB set in max_blockset_file_size_KB config option!"
		log_msg "Consider either increasing this value in the config or changing the blockset URLs."
		return 1
	fi

	# check total entries count vs min_good_entries
	local read_cnt block_cnt ipv4_block_cnt allow_cnt \
		gen_cnt=0 gen_cnt_human
	for list_type in block ipv4_block allow
	do
		read_cnt=0
		read -r read_cnt 2>/dev/null < "${ABL_TMP_DIR}/${list_type}_stats"
		local "${list_type}_cnt=${read_cnt:-0}"
	done

	gen_cnt=$(( block_cnt + ipv4_block_cnt + allow_cnt ))

	[ "${whitelist_mode}" = 1 ] && gen_cnt=$((gen_cnt-26)) # ignore alphabet entries

	is_uint "${gen_cnt}" || gen_cnt=0

	int2human gen_cnt_human "${gen_cnt}" || return 1

	if [ "${gen_cnt}" -lt "${min_good_entries}" ]
	then
		int2human min_good_entries_human "${min_good_entries}" || return 1
		reg_failure "Entries count (${gen_cnt_human}) is below the minimum value set in config (${min_good_entries_human})."
		return 1
	fi

	# check the final blockset with dnsmasq --test
	reg_action "Checking the processed blockset file with 'dnsmasq --test'." || return 1

	rm -f "${ERR_F}"

	{
		try_extract -stdout "${out_f}" |
		dnsmasq --test -C -
	} 2> "${ERR_F}"

	if [ ${?} != 0 ] || ! grep -q "syntax check OK" "${ERR_F}"
	then
		errors="$(head -n10 "${ERR_F}" | ${SED_CMD} '/^$/d')"
		rm -f "${ERR_F}" "${out_f}"
		reg_failure "dnsmasq test on the processed blockset failed."
		log_msg "Errors:" "${errors:-"No specifics: probably killed because of OOM."}"
		return 2
	fi

	rm -f "${ERR_F}"

	set_size_B=$(get_file_size "${out_f}")
	bytes2human set_size_B_human "${set_size_B:-0}"

	local comp_pr=compressed
	case "${final_compr_or_cat_stdout}" in
		cat|*" cat"|*/cat) comp_pr=uncompressed
	esac

	reg_msg "${green}Final blockset file check passed${n_c} (${comp_pr}, ${orange}${set_size_B_human}${n_c}, ${orange}${gen_cnt_human} entries${n_c})"

	set_params "${set_id}" install_cnt="${gen_cnt}"

	:
}

:
