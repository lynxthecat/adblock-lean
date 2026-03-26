#!/bin/sh
# shellcheck disable=SC3043,SC2016,SC3060,SC3040,SC3003

# silence shellcheck warnings

: "${test_domains:=}" "${compression_util:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" \
	"${blue:=}" "${green:=}" "${red:=}" "${n_c:=}"


# UTILITY FUNCTIONS

get_compr_util_spec()
{
	local gcu_util_path='' gcu_ext='' \
		util_path_out_var="${1}" ext_out_var="${2}" gcu_util_name="${3}"

	unset_vars "${1}" "${2}" &&
	assert_set F_get_compr_util_spec util_path_out_var ext_out_var gcu_util_name || return 1

	case "${gcu_util_name}" in
		gzip)
			detect_util gcu_util_path gzip "" "/usr/libexec/gzip-gnu" &&
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
		if detect_util gcu_util_path "gzip" "" "/usr/libexec/gzip-gnu"
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


# HELPER FUNCTIONS

# 1: var for output
# 2: blocklist instance
# 3: BL|PAUSE|BK
# 4: RAM|PERSIST
get_curr_bl_path()
{
	unset_vars "${1:?}" &&
	{
		case "${3:?}" in
			BL|PAUSE) ;;
			*) false ;;
		esac &&
		case "${4:?}" in
			RAM|PERSIST) ;;
			*) false ;;
		esac || bad_args get_urr_bl_path "${@}"; return 1
	} &&
	eval "${1}=\"\${${4}_${3}_FILE_CURR_${2:?}}\"" # example: RAM_BL_FILE_CURR_3
}

find_persist_files()
{
	local persist_dir bl_file pause_file \
		bl_inst="${1}"

	for bl_inst in ${BL_INSTANCES}
	do
		file=
		FF_RM_EXTRA=1 find_files bl_file "${PERSIST_BLOCKLIST_DIR}" "${BLOCKLIST_BASE_FNAME:?}_${bl_inst}"
		export "PERSIST_BL_FILE_CURR_${bl_inst}=${file}"

		FF_RM_EXTRA=1 find_files pause_file "${PERSIST_BLOCKLIST_DIR}" "${PAUSE_BASE_FNAME:?}_${bl_inst}"
		export "PERSIST_PAUSE_FILE_CURR_${bl_inst}=${file}"

		debug_msg "instance '${bl_inst}':" "PERSIST_BL_FILE_CURR_${bl_inst}:'${bl_file}'" "PERSIST_PAUSE_FILE_CURR_${bl_inst}:'${pause_file}'"
	done
}

get_blocklist_md5()
{
	local me=get_blocklist_md5 gbm_md5 gbm_path \
		gbm_out_var="${1}" gbm_inst="${2}"
	is_uint "${gbm_inst}" || { bad_args "${me}" "${@}"; return 1; }
	unset_vars "${gbm_out_var}" || return 1

	eval "gbm_path=\"INSTALL_PATH_${gbm_inst}\"" &&
	get_md5 gbm_md5 "${gbm_path}" &&
	is_hex_lc "${gbm_md5}" &&
	eval "${gbm_out_var}"='${gbm_md5}' && return 0

	reg_failure "${me}: got invalid md5 '${gbm_md5}' for blocklist ${gbm_inst} at ${gbm_path}."
	return 1

}

# Env vars:
#   CA_CHECK_DOMAINS: test DNS resolution
#   CA_NOPROGRESS: do not print progress messages
#
# return values:
# 0: All checks passed
# 1: General error
# 2: The blocklist test domain failed to resolve (blocklist not loaded)
# 3: One of the test domains failed to resolve
check_active_blocklist()
{
	lookup_failed() { reg_failure "Lookup of test domain '${1}' failed."; }
	ca_print() { [ -n "${CA_NOPROGRESS}" ] || reg_msg "${@}"; }

	reg_action -blue "Checking the active blocklist." || return 1

	local me=check_active_blocklist family index indexes instance_ns def_ns ns_ips ca_ns4 ca_ns6 ns_ips_sp ca_test_dom \
		ca_bl_inst="${1}" ca_md5="${2}"

	GDI_NOFORCE=1 get_dnsmasq_instances || return 1

	assert_set "F_${me}" DNSMASQ_INDEXES DNSMASQ_INST_SET ca_bl_inst ca_md5 || return 1

	debug_msg "${me}: instance:${ca_bl_inst}, md5:${ca_md5}"

	eval "indexes=\"\${DNSMASQ_INDEXES_${ca_bl_inst}}\""
	for index in ${indexes}
	do
		ns_ips='' ns_ips_sp='' ca_test_dom="${ca_md5}-${ABL_TEST_DOM_BASE}"

		eval "ca_ns4=\"\${NS4_${index}}\"" "ca_ns6=\"\${NS6_${index}}\""
		debug_msg "${me}: ips: '${ca_ns4}', '${ca_ns6}'"

		for family in 4 6
		do
			case "${family}" in
				4) def_ns=127.0.0.1 ;;
				6) def_ns=::1
			esac
			eval "instance_ns=\"\${ca_ns_${family}:-${def_ns}}\""
			add2list ns_ips "${instance_ns}"
			add2list ns_ips_sp "${blue}${instance_ns}${n_c}" ", "
		done

		ca_print "Testing dnsmasq instance ${index}."
		ca_print "Using following nameservers for DNS resolution verification: ${ns_ips_sp}"

		ca_print -blue "Testing adblocking."

		try_lookup_domain "${ca_test_dom}" "${ns_ips}" 1 -n || { lookup_failed "${ca_test_dom}"; return 2; }

		[ -n "${CA_CHECK_DOMAINS}" ] &&
		{
			ca_print -blue "Testing DNS resolution."
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
	local me=get_abl_run_state
		state_out_var="${1}"
	shift

	unset_vars "${state_out_var}" &&
	assert_set "F_${me}" ABL_ENV_SET state_out_var || return 1

	try_get_abl_run_state "${@}"
	eval "${state_out_var}=${?}"

	:
}

