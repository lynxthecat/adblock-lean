#!/bin/sh
# shellcheck disable=SC3043,SC3001,SC2016,SC2015,SC3020,SC2181,SC2019,SC2018,SC3045,SC3003,SC3060,SC3057

# silence shellcheck warnings
: "${max_file_part_size_KB:=}" "${whitelist_mode:=}" "${list_part_failed_action:=}" "${test_domains:=}" "${compression_util:=}" "${intermediate_compression_options:=}" "${final_compression_options:=}" \
	"${max_download_retries:=}" "${deduplication:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" \
	"${blue:=}" "${green:=}" "${n_c:=}"

BUSYBOX_PATH="/bin/busybox"

PROCESSED_PARTS_DIR="${ABL_TMP_DIR}/list_parts"

ERR_F="${ABL_TMP_DIR}/process-errors"

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

get_compr_util_spec()
{
	local gcu_util_path='' gcu_ext='' \
		util_path_out_var="${1}" ext_out_var="${2}" gcu_util_name="${3}"

	unset_vars "${1}" "${2}" &&
	assert_set F_get_compr_util_spec util_path_out_var ext_out_var gcu_util_name || return 1

	case "${gcu_util_name}" in
		gzip)
			detect_util gcu_util_path gzip "" "/usr/libexec/gzip-gnu" -b &&
			gcu_ext=.gz ;;
		pigz)
			detect_util gcu_util_path "" pigz "/usr/bin/pigz" &&
			gcu_ext=.gz ;;
		zstd)
			detect_util gcu_util_path "" zstd "/usr/bin/zstd" &&
			gcu_ext=.zst ;;
		none) : ;;
		*) reg_failure "Unexpected compression utility '${gcu_util_name}'."; false
	esac ||
	{
		gcu_util_path='' gcu_ext=''
		reg_failure "Compression utility '${gcu_util_name}' can not be used."
		if detect_util gcu_util_path "gzip" "" "/usr/libexec/gzip-gnu" -b
		then
			log_msg "Falling back to gzip compression."
			gcu_ext=.gz
		else
			log_msg "Intermediate and final blocklist compression will be disabled."
			gcu_ext=
		fi
	}

	eval "${util_path_out_var}"='${gcu_util_path}' "${ext_out_var}"='${gcu_ext}'
	: "${gcu_util_path}" "${gcu_ext}"

	:
}

# 1: input file
# 2: command including options
# 3: (optional) var name to output path to compressed file
try_compress()
{
	fail_msg() { reg_failure "${1}${1:+" "}Failed to compress '${tc_inp_file}'."; }
	compr_fail() { fail_msg; rm_if_volatile "${tc_inp_file}"; }

	local me=try_compress tc_cmd tc_ext opts='' \
		tc_inp_file="${1}" tc_cmd="${2}" out_file_var="${3}"

	[ -f "${tc_inp_file}" ] || { fail_msg "${me}: file '${tc_inp_file}' not found."; return 1; }

	unset_vars "${out_file_var}" || { fail_msg; return 1; }

	case "${tc_cmd}" in
		*gzip*|*pigz*) tc_ext=.gz ;;
		*zstd*) tc_ext=.zst ;;
		*) fail_msg "${me}: unexpected command '${tc_cmd}'."; return 1
	esac

	${tc_cmd} "${tc_inp_file}" || { compr_fail; return 1; }

	[ -n "${out_file_var}" ] && eval "${out_file_var}"='${tc_inp_file}${tc_ext}'

	: "${tc_ext}"
	:
}

# 0 (optional): '-stdout' (does not remove source file)
# 1: path to file to extract
try_extract()
{
	extr_failed()
	{
		[ -n "${stdout}" ] || rm_if_volatile "${1}"
		reg_failure "Failed to extract '${1}'."
	}

	local stdout='' \
		ext cmd='' opts='' \
		file_opts='' \
		stdout_opts=''

	[ "${1}" = '-stdout' ] && { stdout=1; shift; }

	get_compr_spec ext cmd "${1}" || { extr_failed; return 1; }

	case "${ext}" in
		*.gz)
			file_opts="-fd"
			stdout_opts="-cd" ;;
		*.zst)
			file_opts=" -fd --rm -q --no-progress"
			stdout_opts="-cd" ;;
		*)
			[ -n "${stdout}" ] || { reg_failure "try_extract: file '${1}' has unexpected extension."; extr_failed "${1}"; return 1; }
			cmd="/bin/busybox cat"
	esac

	if [ -n "${stdout}" ]
	then
		opts="${stdout_opts}"
	else
		opts="${file_opts}"
	fi

	${cmd} ${opts} "${1}" || { extr_failed "${1}"; return 1; }
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
	is_uint "${_elapsed_m}" "${_elapsed_s}" "${elapsed_fp}" && _elapsed_human="${_elapsed_m} m, ${_elapsed_s}.${elapsed_fp} s" || _elapsed_human=unknown
	eval "${1}"='${_elapsed_human}'
	: "${_elapsed_m}" "${_elapsed_s}" "${elapsed_fp}" "${_elapsed_human}"
}


# HELPER FUNCTIONS

get_active_entries_cnt()
{
	local cnt ext rv=1 \
		ga_out_var="${1}" file="${2}"

	unset_vars "${ga_out_var}" &&
	assert_set F_get_active_entries_cnt ga_out_var file &&
	get_compr_spec ext _ "${file}" || return 1

	# ipv4_block prefix doesn't need to be added for counting
	cnt="$(
		if [ -n "${ext}" ]
		then
			try_extract -stdout "${file}"
		else
			/bin/busybox cat "${file}"
		fi |
		${SED_CMD} -E "s~^(server|local)=/~~;/${ABL_TEST_DOMAIN}/d;s~/#{0,1}$~~" | tr '/' '\n' | wc -w
	)"

	[ "${whitelist_mode}" = 1 ] && cnt=$((cnt-26)) # ignore alphabet entries

	if is_uint "${cnt}"
	then
		rv=0
	else
		cnt=0
	fi

	eval "${ga_out_var}"='${cnt}'
	return ${rv}
}