# return codes:
# 0 - running
# 1 - error
# 2 - (reserved)
# 3 - paused
# 4 - stopped
try_get_abl_run_state()
{
	check_fail() { reg_failure "${1}${1:+ }Failed to check adblock-lean run state. ${diag_msg}"; }

	[ -n "${DNSMASQ_CONF_DIRS}" ] || { check_fail "\$DNSMASQ_CONF_DIRS is not set."; return 1; }

	local bl_inst bl_md5 diag_msg \
		dns_checked='' params_checked='' index indexes \
		dns_check_res='' dns_check_res_all='' params_check_res=''

	print_msg -blue "Checking adblock-lean run state."

	[ -n "${META_READ}" ] || read_blocklist_metadata || params_check_res=1

	for bl_inst in "${@}"
	do
		eval "bl_md5=\"BL_MD5_RAM_${bl_inst}\"" && [ -n "${bl_md5}" ] || { params_check_res=1; continue; }
		params_checked=1
		check_active_blocklist "${bl_inst}" "${bl_md5}"
		dns_check_res=${?}
		case "${dns_check_res_all}" in
			'') dns_check_res_all=${dns_check_res} ;;
			*) [ "${dns_check_res}" = "${dns_check_res_all}" ] || dns_check_res_all=1 ;;
		esac
		dns_checked=1
	done

	case "${params_checked}" in
		'') params_check_res=-1 ;;
		*) : "${params_check_res:=0}" ;;
	esac

	[ -n "${dns_checked}" ] || dns_check_res_all=-1

	diag_msg="params:${params_check_res}, dns:${dns_check_res_all}."
	debug_msg "${me}: ${diag_msg}"

	[ -n "${params_checked}" ] &&
	{
		[ "${params_check_res}" = 0 ] || { check_fail; return 1; }

		case "${dns_check_res_all}" in
			0) : ;;
			1) check_fail "General error."; return 1 ;;
			2) reg_failure "Inconsistent run state. ${diag_msg}"; return 1 ;;
			*) check_fail "Unexpected DNS check code '${dns_check_res_all}'."
		esac
		return 0
	}

	[ -n "${PAUSE_FILE_CURR}" ] && return 3

	return 4
}

# Populates global vars required for processing, status and cleanup
# Env vars:
#   SAE_STATUS: do not exit on non-critical errors
set_abl_env()
{
	[ -n "${ABL_ENV_SET}" ] && return 0

	local me=set_abl_env \
		IFS="${DEFAULT_IFS}" \
		compr_util_path \
		compr_ext \
		extr_cmd_stdout \
		compr_cmd_to_file \
		compr_cmd_stdout \
		cpu_cnt

	export \
		RUN_STATE_GLOBAL='' \
		PARALLEL_JOBS='' \
		PART_EXTR_OR_CAT_STDOUT="${CAT_CMD}" \
		INTERM_COMPR_OR_CAT_STDOUT="${CAT_CMD}" \
		INTERM_COMPR_EXT='' \
		INTERM_COMPR_TO_FILE=''

	debug_msg "Preparing environment." 

	assert_set "F_${me}" BL_INSTANCES compression_util || return 1

	set -o pipefail
	read_blocklist_metadata &&
	get_dnsmasq_instances &&
	check_dnsmasq_instances &&
	get_dnsmasq_ips ||
		return 1

	get_abl_run_state RUN_STATE_GLOBAL ${BL_INSTANCES} || [ -n "${SAE_STATUS}" ] || return 1

	# Parallel processing
	case "${MAX_PARALLEL_JOBS}" in
		auto)
			cpu_cnt="$(grep -c '^processor\s*:' /proc/cpuinfo)"
			if is_uint "${cpu_cnt}"
			then
				# cap PARALLEL_JOBS to 4 in 'auto' mode
				PARALLEL_JOBS=$(( (cpu_cnt>4)*4 + (cpu_cnt<=4)*cpu_cnt ))
			else
				reg_failure "Failed to detect CPU core count. Parallel processing will be disabled."
				PARALLEL_JOBS=1
			fi ;;
		*)
			PARALLEL_JOBS="${MAX_PARALLEL_JOBS}"
	esac

	# Compression
	get_compr_util_spec compr_util_path compr_ext "${compression_util}" || return 1

	# Interm compr commands
	[ -n "${compr_ext}" ] &&
	{
		compr_cmd_to_file="${compr_util_path} -f"
		compr_cmd_stdout="${compr_util_path} -c"
		extr_cmd_stdout="${compr_util_path} -cd"

		PART_EXTR_OR_CAT_STDOUT="try_extract -stdout"
		INTERM_COMPR_OR_CAT_STDOUT=${compr_cmd_stdout}
		INTERM_COMPR_TO_FILE=${compr_cmd_to_file}
		INTERM_COMPR_EXT=${compr_ext}
	}

	debug_msg "compr_util_path: '${compr_util_path}', compr_ext: '${compr_ext}'"

	for bl_inst in ${BL_INSTANCES}
	do
		set_abl_inst_env "${bl_inst}" "${compr_ext}" "${extr_cmd_stdout}" "${compr_cmd_stdout}" "${compr_cmd_to_file}" || return 1
	done

	export ABL_ENV_SET=1

	:
}


# Populates global vars for individual blocklist instances
# Env vars:
#   SAE_STATUS: do not exit on non-critical errors
set_abl_inst_env()
{
	rebuild_req_notice() { log_msg -warn "Please run 'service adblock-lean ${1}' to rebuild the ${2}${2:+ }blocklist."; }
	wont_work() {
		reg_failure "${1} can not be used because of missing addnmounts in /etc/config/dhcp: ${2}" \
			"Please run 'service adblock-lean create_addnmounts' to create required addnmount entries."
	}

	local bl_inst="${1}" compr_ext="${2}" extr_cmd_stdout="${3}" compr_cmd_stdout="${4}" compr_cmd_to_file="${5}"

	local me=set_abl_inst_env \
		IFS="${DEFAULT_IFS}" \
		\
		dnsmasq_indexes \
		dnsmasq_conf_dirs \
		\
		conf_script_log_avail \
		\
		first_conf_dir \
		sae_missing_addnm \
		addnm_ignore_paths \
		\
		bl_base_fname \
		bl_full_fname_check \
		bl_path_ram_check \
		bl_full_fname \
		bl_path_ram \
		bl_path_persist \
		\
		bk_file \
		pause_dir \
		pause_file_new \
		\
		install_path \
		\
		persist_avail=0 \
		persist_dir \
		persist_mode \
		\
		curr_path_persist \
		curr_cnt_persist \
		curr_cnt_persist_human \
		curr_persist_size_b \
		\
		final_compress \
		final_compr_ext \
		final_extr_or_cat_stdout \
		final_compr_or_cat_stdout \
		final_compr_to_file \
		\
		start_action=gen

# TODO: fix vars across the scripts, e.g. DNSMASQ_CONF_DIRS, DNSMASQ_INDEXES, PERSIST_DIR, PERSIST_MODE

	# Check addnmounts, possibility of final compression, multiple dnsmasq instances and persistent blocklist creation,
	#   get final blocklist paths,
	#   compression util path and extension
	debug_msg "Preparing environment for instance ${bl_inst}."

	assert_set "F_${me}" bl_inst "DNSMASQ_INDEXES_${bl_inst}" "DNSMASQ_CONF_DIRS_${bl_inst}" "PERSIST_MODE_${bl_inst}" || return 1

	eval \
		"dnsmasq_indexes=\"DNSMASQ_INDEXES_${bl_inst}\"" \
		"dnsmasq_conf_dirs=\"\${DNSMASQ_CONF_DIRS_${bl_inst}}\"" \
		"persist_dir=\"\${PERSIST_DIR_${bl_inst}}\"" \
		"persist_mode=\"\${PERSIST_MODE_${bl_inst}}\"" \
		"curr_path_persist=\"\${PATH_PERSIST_${bl_inst}}\"" \
		"curr_cnt_persist=\"\${CNT_PERSIST_${bl_inst}}\""

	bl_base_fname=${BLOCKLIST_BASE_FNAME:?}_${bl_inst}

	get_inst_metadata

	get_curr_blocklist_path # TODO: instance-specific paths

	# conf-script error logging
	check_addnmounts sae_missing_addnm "${dnsmasq_indexes}" "${LOG_CMD}" || return 1
	case "${sae_missing_addnm}" in
		'') conf_script_log_avail=1 ;;
		*) wont_work "Error logging by the conf-script" "${sae_missing_addnm}" ;;
	esac

	# Compression

	# Final blocklist compr commands, filenames, ramdisk blocklist path
	if [ -n "${compr_ext}" ]
	then
		assert_set "F_${me}" compr_cmd_to_file compr_cmd_stdout extr_cmd_stdout || return 1
		bl_full_fname_check=${bl_base_fname:?}${compr_ext}
		bl_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname_check}
		check_addnmounts sae_missing_addnm "${dnsmasq_indexes}" "${extr_cmd_stdout%% *}${_NL_}${bl_path_ram_check}" || return 1

		if [ -z "${sae_missing_addnm}" ]
		then
			bl_full_fname=${bl_full_fname_check}
			bl_path_ram=${bl_path_ram_check}

			final_compress=1
			final_compr_ext=${compr_ext}
			final_compr_to_file=${compr_cmd_to_file}
			final_compr_or_cat_stdout=${compr_cmd_stdout}
			final_extr_or_cat_stdout=${extr_cmd_stdout}
		else
			wont_work "Final blocklist compression" "${sae_missing_addnm}"
		fi
	fi

	# Final blocklist full filename
	: "${bl_full_fname:="${bl_base_fname:?}"}"

	# Multiple dnsmasq instances
	case "${dnsmasq_indexes}" in
		*[0-9]*" "*[0-9]*)
			bl_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname:?}
			check_addnmounts sae_missing_addnm "${dnsmasq_indexes}" "${bl_path_ram_check}" || return 1
			if [ -z "${sae_missing_addnm}" ]
			then
				bl_path_ram=${bl_path_ram_check}
			else
				wont_work "Multiple dnsmasq instances" "${sae_missing_addnm}"
			fi ;;
		*)
			first_conf_dir="${dnsmasq_conf_dirs%% *}"
			is_valid_dir "${first_conf_dir}" || return 1
			addnm_ignore_paths="${first_conf_dir}/${bl_full_fname}"

			[ -n "${bl_path_ram}" ] || bl_path_ram="${first_conf_dir}/${bl_full_fname}"
	esac

	# addnmount for blocklist on ramdisk - required regardless of compr/persist/multi_inst availability
	sae_missing_addnm=
	is_included "${bl_path_ram}" "${addnm_ignore_paths}" "${_NL_}" ||
		check_addnmounts sae_missing_addnm "${dnsmasq_indexes}" "${bl_path_ram}" || return 1
	[ -z "${sae_missing_addnm}" ] || { wont_work "adblock-lean" "${sae_missing_addnm}"; [ -n "${SAE_STATUS}" ] || return 1; }

	# Persistent blocklist
	case "${persist_mode}" in manual|managed)
		if check_persist_dir
		then
			check_addnmounts sae_missing_addnm "${dnsmasq_indexes}" "${persist_dir}" || return 1
			if [ -z "${sae_missing_addnm}" ]
			then
				persist_avail=1
				[ "${persist_mode}" = managed ] && bl_path_persist="${persist_dir}/${bl_full_fname}"
			else
				wont_work "Persistent blocklist" "${sae_missing_addnm}"
			fi
		else
			log_msg -warn "" "Persistent blocklist can not be used or updated."
		fi
	esac

	if [ "${persist_avail}" = 1 ]
	then
		if [ "${ABL_INIT_ACTION}" = boot ] || { [ -z "${PAUSE_FILE_CURR}" ] && [ "${ABL_INIT_ACTION}" = status ]; }
		then
			reg_action -blue "Checking the persistent blocklist."
			local file="${PERSIST_BL_FILE_CURR}" \
				min_good_line_count_human='' persist_ext='' persist_fail='' curr_cnt_persist='' curr_cnt_persist_human=''

			if
				{
					[ -n "${file}" ] ||
						{
							[ "${persist_mode}" = manual ] && persist_mode=disable
							persist_fail="Persistent blocklist not found in directory '${persist_dir}'."
							false
						}
				} &&

				{
					get_compr_spec persist_ext _ "${file}" ||
						{ persist_fail="Can not find utility to extract persistent blocklist file '${file}'."; false; }
				} &&

				{
					[ "${persist_ext}" = "${final_compr_ext}" ] ||
						{
							persist_fail="Extension '${persist_ext}' of persistent blocklist file '${file}' does not match required extension '${final_compr_ext}'."
							false
						}
				} &&

				curr_persist_size_b="$(get_file_size "${file}")" &&
				{
					[ $(( curr_persist_size_b/1024 )) -le "${max_blocklist_file_size_KB}" ] ||
					{ persist_fail="Persistent blocklist file '${file}' is larger than the maximum value set in config (${max_blocklist_file_size_KB} KiB)."; false; }
				} &&

				GMD_QUIET=1 get_inst_metadata "${file}" "" _ _ curr_cnt_persist && #TODO

				{
					int2human curr_cnt_persist_human "${curr_cnt_persist}" &&
					int2human min_good_line_count_human "${min_good_line_count}" || return 1
				} &&

				{
					[ "${curr_cnt_persist}" -ge "${min_good_line_count}" ] ||
						{
							persist_fail="Entries count (${curr_cnt_persist_human}) in the persistent blocklist '${file}' is below the minimum value set in config (${min_good_line_count_human})."
							false
						}
				}
			then
				start_action=load

				install_path=${file}
			else
				[ "${BL_FILE_CURR}" = "${file}" ] &&
					{ [ "${ABL_INIT_ACTION}" = status ] || rm_main_bl "${bl_inst}"; } # TODO: rm_main_bl should handle individual bl instances
				export "PERSIST_BL_FILE_BAD_${bl_inst}"=1 # TODO: handle per-instance TODO2: is this var needed?
				local start_act_msg="Will create a new blocklist on the ramdisk."
				[ "${persist_mode}" = managed ] &&
				{
					start_act_msg="Will rebuild the persistent blocklist."

					install_path=${bl_path_persist}
				}

				[ -n "${persist_fail}" ] && log_msg -warn "${persist_fail}"
				[ "${ABL_CMD}" = start ] && [ -n "${start_act_msg}" ] && log_msg "${start_act_msg}"
				[ "${persist_mode}" = manual ] && rebuild_req_notice "gen_persist_blocklist" "persistent"
			fi
		elif [ "${persist_mode}" = managed ]
		then
			pause_dir=${persist_dir:?}
			[ "${ABL_CMD}" = start ] && reg_msg "" "Will update the persistent blocklist." ""
			install_path=${bl_path_persist}
		fi
	fi

	: "${install_path:="${bl_path_ram}"}"

	[ -n "${install_path}" ] &&
	case "${start_action}" in
		load) [ -n "${install_path}" ] && add2list "BLOCKLISTS_TO_INSTALL" "${bl_inst}" " " ;;
		gen) add2list "BLOCKLISTS_TO_GEN" "${bl_inst}" " " ;;
		*) reg_failure "${me}: invalid start action '${start_action}'."; return 1 ;;
	esac ||
		{ reg_failure "No usable path to install or load the blocklist."; rebuild_req_notice "restart"; [ -n "${SAE_STATUS}" ] || return 1; }

	bk_file="${BK_BL_BASE_PATH:?}${INTERM_COMPR_EXT}"
	pause_file_new="${pause_dir:-"${ABL_RUN_DIR:?}"}/${PAUSE_BASE_FNAME:?}${final_compr_ext}"

	export \
		"INSTALL_PATH_${bl_inst}=${install_path}" \
		"INSTALL_PATH_RAM_${bl_inst}=${bl_path_ram}" \
		"PAUSE_FILE_NEW_${bl_inst}=${pause_file_new}" \
		"BK_FILE_${bl_inst}=${bk_file}" \
		"FINAL_COMPRESS_${bl_inst}=${final_compress}" \
		"FINAL_COMPR_EXT_${bl_inst}=${final_compr_ext}" \
		"FINAL_EXTR_OR_CAT_STDOUT_${bl_inst}=${final_extr_or_cat_stdout:-"${CAT_CMD}"}" \
		"FINAL_COMPR_OR_CAT_STDOUT_${bl_inst}=${final_compr_or_cat_stdout:-"${CAT_CMD}"}" \
		"FINAL_COMPR_TO_FILE_${bl_inst}=${final_compr_to_file}" \
		"CONF_SCRIPT_LOG_${bl_inst}=${conf_script_log_avail}"

	debug_msg \
		"bl_path_ram: '${bl_path_ram}'" \
		"bl_path_persist: '${bl_path_persist}'" \
		"final_compr_ext: '${final_compr_ext}'" \
		"install_path: '${install_path}'" \
		"bk_file: '${bk_file}'" \
		"pause_file_new: '${pause_file_new}'"

	:
}