# Env vars:
#   CA_CHECK_DNS: test DNS resolution
#   CA_NOERR: do not print/register errors
#   CA_NOPROGRESS: do not print progress messages
# return values:
# 0 - All checks passed
# 1 - General error
# 2 - The blocklist test domain failed to resolve (blocklist not loaded)
# 3 - One of the test domains failed to resolve
check_active_blocklist()
{
	lookup_failed() { [ -n "${CA_NOERR}" ] || reg_failure "Lookup of test domain '${1}' failed."; }
	cab_print() { [ -n "${CA_NOPROGRESS}" ] || reg_msg "${@}"; }

	reg_action -3 -blue "Checking the active blocklist." || return 1

	local family ip index instance_ns def_ns ns_ips ns_ips_sp

	GDI_NOFORCE=1 get_dnsmasq_instances || return 1

	assert_set F_check_active_blocklist DNSMASQ_INDEXES DNSMASQ_INST_SET || return 1

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
				add2list ns_ips_sp "${blue}${ip}${n_c}" ", "
			done
		done

		cab_print -3 "Testing dnsmasq instance ${index}."
		cab_print -3 "Using following nameservers for DNS resolution verification: ${ns_ips_sp}"

		cab_print -3 -blue "Testing adblocking."

		try_lookup_domain "${ABL_TEST_DOMAIN}" "${ns_ips}" 1 -n || { lookup_failed "${ABL_TEST_DOMAIN}"; return 2; }

		[ -n "${CA_CHECK_DNS}" ] &&
		{
			cab_print -3 -blue "Testing DNS resolution."
			for domain in ${test_domains}
			do
				try_lookup_domain "${domain}" "${ns_ips}" 5 || { lookup_failed "${domain}"; return 3; }
			done
		}
	done

	:
}

get_abl_run_state()
{
	local rv grs_out_var="${1}"
	are_var_names_safe "${grs_out_var}" &&
	assert_set F_get_abl_run_state grs_out_var || return 1

	export "${grs_out_var}=1"
	try_get_abl_run_state
	rv=${?}
	export "${grs_out_var}=${rv}"
	return ${rv}
}

# return codes:
# 0 - running
# 1 - error
# 2 - (reserved)
# 3 - paused
# 4 - stopped
try_get_abl_run_state()
{
	check_fail() { reg_failure "${1}${1:+ }Failed to check adblock-lean run state."; }
	unexp_state() { reg_failure "Inconsistent run state. Adblocking check result: '${dns_check_res}', blocklist file check result: '${file_check_res}'."; }

	[ -n "${DNSMASQ_CONF_DIRS}" ] || { check_fail "\$DNSMASQ_CONF_DIRS is not set."; return 1; }
	local me=get_abl_run_state dir dns_check_res file_check_res

	assert_set "F_${me}" ABL_ENV_SET || return 1

	[ -f "${BL_FILE_CURR}" ]
	file_check_res=${?}

	CA_NOERR=1 check_active_blocklist
	dns_check_res=${?}
	case "${dns_check_res}${file_check_res}" in
		00) return 0 ;;
		01) unexp_state; return 1 ;;
		11|10) check_fail; return 1 ;;
		21) ;;
		20)
			[ -n "${BL_FILE_CURR}" ] && [ "${BL_FILE_CURR}" = "${PERM_BL_FILE_CURR}" ] && return 3
			unexp_state; return 1 ;;
		*) check_fail "${me}: unexpected dns check code '${dns_check_res}${file_check_res}'."; return 1
	esac

	[ -n "${PAUSE_FILE_CURR}" ] && return 3

	return 4
}