# Get interfaces each dnsmasq instance is listening on and associated IP addresses
# Populates global vars: NS4_${dnsmasq_index} NS6_${dnsmasq_index}
get_dnsmasq_ips()
{
	local me=get_dnsmasq_ips \
		IFS="${DEFAULT_IFS}" \
		odevs linux_ifaces dnp_res

	assert_set "F_${me}" IP_REGEX_4 IP_REGEX_6 || return 1

	# get list of OpenWrt device names, store in $odevs
	# shellcheck disable=SC2329
	get_odevs_cb()
	{
		local dev section_id="$1"
		config_get dev "${section_id}" name
		odevs="${odevs}${odevs:+$'\n'}${dev}"
	}

	config_load network &&
	config_foreach get_odevs_cb device &&

	# get list of all linux ifaces + IP addresses
	linux_ifaces="$(
		ip -o addr show |
		${SED_CMD} -nE "/^\s*[0-9]+:\s*/{s/^\s*[0-9]+\s*:\s+//;s/inet[6]*\s+//;s/\s(${IP_REGEX_4:?}|${IP_REGEX_6:?})(\/[0-9]+)\s.*/\1/;s/\s+/ /;s/\s+$//;p;}"
	)" &&

	dnp_res="$(
		${NETSTAT_CMD} -plnt |
		${AWK_CMD} -v regex_4="${IP_REGEX_4//\\./.}" -v regex_6="${IP_REGEX_6}" -v l_ifaces="${linux_ifaces}" -v odevs_str="${odevs}" '
			BEGIN {
				rv = 1
				# array with OpenWrt device names as keys
				split(odevs_str,o,"\n")
				for (d in o) { odevs[o[d]] }

				# parse linux ifaces w/ ips into array keyed by ips, prioritize OpenWrt devices
				split(l_ifaces,a,"\n")
				for (e in a) {
					i=a[e]
					n = index(i, " ")
					if(n != 0) {
						ip = substr(i, n + 1)
						if_name=substr(i, 1, n - 1)
						if ( ips[ip] == "" || if_name in odevs ) {ips[ip] = if_name}
					}
				}
			}

			/LISTEN[ ].*\/dnsmasq$/ {
				ip = $4
				sub(/:[^:]+$/,"",ip)
				if (ip in ips) {} else next
				iface=ips[ip]

				pid = $7
				if (! match (pid,/\/dnsmasq$/)) next
				sub("/dnsmasq","",pid)
				if (! iface || ! pid) next

				id = pid " " iface

				if (match(ip,regex_4)) { if (out_4[id] != "") {next}; out[id]; out_4[id] = ip }
				else if (match(ip,regex_6)) { if (out_6[id] != "") {next}; out[id]; out_6[id] = ip }
				else next
			}

			END {
				for (id in out) {
					if (out_4[id]) {rv = 0; out_val_4 = out_4[id]} else {out_val_4 = "NIL"}
					if (out_6[id]) {rv = 0; out_val_6 = out_6[id]} else {out_val_6 = "NIL"}
					print id " " out_val_4 " " out_val_6
				}
				exit rv
			}
		'
	)" &&
	[ -n "${dnp_res}" ] ||
		{ reg_failure "Failed to get network params for dnsmasq instances. Found Linux ifaces: '${linux_ifaces//"${_NL_}"/ }', OpenWrt devices: '${odevs}', "; return 1; }


	# dnsmasq nameserver IP's
	local line index indexes all_indexes \
		bl_inst \
		inst_pid inst_iface \
		inst_ip_4 inst_ip_6 ip4_present ip6_present

	for bl_inst in ${BL_INSTANCES}
	do
		assert_set "F_${me}" "DNSMASQ_INDEXES_${bl_inst}" || return 1
		eval "indexes=\"DNSMASQ_INDEXES_${bl_inst}\""
		add2list all_indexes "${indexes}" " "
	done

	for index in ${all_indexes}
	do
		# iface and nameservers
		inst_iface='' inst_ip_4='' inst_ip_6='' ip4_present='' ip6_present=''

		eval "inst_pid=\"\${PID_${index}}\""
		IFS="${_NL_}"
		for line in ${dnp_res}
		do
			IFS="${DEFAULT_IFS}"
			set -- ${line}
			[ "${1}" = "${inst_pid}" ] && [ -n "${2}" ] || continue

			[ -n "${3%"NIL"}" ] && ip4_present=1
			[ -n "${4%"NIL"}" ] && ip6_present=1
		done

		IFS="${_NL_}"
		for line in ${dnp_res}
		do
			IFS="${DEFAULT_IFS}"
			set -- ${line}
			[ "${1}" = "${inst_pid}" ] || continue

			iface_tmp="${2}"
			ip4_tmp="${3%"NIL"}"
			ip6_tmp="${4%"NIL"}"

			[ -n "${iface_tmp}" ] &&
				{ [ -n "${ip4_tmp}" ] || [ -n "${ip6_tmp}" ]; } ||
					continue

			[ -z "${inst_iface}" ] ||
			{
				[ "${inst_iface}" = lo ] &&
				{ [ -z "${ip4_present}" ] || [ -n "${ip4_tmp}" ]; } &&
				{ [ -z "${ip6_present}" ] || [ -n "${ip6_tmp}" ]; }
			} &&
			{
				inst_iface="${iface_tmp}"
				inst_ip_4="${ip4_tmp}"
				inst_ip_6="${ip6_tmp}"
			}
		done
		IFS="${DEFAULT_IFS}"

		[ -n "${inst_ip_4}" ] || [ -n "${inst_ip_6}" ] || { reg_failure "${me}: no IP addresses detected for dnsmasq instance with index ${index}."; return 1; }

		eval "NS4_${index}"='${inst_ip_4}'
		eval "NS6_${index}"='${inst_ip_6}'
	done
	:
}