# Output via optional vars:
# 1: state var for processing setup: <final_compr:[0|1]${_NL_}multi_inst:[0|1]${_NL_}perm_bl:[0|1]>
# 2: printable missing addnmounts for addnmounts suggestion
# 3: path on ramdisk for new blocklist creation
# 4: path for permanent blocklist creation/loading
# 5: compr util path
# 6: compr extension
# 7: conf_req: 1 if conf-files are required, 0 if not
check_process_features()
{
	feature_unavail() {
		[ -z "${CPF_QUIET}" ] && reg_failure "${1} can not be used because of missing addnmounts in /etc/config/dhcp: ${2}" \
			"Please run 'service adblock-lean setup' to create required addnmount entries."
	}

	local me=check_process_features \
		IFS="${DEFAULT_IFS}" \
		first_conf_dir \
		\
		cpf_paths='' \
		\
		cpf_missing='' \
		\
		cpf_all_req_recomm='' \
		cpf_all_missing_recomm='' \
		\
		compr_allowed=0 \
		perm_allowed=0 \
		multi_inst_allowed=0 \
		\
		cpf_compr_util_path='' \
		cpf_compr_ext='' \
		\
		cpf_conf_req=1 \
		\
		bl_full_fname='' \
		cpf_bl_path_ram='' \
		cpf_bl_path_perm='' \
		\
		bl_full_fname_check='' \
		bl_path_ram_check='' \
		\
		ok_paths='' \
		\
		bl_full_fname_recomm='' \
		cpf_bl_path_ram_recomm='' \
		\
		perm_dir="${PERM_BLOCKLIST_DIR%"/"}" \
		\
		state_var="${1}" \
		all_req_addnm_var="${2}" \
		missing_recomm_var="${3}" \
		bl_path_ram_var="${4}" \
		bl_path_perm_var="${5}" \
		compr_util_path_var="${6}" \
		compr_ext_var="${7}" \
		conf_req_var="${8}"

	debug_msg "Checking processing features${CPF_QUIET:+" (QUIET)"}." 

	unset_vars "${state_var}" "${all_req_addnm_var}" "${missing_recomm_var}" "${bl_path_ram_var}" "${bl_path_perm_var}" "${compr_util_path_var}" "${compr_ext_var}" "${conf_req_var}" &&
	assert_set "F_${me}" DNSMASQ_INDEXES compression_util || return 1


	# Compression
	get_compr_util_spec cpf_compr_util_path cpf_compr_ext "${compression_util}" || return 1

	if [ -n "${cpf_compr_ext}" ]
	then
		bl_full_fname_check=${BLOCKLIST_BASE_FNAME:?}${cpf_compr_ext}
		bl_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname_check}
		cpf_paths="${BUSYBOX_PATH:?}${_NL_}${cpf_compr_util_path%% *}${_NL_}${bl_path_ram_check}"
		check_addnmounts cpf_missing "${cpf_paths}" || return 1

		if [ -z "${cpf_missing}" ]
		then
			compr_allowed=1
			bl_full_fname=${bl_full_fname_check}
			cpf_bl_path_ram=${bl_path_ram_check}
		else
			feature_unavail "Final blocklist compression" "${cpf_missing}"
		fi

		[ -n "${CPF_QUIET}" ] &&
		{
			bl_full_fname_recomm=${BLOCKLIST_BASE_FNAME:?}${cpf_compr_ext}
			cpf_bl_path_ram_recomm=${ABL_RUN_DIR:?}/${bl_full_fname_recomm}
			add2list cpf_all_req_recomm "${cpf_paths}" "${_NL_}" &&
			add2list cpf_all_missing_recomm "${cpf_missing}" ", " || return 1
		}
	fi

	: "${bl_full_fname_recomm:="${BLOCKLIST_BASE_FNAME:?}"}"
	: "${bl_full_fname:="${BLOCKLIST_BASE_FNAME:?}"}"


	# Multiple dnsmasq instances
	case "${DNSMASQ_INDEXES}" in
		*[0-9]*" "*[0-9]*)
			[ -n "${CPF_QUIET}" ] &&
			{
				cpf_bl_path_ram_recomm=${ABL_RUN_DIR:?}/${bl_full_fname_recomm}
				cpf_paths="${BUSYBOX_PATH:?}${_NL_}${cpf_bl_path_ram_recomm}"
				check_addnmounts cpf_missing "${cpf_paths}" &&
				add2list cpf_all_req_recomm "${cpf_paths}" "${_NL_}" &&
				add2list cpf_all_missing_recomm "${cpf_missing}" ", " || return 1
			}

			bl_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname:?}
			cpf_paths="${BUSYBOX_PATH:?}${_NL_}${bl_path_ram_check}"
			check_addnmounts cpf_missing "${cpf_paths}" || return 1
			if [ -z "${cpf_missing}" ]
			then
				cpf_bl_path_ram=${bl_path_ram_check}
				multi_inst_allowed=1
			else
				feature_unavail "Multiple dnsmasq instances" "${cpf_missing}"
			fi ;;
		*)
			first_conf_dir="${DNSMASQ_CONF_DIRS%% *}"
			is_valid_dir "${first_conf_dir}" || return 1
			ok_paths="${first_conf_dir}/${bl_full_fname}${_NL_}${first_conf_dir}/${bl_full_fname_recomm}"

			[ -n "${cpf_bl_path_ram}" ] ||
			{
				cpf_bl_path_ram="${first_conf_dir}/${bl_full_fname}"
				cpf_conf_req=0
			}

			: "${cpf_bl_path_ram_recomm:="${first_conf_dir}/${bl_full_fname_recomm}"}"
	esac

	assert_set "F_${me}" cpf_bl_path_ram_recomm || return 1

	# Permanent blocklist
	case "${PERM_BLOCKLIST_MODE}" in manual|managed)
		[ -n "${CPF_QUIET}" ] &&
		{
			cpf_paths="${BUSYBOX_PATH:?}${_NL_}${perm_dir}"
			is_included "${cpf_bl_path_ram_recomm}" "${ok_paths}" "${_NL_}" ||
				cpf_paths="${cpf_paths}${_NL_}${cpf_bl_path_ram_recomm}"
			check_addnmounts cpf_missing "${cpf_paths}" &&
			add2list cpf_all_req_recomm "${cpf_paths}" "${_NL_}" &&
			add2list cpf_all_missing_recomm "${cpf_missing}" ", " || return 1
		}

		if [ -n "${cpf_bl_path_ram}" ]
		then
			local perm_fail perm_dir_pr="permanent blocklist directory"
			if [ -d "${perm_dir}" ] ||
				{
					case "${PERM_BLOCKLIST_DIR}" in
						'') perm_fail="No path specified in config option PERM_BLOCKLIST_DIR." ;;
						/) perm_fail="Invalid ${perm_dir_pr}: /" ;;
						*) perm_fail="Can not find ${perm_dir_pr}: ${perm_dir}."
					esac
					false
				}
			then
				# alternative path on ramdisk required for fallback
				cpf_paths="${BUSYBOX_PATH:?}${_NL_}${perm_dir}"
				is_included "${cpf_bl_path_ram}" "${ok_paths}" "${_NL_}" ||
					cpf_paths="${cpf_paths}${_NL_}${cpf_bl_path_ram}"
				check_addnmounts cpf_missing "${cpf_paths}" || return 1
				if [ -z "${cpf_missing}" ]
				then
					perm_allowed=1
					[ "${PERM_BLOCKLIST_MODE}" = managed ] && cpf_bl_path_perm="${perm_dir}/${bl_full_fname}"
				else
					feature_unavail "Permanent blocklist" "${cpf_missing}"
				fi
			else
				log_msg -warn "" "${perm_fail}${perm_fail:+ }Permanent blocklist can not be used or updated."
			fi
		fi
	esac

	eval "${state_var:-_}=\"final_compr:\${compr_allowed}\${_NL_}multi_inst:\${multi_inst_allowed}\${_NL_}perm_bl:\${perm_allowed}\""	
	eval "${all_req_addnm_var:-_}"='${cpf_all_req_recomm}'
	eval "${missing_recomm_var:-_}"='${cpf_all_missing_recomm}'
	eval "${conf_req_var:-_}"='${cpf_conf_req}'
	eval "${bl_path_ram_var:-_}"='${cpf_bl_path_ram}'
	eval "${bl_path_perm_var:-_}"='${cpf_bl_path_perm}'
	eval "${compr_util_path_var:-_}"='${cpf_compr_util_path}'
	eval "${compr_ext_var:-_}"='${cpf_compr_ext}'

	: "${cpf_all_req_recomm}" "${multi_inst_allowed}" "${perm_allowed}" "${compr_allowed}" "${cpf_all_missing_recomm}" "${cpf_bl_path_perm}" "${cpf_conf_req}"

	:
}