mk_metadata()
{
	try_mk_metadata "${@}" && return 0
	reg_failure "Failed to create or update the metadata file."
	return 1
}

try_mk_metadata()
{
	# shellcheck disable=SC2329
	rm_unused() { is_included "${1}" "${BL_INSTANCES}" " " || uci_tmp -q delete "${meta_fname}.${1}"; }
	uci_tmp() { uci -c "${meta_dir}" "$@"; }

	# shellcheck disable=SC2034
	local me=mk_metadata IFS="${DEFAULT_IFS}" \
		meta_dir="${META_FILE%/*}" \
		meta_fname="${META_FILE##*/}" \
		location \
		meta_param param_val uci_fail='' \
		meta_path meta_md5 meta_cnt \
		bl_inst

	debug_msg "Creating/updating metadata."

	assert_set "F_${me}" INSTALLED_INSTANCES || return 1

	{ [ -f "${META_FILE}" ] || touch "${META_FILE}"; } || return 1

	(
		UCI_CONFIG_DIR="${meta_dir}" config_load "${META_FILE##*/}" &&
		config_foreach rm_unused blocklist_instance
	)

	for bl_inst in ${INSTALLED_INSTANCES}
	do
		for location in RAM PERSIST
		do
			eval "meta_path=\"\${PATH_${location}_${bl_inst}}\"" \
				"meta_md5=\"\${MD5_${location}_${bl_inst}}\"" \
				"meta_cnt=\"\${CNT_${location}_${bl_inst}}\""

			{ [ -n "${meta_path}" ] && [ -n "${meta_md5}" ] && [ -n "${meta_cnt}" ]; } ||
				{ [ "${location}" = PERSIST ] && continue; } ||
					{ reg_failure "${me}: empty values for params."; uci_fail=1; break; }

			# create/update section in meta file
			uci_tmp set "${meta_fname}.${bl_inst}=blocklist_instance" &&
			for meta_param in blocklist_path md5 cnt
			do
				eval "param_val=\"\${meta_${meta_param}}\""
				uci_tmp set "${meta_fname}.${bl_inst}.${meta_param}"="${param_val}" || { uci_fail=1; break; }
			done

			# Store MD5 sum for persistent blocklist next to the file
			[ "${location}" = PERSIST ] &&
				printf '%s\n' "${meta_md5}" > "${meta_path%/*}/.persist-md5"
		done
	done

	[ -z "${uci_fail}" ] &&
	uci_tmp commit "${meta_fname}" ||
		{ uci_tmp revert "${meta_fname}"; rm -f "${META_FILE}"; return 1; }


	:
}

# Env vars:
#   GMD_QUIET: do not print file-not-found or key-not-found erros (return 1)
#
# Reads the metadata file and assigns global vars:
#   IS_PAUSED_{inst}
#   PATH_RAM_{inst} MD5_RAM_{inst} CNT_RAM_{inst}
#   PATH_PERSIST_{inst} MD5_PERSIST_{inst} CNT_PERSIST_{inst}
#
# Values are only assigned for files which actually exist, and reflect last known state
#   (updated at the end of each adblock-lean run of start/stop/pause/resume)
#
# shellcheck disable=SC2329
read_blocklist_metadata()
{
	append_err() { err_msgs=${err_msgs}${err_msgs:+"${_NL_}"}; }

	populate_vars()
	{
		local \
			bl_md5 \
			meta_path meta_md5 meta_cnt \
			persist_seen='' \
			bl_inst_pr="blocklist instance '${1}'"

		debug_msg "Populating vars for blocklist instance '${1}'."
		is_included "${1}" "${BL_INSTANCES}" ||
		{
			append_err "Instance '${1}' in ${sp_f_pr} is not included in configured instances '${BL_INSTANCES}'."
			return 1
		}

		is_included "${seen_instances}" "${1}" &&
			append_err "Multiple entries for ${bl_inst_pr} in ${sp_f_pr}."

		add2list seen_instances "${1}" " "

		for location in RAM PERSIST
		do
			for key in ${req_keys}
			do
				config_get "meta_val" "${1}" "${location}_${key}"
				[ -n "$meta_val" ] ||
				{ [ "${location}" = PERSIST ] && [ -z "${persist_seen}" ] && continue; } ||
				{
					append_err "Failed to get ${key} from ${sp_f_pr} for ${bl_inst_pr}."
					return 1
				}

				[ "${location}" = PERSIST ] && persist_seen=1

				eval "${key}_${location}_${1}"='${meta_val}'
			done
		done

		config_get "IS_PAUSED_${1}" "${1}" "IS_PAUSED"

		META_READ=1

		# check md5 - requires second loop
		for location in RAM PERSIST
		do
			eval \
				"meta_md5=\"MD5_${location}_${1}\"" \
				"meta_path=\"PATH_${location}_${1}\""
			[ -n "${meta_path}" ] || continue
			get_md5 bl_md5 "${meta_path}" ||
				{ append_err "Failed to get MD5 sum of ${meta_path}."; return 1; }
			[ "${meta_md5}" = "${bl_md5}" ] ||
			{
				append_err "MD5 sum not matching in ${sp_f_pr} for ${bl_inst_pr}, path '${meta_path}'. Spec file has: '${meta_md5}', blocklist file has: '${bl_md5}'."
				return 1
			}
		done
		:
	}

	local me=read_blocklist_metadata \
		req_keys="PATH MD5 CNT" \
		location key \
		IFS="${DEFAULT_IFS}" \
		rbm_rv=0 \
		err_msgs='' \
		seen_instances='' \
		missing_instances='' \
		sp_f_pr="metadata file '${META_FILE}'"

	debug_msg "${me} start, instances ${BL_INSTANCES}"

	export META_READ=

	[ -n "${BL_INSTANCES}" ] || { reg_failure "Blocklist instances (\$BL_INSTANCES) are not set."; return 1; }

	# Reset global vars
	for bl_inst in ${BL_INSTANCES}
	do
		unset "IS_PAUSED_${bl_inst}"
		for location in RAM PERSIST
		do
			for key in ${req_keys}
			do
				unset "${key}_${location}_${bl_inst}"
			done
		done
	done

	[ -f "${META_FILE}" ] ||
		{ [ -n "${GMD_QUIET}" ] || reg_failure "${me}: can not find ${sp_f_pr}."; return 1; }

	UCI_CONFIG_DIR="${META_FILE%/*}" config_load "${META_FILE##*/}" ||
		{ reg_failure "${me}: failed to load ${sp_f_pr}."; return 1; }

	config_foreach populate_vars blocklist_instance

	[ -n "${err_msgs}" ] &&
	{
		rbm_rv=1
		IFS="${_NL_}"
		for err_msg in ${err_msgs}
		do
			IFS="${DEFAULT_IFS}"
			reg_failure "${me}: ${err_msg}"
		done
		IFS="${DEFAULT_IFS}"
	}

	subtract_a_from_b "${seen_instances}" "${BL_INSTANCES}" missing_instances " " ||
		{ reg_failure "${me}: configured instances '${missing_instances}' are missing from ${sp_f_pr}."; rbm_rv=1; }

	return ${rbm_rv}
}