# Env vars:
#   SAE_FORCE: force env re-processing
#   SAE_FORCE_ONCE: force env re-processing only once
#   SAE_QUIET: do not print errors
# 1 (optional): var name to output all required addnmounts (only when some are missing)
set_abl_env()
{
	[ -n "${SAE_FORCE_ONCE}" ] && { unset SAE_FORCE_ONCE; local SAE_FORCE=1; }
	[ -z "${SAE_FORCE}" ] && [ -n "${ABL_ENV_SET}" ] && return 0
	[ -n "${SAE_QUIET}" ] && SAE_FORCE_ONCE=1 # ensure errors are printed at next non-quiet call

	local me=set_abl_env \
		IFS="${DEFAULT_IFS}" \
		\
		compr_util_path='' \
		compr_ext='' \
		\
		extr_cmd_stdout='' \
		compr_cmd_to_file='' \
		extra_compr_cmd_to_file_opts='' \
		compr_cmd_stdout='' \
		\
		interm_compr_opts='' \
		\
		final_compr_opts='' \
		\
		pause_dir="${ABL_RUN_DIR:?}" \
		\
		bl_dir_new='' \
		\
		par_opt='' \
		cpu_cnt \
		rebuild_perm_bl='' \
		\
		perm_bl_size_b='' \
		perm_bl_entries_cnt=0 \
		perm_bl_cnt_human=''

	export \
		START_ACTION=gen \
		\
		PERM_BLOCKLIST_DIR="${PERM_BLOCKLIST_DIR%"/"}" \
		\
		CONF_FILES_REQ=0 \
		CONF_FILES_REQ_FALLBACK=0 \
		\
		BL_FILE_NEW='' \
		BL_FILE_NEW_FALLBACK='' \
		BL_FILE_CURR='' \
		\
		PAUSE_FILE_CURR='' \
		PAUSE_FILE_NEW="${pause_dir:?}/${PAUSE_BASE_FNAME:?}" \
		\
		BK_BL_FILE='' \
		\
		PERM_BL_FILE_CURR='' \
		\
		LOAD_BL_PATH='' \
		LOAD_BL_SIZE_B='' \
		LOAD_BL_ENTRIES_CNT='' \
		LOAD_BL_DESC='' \
		\
		PARALLEL_JOBS='' \
		\
		PART_EXTR_OR_CAT_STDOUT="/bin/busybox cat" \
		\
		INTERM_COMPR_OR_CAT_STDOUT="/bin/busybox cat" \
		INTERM_COMPR_EXT='' \
		INTERM_COMPR_TO_FILE='' \
		\
		FINAL_COMPRESS='' \
		FINAL_EXTR_OR_CAT_STDOUT="/bin/busybox cat" \
		FINAL_COMPR_OR_CAT_STDOUT="/bin/busybox cat" \
		FINAL_COMPR_EXT='' \
		FINAL_COMPR_TO_FILE=''

	debug_msg "Preparing environment." 

	# Get current blocklist file if any
	local path
	read_str_from_file -v path -f "${LAST_BLOCKLIST_PATH_FILE}" -q -n 512 &&
		is_valid_dir "${path%/*}" && [ -f "${path}" ] &&
			BL_FILE_CURR="${path}"

	# Get current pause file if any
	read_str_from_file -v path -f "${LAST_PAUSE_PATH_FILE}" -q -n 512 &&
		is_valid_dir "${path%/*}" && [ -f "${path}" ] &&
			PAUSE_FILE_CURR="${path}"

	assert_set "F_${me}" DNSMASQ_INDEXES || return 1

	# Parallel processing
	case "${MAX_PARALLEL_JOBS}" in
		auto)
			cpu_cnt="$(grep -c '^processor\s*:' /proc/cpuinfo)"
			if is_uint "${cpu_cnt}"
			then
				# cap PARALLEL_JOBS to 4 in 'auto' mode
				PARALLEL_JOBS=$(( (cpu_cnt>4)*4 + (cpu_cnt<=4)*cpu_cnt ))
			else
				log_msg "Failed to detect CPU core count. Parallel processing will be disabled."
				PARALLEL_JOBS=1
			fi ;;
		*)
			PARALLEL_JOBS="${MAX_PARALLEL_JOBS}"
	esac

	# Check addnmounts, possibility of final compression, multiple dnsmasq instances and permanent blocklist creation,
	#   get final blocklist paths,
	#   compression util path and extension
	local state bl_path_ram bl_path_perm compr_util_path compr_ext \
		final_compr_req='' multi_inst_req='' perm_bl_req='' CPF_QUIET=''

	[ -n "${SAE_QUIET}" ] && CPF_QUIET=1
	check_process_features state _ _ bl_path_ram bl_path_perm compr_util_path compr_ext CONF_FILES_REQ || return 1

	CONF_FILES_REQ_FALLBACK=${CONF_FILES_REQ}

	# Parse state
	local feature_state
	for feature in final_compr multi_inst perm_bl
	do
		feature_state="${state##*"${feature}:"}"
		feature_state="${feature_state%%"${_NL_}"*}"
		case "${feature_state}" in
			[01]) ;;
			*) reg_failure "${me}: invalid state '${feature_state}' for feature '${feature}'."; return 1
		esac
		eval "${feature}_req"='${feature_state}'
	done

	# Interm compr commands
	[ -n "${compr_ext}" ] &&
	{
		# set compr parallelization options, unless specified by the user
		case "${compr_util_path}" in *zstd*|*pigz*)
			case "${compr_util_path}" in
				*zstd*) par_opt=T extra_compr_cmd_to_file_opts="--rm -q --no-progress" ;;
				*pigz*) par_opt=p
			esac
			case "${intermediate_compression_options}" in
				*" -${par_opt}"*) interm_compr_opts="${intermediate_compression_options}" ;;
				*) interm_compr_opts="${intermediate_compression_options} -${par_opt}$((PARALLEL_JOBS/2 + (PARALLEL_JOBS/2<1) ))" # not less than 1
			esac
			case "${final_compression_options}" in
				*" -${par_opt}"*) final_compr_opts="${final_compression_options}" ;;
				*) final_compr_opts="${final_compression_options} -${par_opt}${PARALLEL_JOBS}"
			esac
		esac

		compr_cmd_to_file="${compr_util_path} -f ${extra_compr_cmd_to_file_opts}"
		compr_cmd_stdout="${compr_util_path} -c"
		extr_cmd_stdout="${compr_util_path} -cd"

		# Interm compr commands
		PART_EXTR_OR_CAT_STDOUT="try_extract -stdout"
		INTERM_COMPR_OR_CAT_STDOUT="${compr_cmd_stdout} ${interm_compr_opts}"
		INTERM_COMPR_TO_FILE="${compr_cmd_to_file} ${interm_compr_opts}"
		INTERM_COMPR_EXT="${compr_ext}"
	}

	# Compr final commands, extension and filenames
	[ "${final_compr_req}" = 1 ] &&
	{
		FINAL_COMPRESS=1
		FINAL_COMPR_EXT=${compr_ext}
		FINAL_COMPR_TO_FILE="${compr_cmd_to_file} ${final_compr_opts}"
		FINAL_COMPR_OR_CAT_STDOUT="${compr_cmd_stdout} ${final_compr_opts}"
		FINAL_EXTR_OR_CAT_STDOUT=${extr_cmd_stdout}
	}

	[ "${final_compr_req}" = 1 ] || [ "${multi_inst_req}" = 1 ] &&
		CONF_FILES_REQ=1


	BK_BL_FILE="${BK_BL_BASE_PATH:?}${INTERM_COMPR_EXT}"

	# Perm blocklist
	if [ "${perm_bl_req}" = 1 ]
	then
		if [ "${ABL_INIT_ACTION}" = boot ] || [ "${ABL_INIT_ACTION}" = status ]
		then
			reg_action -3 -blue "Checking the permanent blocklist."
			local file='' perm_ext='' compr_util='' perm_fail='' min_good_line_count_human='' perm_bl_entries_cnt='' perm_bl_cnt_human=''

			if
				{
					FF_RM_EXTRA=1 find_files file "${PERM_BLOCKLIST_DIR}" "${BLOCKLIST_BASE_FNAME:?}" ||
						{
							[ "${PERM_BLOCKLIST_MODE}" = manual ] && PERM_BLOCKLIST_MODE=disable
							perm_fail="Permanent blocklist not found in directory '${PERM_BLOCKLIST_DIR}'."
							false
						}
				} &&

				{
					get_compr_spec perm_ext _ "${file}" ||
						{ perm_fail="Can not find utility to extract permanent blocklist file '${file}'."; false; }
				} &&

				{
					[ "${perm_ext}" = "${FINAL_COMPR_EXT}" ] ||
						{
							perm_fail="Extension '${perm_ext}' of permanent blocklist file '${file}' does not match required extension '${FINAL_COMPR_EXT}'."
							false
						}
				} &&

				perm_bl_size_b="$(get_file_size "${file}")" &&
				{
					[ $(( perm_bl_size_b/1024 )) -le "${max_blocklist_file_size_KB}" ] ||
					{ perm_fail="Permanent blocklist file '${file}' is larger than the maximum value set in config (${max_blocklist_file_size_KB} KiB)."; false; }
				} &&

				{
					get_active_entries_cnt perm_bl_entries_cnt "${file}" ||
						{ perm_fail="Failed to get entries count in the permanent blocklist file '${file}'."; false; }
				} &&

				{
					int2human perm_bl_cnt_human "${perm_bl_entries_cnt}" &&
					int2human min_good_line_count_human "${min_good_line_count}" || return 1
				} &&

				{
					[ "${perm_bl_entries_cnt}" -ge "${min_good_line_count}" ] ||
						{
							perm_fail="Entries count (${perm_bl_cnt_human}) in the permanent blocklist '${file}' is below the minimum value set in config (${min_good_line_count_human})."
							false
						}
				}
			then
				START_ACTION=load

				PERM_BL_FILE_CURR=${file}
				LOAD_BL_PATH=${PERM_BL_FILE_CURR}
				LOAD_BL_SIZE_B=${perm_bl_size_b}
				LOAD_BL_ENTRIES_CNT=${perm_bl_entries_cnt}
				LOAD_BL_DESC="permanent"
				BL_FILE_NEW_FALLBACK=${bl_path_ram}
			else
				local warn_act_msg=''
				[ "${ABL_CMD}" = start ] && [ -z "${SAE_QUIET}" ] && warn_act_msg="Will create a new blocklist on the ramdisk."
				[ "${PERM_BLOCKLIST_MODE}" = managed ] &&
				{
					rebuild_perm_bl=1
					[ "${ABL_CMD}" = start ] &&
					{
						[ -z "${SAE_QUIET}" ] && warn_act_msg="Will rebuild the permanent blocklist."
						rm -f "${file}"
					}
					BL_FILE_NEW=${bl_path_perm}
					BL_FILE_NEW_FALLBACK=${bl_path_ram}
				}
				local warn_msg="${perm_fail}${perm_fail:+ }${warn_act_msg}"
				[ -n "${warn_msg}" ] && log_msg -warn "" "${warn_msg}"
			fi
		elif [ "${PERM_BLOCKLIST_MODE}" = managed ]
		then
			pause_dir=${PERM_BLOCKLIST_DIR:?}
			rebuild_perm_bl=1
			[ "${ABL_CMD}" = start ] && reg_msg -3 "" "Will update the permanent blocklist."
			BL_FILE_NEW=${bl_path_perm}
			BL_FILE_NEW_FALLBACK=${bl_path_ram}
		fi

		[ "${START_ACTION}" = load ] || [ -n "${rebuild_perm_bl}" ] &&
			CONF_FILES_REQ=1
	fi

	: "${BL_FILE_NEW:="${bl_path_ram}"}"

	[ "${START_ACTION}" = load ] || [ -n "${BL_FILE_NEW}" ] ||
		{ reg_failure "No usable path to install or load the blocklist."; return 1; }

	PAUSE_FILE_NEW=${pause_dir:?}/${PAUSE_BASE_FNAME:?}${FINAL_COMPR_EXT}

	export ABL_ENV_SET=1

	debug_msg \
		"Run state: ${ABL_RUN_STATE}" \
		"Shared dir: '${bl_dir_new}'" \
		"Curr blocklist: '${BL_FILE_CURR}'" \
		"New blocklist: '${BL_FILE_NEW}'" \
		"BK file: '${BK_BL_FILE}'" \
		"Curr pause file: '${PAUSE_FILE_CURR}'" \
		"New pause file: '${PAUSE_FILE_NEW}'" \
		"CONF_FILES_REQ: '${CONF_FILES_REQ}'"

	:
}


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

	case "${list_id}" in
		*[A-Z]*) list_id_lc="$(printf '%s' "${list_id}" | tr 'A-Z' 'a-z')" ;;
		*) list_id_lc="${list_id}"
	esac
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
			reg_msg -3 -yellow "" "Stopping unfinished jobs (PIDS: ${RUNNING_PIDS})."
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

		rm -f "${rogue_el_file}" "${list_stats_file}" "${size_exceeded_file}" "${ucl_err_file}"

		msg="Processing ${list_format} ${list_type}list"
		get_pad pad "${msg}" 28

		reg_msg "${msg}: ${pad}${blue}${print_id}${n_c}${msg_mirr}"

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

		# size-exceeded check
		read_str_from_file -v "part_line_count part_size_B _" -f "${list_stats_file}" -a 2 -D "list stats" || finalize_job 1
		if [ -f "${size_exceeded_file}" ]
		then
			reg_failure "Size of ${list_type}list part '${print_id}' reached the maximum value set in config (${max_file_part_size_KB} KB)."
			log_msg "Consider either increasing this value in the config or removing the corresponding ${list_type}list part path or URL from config."
			finalize_job 2
		fi

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
		read_str_from_file -v "part_line_count _" -f "${1}" -a 1 -V 0 || return 1
		list_line_count=$((list_line_count+part_line_count))
	}

	# shellcheck disable=SC2329
	concat_allow_cb()
	{
		/bin/busybox cat "${1}" >> "${PROCESSED_PARTS_DIR}/allow"
		local rv=${?}
		rm -f "${1}"
		return "${rv}"
	}

	local lists schedule_req local_list_path list_format list_type \
		preprocessed_line_count=0 preprocessed_line_count_human \
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
			preprocessed_line_count=$((preprocessed_line_count+1))
		done
		use_allowlist=1
	fi

	reg_action -1 -blue "Downloading and processing blocklist parts (max parallel jobs: ${PARALLEL_JOBS})."

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
						reg_msg -3 "No local ${list_type}list identified."
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
			local part_line_count=0 list_line_count=0
			FF_EXEC="read_stats_cb {}" \
				find_files _ "${ABL_TMP_DIR}" "stats_${list_type}-" || [ ${?} != 1 ] ||
					{ reg_failure "Failed to read processed ${list_type}list parts stats."; return 1; }

			if [ "${list_line_count}" = 0 ]
			then
				case "${list_type}" in
					block)
						[ "${whitelist_mode}" = 0 ] && return 1
						log_msg -yellow "Whitelist mode is on - accepting empty blocklist." ;;
					allow)
						reg_msg -3 "Not using any allowlist for blocklist processing."
				esac
			elif [ "${list_type}" = ipv4_block ]
			then
				use_ipv4_blocklist=1
			elif [ "${list_type}" = allow ]
			then
				reg_msg -3 "Will remove any (sub)domain matches present in the allowlist from the blocklist and append corresponding server entries to the blocklist."
				use_allowlist=1
			fi
			preprocessed_line_count="$((preprocessed_line_count+list_line_count))"
		done
	done

	int2human preprocessed_line_count_human "${preprocessed_line_count}" || return 1
	reg_msg -3 -green "" "Successfully generated preprocessed blocklist file with ${preprocessed_line_count_human} entries."
	:
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
		final_entries_cnt min_good_line_count_human list_type \
		errors max_blocklist_file_size_B=$((max_blocklist_file_size_KB*1024)) \
		dedup_cmd_or_cat="/bin/busybox cat" \
		pack_cmd="pack_entries_sed" \
		entries_cnt_out_var="${1}" out_f="${2}" INITIAL_UPTIME_S="$(( ${3} / 1000 ))"

	unset_vars "${entries_cnt_out_var}" &&
	assert_set "F_${me}" entries_cnt_out_var out_f PART_EXTR_OR_CAT_STDOUT FINAL_EXTR_OR_CAT_STDOUT FINAL_COMPR_OR_CAT_STDOUT &&
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

	reg_action -3 -blue "Sorting and merging the blocklist parts into a single blocklist file." || return 1
	{
		{
			# print blocklist parts
			print_list_parts block "${INTERM_COMPR_EXT}" "${PART_EXTR_OR_CAT_STDOUT}" |
			# optional deduplication
			${dedup_cmd_or_cat} |
			# count entries
			tee >(wc -w > "${ABL_TMP_DIR}/block_entries") |
			# pack entries in 1024 characters long lines
			${pack_cmd} block || exit 1

			# print ipv4 blocklist parts
			if [ -n "${use_ipv4_blocklist}" ]
			then
				print_list_parts ipv4_block "${INTERM_COMPR_EXT}" "${PART_EXTR_OR_CAT_STDOUT}" |
				# optional deduplication
				${dedup_cmd_or_cat} |
				tee >(wc -w > "${ABL_TMP_DIR}/ipv4_block_entries") |
				# add prefix
				${SED_CMD} 's/^/bogus-nxdomain=/' || exit 1
			fi

			# print allowlist parts
			if [ -n "${use_allowlist}" ]
			then
				# optional deduplication
				${dedup_cmd_or_cat} < "${PROCESSED_PARTS_DIR}/allow" |
				tee >(wc -w > "${ABL_TMP_DIR}/allow_entries") |
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

			# add the blocklist test entry
			printf '%s\n' "address=/${ABL_TEST_DOMAIN}/#"
		} |

		# limit size
		{ head -c "${max_blocklist_file_size_B}"; read -rn1 -d '' && { touch "${ABL_TMP_DIR}/abl-too-big.tmp"; cat 1>/dev/null; } || true; } |

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

	local block_entries_cnt ipv4_block_entries_cnt allow_entries_cnt

	for list_type in block ipv4_block allow
	do
		read_list_stats "${list_type}_entries_cnt" "${ABL_TMP_DIR}/${list_type}_entries"
	done

	final_entries_cnt=$(( block_entries_cnt + ipv4_block_entries_cnt + allow_entries_cnt ))

	eval "${entries_cnt_out_var}"='${final_entries_cnt}'
	: "${final_entries_cnt}"
}


stop_dnsmasq()
{
	reg_action -3 -blue "Stopping dnsmasq." || return 1
	/etc/init.d/dnsmasq stop || { reg_failure "Failed to stop dnsmasq."; return 1; }
}

# 1 - blocklist path
# 2 - entries count
# 3 - printable description
test_blocklist()
{
	local entries_cnt_human errors
		test_path="${1}" entries_cnt="${2}" desc="${3}"

	int2human entries_cnt_human "${entries_cnt}" || return 1

	if [ "${entries_cnt}" -lt "${min_good_line_count}" ]
	then
		int2human min_good_line_count_human "${min_good_line_count}" || return 1
		reg_failure "Entries count (${entries_cnt_human}) is below the minimum value set in config (${min_good_line_count_human})."
		return 1
	fi

	# check the final blocklist with dnsmasq --test
	reg_action -3 -blue "Checking the ${desc}${desc:+ }blocklist file with 'dnsmasq --test'." || return 1

	rm -f "${ERR_F}"

	{
		try_extract -stdout "${test_path}" |
		dnsmasq --test -C -
	} 2> "${ERR_F}"

	if [ ${?} != 0 ] || ! grep -q "syntax check OK" "${ERR_F}"
	then
		errors="$(head -n10 "${ERR_F}" | ${SED_CMD} '/^$/d')"
		rm -f "${ERR_F}"
		rm_if_volatile "${test_path}"
		reg_failure "dnsmasq test on the ${desc}${desc:+ }blocklist failed."
		log_msg "Errors:" "${errors:-"No specifics: probably killed because of OOM."}"
		return 2
	fi

	rm -f "${ERR_F}"

	reg_msg -3 -green "New blocklist file check passed."
	:
}