mv_blocklist()
{
	local me=mv_blocklist mv_rv \
		mv_src_f="${1}" mv_dst_f="${3}" mv_compr_cmd="${3}" mv_bl_inst="${4}"

	debug_msg "${me} start: '${mv_src_f}' to '${mv_dst_f}'"

	assert_set "F_${me}" mv_src_f mv_dst_f &&
	try_mv_blocklist "${@}"
	mv_rv=${?}
	
	debug_msg "${me} end"
	[ "${mv_rv}" = 0 ] && return 0

	rm_if_writable "${mv_src_f}" "${mv_dst_f}"
	reg_failure "Failed to move blocklist ${mv_bl_inst:+"(index '${mv_bl_inst}') "}from '${mv_src_f}' to '${mv_dst_f}' (cmd: '${mv_compr_cmd}')."
	return 1
}

# Args:
# 1: src path
# 2: dst path
# 3: compression cmd
# 4: blocklist instance (when present)
# If src dir is protected, copy file instead of moving
try_mv_blocklist()
{
	local transfer_cmd="try_mv -q" \
		file_changed='' \
		src_md5 mv_src_d mv_src_fname mv_src_ext \
		dst_md5 mv_dst_d mv_dst_ext \
		mv_src_f="${1}" mv_dst_f="${2}" mv_compr_cmd="${3}" mv_bl_inst="${4}" mv_location="${5}"

	split_path mv_src_d mv_src_fname mv_src_ext "${mv_src_f}" &&
	split_path mv_dst_d mv_dst_fname mv_dst_ext "${mv_dst_f}" || return 1

	is_valid_dir "${mv_src_d}" && is_valid_dir "${mv_dst_d}" || { reg_failure "${me}: unexpected src dir '${mv_src_d}' or dest dir '${mv_dst_d}'."; return 1; }

	[ -f "${mv_src_f}" ] || { reg_failure "${me}: file '${mv_src_f}' not found."; return 1; }

	[ "${mv_src_f}" = "${mv_dst_f}" ] && return 0

	is_dir_writable "${mv_dst_d}" || { reg_failure "${me}: logic bug: attempted write into protected dir '${mv_dst_d}'."; return 1; }

	is_dir_writable "${mv_src_d}" || transfer_cmd="cp"

	if [ -n "${mv_src_ext}" ] && [ "${mv_src_ext}" != "${mv_dst_ext}" ]
	then
		try_extract "${mv_src_f}" || return 1
		mv_src_f="${mv_src_f%.*}"
		mv_src_ext=
		file_changed=1
	fi

	if [ -n "${mv_dst_ext}" ] && [ -z "${mv_src_ext}" ]
	then
		assert_set "F_${me}" mv_compr_cmd &&
		try_compress "${mv_src_f}" "${mv_compr_cmd}" mv_src_f || return 1
		file_changed=1
	fi

	[ -n "${mv_bl_inst}" ] && {
		get_blocklist_md5 src_md5 "${mv_bl_inst}" &&
		is_hex_lc "${src_md5}" || { reg_failure "${me}: invalid md5 '${src_md5}' in blocklist filename '${mv_src_fname}' in dir '${mv_src_d}'."; return 1; }

		# recalculate md5 if needed
		dst_md5="${src_md5}"
		[ -n "${file_changed}" ] &&
			{ get_md5 dst_md5 "${mv_src_f}" || return 1; }
	}

	: "${dst_md5}"

	${transfer_cmd} "${mv_src_f}" "${mv_dst_f}" || return 1

	# Update metadata
	[ -n "${mv_bl_inst}" ] && eval "MD5_${mv_location}_${mv_bl_inst}"='${dst_md5}'

	:
}