# Env vars:
# CONF_FILES_REQ (0|1): create conf files in dnsmasq dirs
#
# Args:
# 1: final blocklist path
# 2: blocklist size
# 3: entries count
# 4: description
install_blocklist()
{
	local size_b entries_cnt_human list_size_human compr_pr="uncompressed" cpf_compr_ext compr_util dir \
		final_file="${1}" entries_cnt="${2}" desc="${3}"

	assert_set F_install_blocklist final_file desc DNSMASQ_CONF_DIRS FINAL_EXTR_OR_CAT_STDOUT || return 1

	reg_msg -3 -blue "" "Installing ${desc} blocklist file."

	[ -z "${entries_cnt}" ] || int2human entries_cnt_human "${entries_cnt}" || return 1

	size_b="$(get_file_size "${final_file}")" &&
	bytes2human list_size_human "${size_b}" || return 1

	get_compr_spec cpf_compr_ext compr_util "${final_file}" || return 1
	[ -n "${cpf_compr_ext}" ] && compr_pr="${compr_util}${compr_util:+"-"}compressed"

	[ "${CONF_FILES_REQ}" = 1 ] && {
		for dir in ${DNSMASQ_CONF_DIRS}
		do
			is_valid_dir "${dir}" || return 1
			printf '%s\n' "conf-script=\"/bin/busybox sh ${dir}/.abl-extract_blocklist\"" > "${dir}/abl-conf-script" &&
			printf '%s\n%s\n' "${FINAL_EXTR_OR_CAT_STDOUT} \"${final_file}\"" "exit 0" > "${dir}/.abl-extract_blocklist" ||
				{ reg_failure "Failed to create conf-script in directory '${dir}'."; return 1; }
		done
	}

	restart_dnsmasq || return 1

	CA_CHECK_DNS=1 check_active_blocklist || { reg_failure "Active blocklist check failed with the ${desc} blocklist."; return 1; }
	reg_msg -3 -green "" "Active blocklist check passed."

	reg_success "${green}Successfully loaded ${desc} blocklist${n_c}." \
		"Final blocklist file: ${blue}${final_file}${n_c} (${compr_pr}, size: ${blue}${list_size_human}${n_c}${entries_cnt_human:+", entries count: ${blue}${entries_cnt_human}${n_c}"}).${n_c}"

	BL_FILE_CURR="${final_file}"
	printf '%s\n' "${BL_FILE_CURR}" > "${LAST_BLOCKLIST_PATH_FILE}"

	:
}

# Move file ${1} to path ${2} while compressing/extracting/recompressing if required
conv_compr()
{
	try_conv_compr "${@}" && return 0

	local src_path="${1}" dest_path="${2}"
	rm_if_volatile "${src_path}" "${dest_path}"
	return 1
}

try_conv_compr()
{
	local me=conv_compr src_ext='' dest_ext='' src_dir='' dest_dir='' \
		src_path="${1}" dest_path="${2}" compr_cmd="${3}"

	assert_set "F_${me}" src_path dest_path || return 1

	src_dir="${src_path%/*}"
	dest_dir="${dest_path%/*}"

	is_valid_dir "${src_dir}" && is_valid_dir "${dest_dir}" || { reg_failure "${me}: unexpected src dir '${src_dir}' or dest dir '${dest_dir}'."; return 1; }

	[ -f "${src_path}" ] || { reg_failure "File not found at path '${src_path}'."; return 2; }

	[ "${src_path}" = "${dest_path}" ] && return 0

	get_compr_spec src_ext _ "${src_path}" &&
	get_compr_spec dest_ext _ "${dest_path}" || return 1

	[ -z "${dest_ext}" ] || assert_set "F_${me}" compr_cmd || return 1

	if [ -n "${src_ext}" ] && [ "${src_ext}" != "${dest_ext}" ]
	then
		try_extract "${src_path}" || return 1
		src_path="${src_path%.*}"
		src_ext=
	fi

	if [ -n "${dest_ext}" ] && [ -z "${src_ext}" ]
	then
		try_compress "${src_path}" "${compr_cmd}" src_path || return 1
	fi

	# Avoid writing into PERM_BLOCKLIST_DIR unless mode is 'main'
	if [ "${src_dir}" = "${PERM_BLOCKLIST_DIR}" ] && [ "${dest_dir}" != "${src_dir}" ] && [ "${PERM_BLOCKLIST_MODE}" != managed ]
	then
		cp "${src_path}" "${dest_path}"
	else
		try_mv "${src_path}" "${dest_path}"
	fi || return 1

	:
}

export_blocklist()
{
	try_export_blocklist "${@}" && return 0

	local src_path="${1}" dest_path="${2}"
	rm_if_volatile "${src_path}" "${dest_path}"

	reg_failure "Failed to export blocklist '${src_path}' to '${dest_path}'."
	return 1
}

# 1: source file path
# 2: dest file path
# 3: compression command with options
#
# return codes:
# 0: success
# 1: failure
# 2: blocklist file not found (nothing to export)
try_export_blocklist()
{
	local IFS="${DEFAULT_IFS}" \
		src_path="${1}" dest_path="${2}" compr_cmd="${3}"

	assert_set "F_export_blocklist" src_path dest_path ALL_CONF_DIRS || return 1
	[ -f "${src_path}" ] || { reg_failure "Blocklist not found at path '${src_path}'."; return 2; }

	reg_action -3 -blue "Creating backup of current blocklist." || return 1

	conv_compr "${src_path}" "${dest_path}" "${compr_cmd}" || return 1

	:
}

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

restore_saved_blocklist()
{
	try_restore_saved_blocklist "${@}" && return 0

	local src_file="${1}" dest_file="${2}"

	rm_if_volatile "${src_file}" "${dest_file}"
	rm_conf_scripts
	rm_main_bl

	reg_failure "Failed to restore saved blocklist '${src_file}'."
	BL_FILE_CURR=
	return 1
}

# Env vars:
# RESTORE_FROM_PERM: do not convert or move source file - try to install as is
#
# 1 - source file
# 2 - dest file
try_restore_saved_blocklist()
{
	local me="restore_saved_blocklist" \
		src_file="${1}" dest_file="${2}"

	reg_action -1 -blue "Restoring saved blocklist file." || return 1

	assert_set "F_${me}" src_file dest_file LAST_BLOCKLIST_PATH_FILE || return 1

	reg_msg -3 "" "${blue}Importing blocklist file: ${n_c}'${src_file}'."

	rm_conf_scripts
	rm_main_bl

	[ -n "${RESTORE_FROM_PERM}" ] && [ "${src_file}" != "${dest_file}" ] &&
		{ reg_failure "${me}: \$RESTORE_FROM_PERM is set but source file '${src_file}' is not the same as dest file '${dest_file}'"; return 1; }

	[ -n "${RESTORE_FROM_PERM}" ] || conv_compr "${src_file}" "${dest_file}" "${FINAL_COMPR_TO_FILE}" ""

	install_blocklist "${dest_file}" "" "saved" || return 1

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
