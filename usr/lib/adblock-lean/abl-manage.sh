#!/bin/sh
# shellcheck disable=SC3043,SC2016,SC3060,SC3040,SC3003,SC3020,SC3045
# shellcheck source=/dev/null

META_FNAME="blockset-metadata"
META_BASE_FNAME_PERSIST="persist_blockset-metadata"
META_FILE="${ABL_RUN_DIR}/${META_FNAME}"
META_PARAMS="PATH SINGLE_INSTANCE MD5 CNT"
META_PARAMS_PERSIST="PATH MD5 CNT"

IP_REGEX_4='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])'
IP_REGEX_6='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}'

VAR2CFG_MAP="$(
	# Format: <var>[=<cfg_opt>]
	printf '%s\n' "
		whitelist_mode
		raw_block_lists
		raw_allow_lists
		raw_ipv4_block_lists
		hosts_block_lists
		local_allowlist_path
		local_blocklist_path
		local_ipv4_blocklist_path
		persist_mode=persist_blockset_mode
		persist_dir=persist_blockset_dir
		test_domains
		max_part_size=max_part_size_KB
		max_set_size=max_blockset_size_KB
		min_blockset_entries
		custom_script
		dmsq_instances=dnsmasq_instances
		conf_dirs=dnsmasq_conf_dirs
	" |
	${AWK_CMD:?} '{$1=$1; split($0,a,"="); if (!a[1]) next; if (!a[2]) a[2] = a[1]; print a[1] "=" a[2]}'
)" &&

# Format: <local_var>=<global_var_prefix>
BL_PARAMS_MAP="
	${VAR2CFG_MAP}
	run_state=RUN_STATE
	skip_load_stop=SKIP_LOAD_STOP
	bk_file=BK_FILE
	bk_cnt=BK_CNT
	bk_ext=BK_EXT
	cur_persist_path=PERSIST_PATH
	cur_persist_cnt=PERSIST_CNT
	cur_persist_md5=PERSIST_MD5
	cur_path=PATH
	cur_md5=MD5
	cur_cnt=CNT
	cur_1_instance=SINGLE_INSTANCE
	install_path=INSTALL_PATH
	install_cnt=INSTALL_CNT
	install_path_ram=INSTALL_PATH_RAM
	install_1_instance=INSTALL_SINGLE_INSTANCE
	install_1_instance_ram=INSTALL_SINGLE_INSTANCE_RAM
	pause_path=PAUSE_PATH
	final_compress=FINAL_COMPRESS
	final_compr_ext=FINAL_COMPR_EXT
	final_extr_or_cat_stdout=FINAL_EXTR_OR_CAT_STDOUT
	final_compr_or_cat_stdout=FINAL_COMPR_OR_CAT_STDOUT
	final_compr_to_file=FINAL_COMPR_TO_FILE
	conf_script_log_avail=CONF_SCRIPT_LOG_AVAIL
"

# 'case' clauses for translating param name to global var name
BL_PARAMS_CLAUSES="$(
	printf '%s\n' "${BL_PARAMS_MAP}" |
	${SED_CMD:?} 's/\s//g;/^$/d;s/=/\) _gl_var=/; s/$/ ;;/'
)" &&

VAR2CFG_CLAUSES="$(
	printf '%s\n' "${VAR2CFG_MAP}" |
	${SED_CMD:?} 's/=/\) _cfg_opt=/; s/$/ ;;/'
)" || exit 1

get_cfg_opt()
{
	local _cfg_opt
	eval "
		case \"${2:?}\" in
			${VAR2CFG_CLAUSES}
			*) return 1 ;;
		esac
	"

	export -n "${1:?}=${_cfg_opt}"
}


# silence shellcheck warnings
: "${blue:=}" "${lblue:=}" "${green:=}" "${red:=}" "${orange:=}" "${n_c:=}"


# UTILITY FUNCTIONS

# 1 - var name to output extension
# 2 - var name to output compr util (gzip|zstd)
# 3 - path
get_compr_spec()
{
	local gcs_file gcs_ext gcs_util \
		extn_out_var="${1}" util_out_var="${2}" gcs_path="${3}"

	unset_vars "${extn_out_var}" "${util_out_var}"
	assert_set F_get_compr_spec extn_out_var util_out_var gcs_path || return 1

	gcs_file="${gcs_path##*"/"}"
	case "${gcs_file}" in
		*.gz) gcs_ext=.gz gcs_util=gzip ;;
		*.zst) gcs_ext=.zst gcs_util=zstd ;;
		*.*) reg_fail "Unexpected extension '${gcs_file##*.}' in file '${gcs_path}'."; return 1
	esac
	export -n "${extn_out_var}=${gcs_ext}" "${util_out_var}=${gcs_util}"
}

get_compr_util_spec()
{
	local gcu_util_path gcu_ext \
		util_path_out_var="${1}" ext_out_var="${2}" gcu_util_name="${3}"

	unset_vars "${1}" "${2}"
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
		*) reg_fail "Unexpected compression utility '${gcu_util_name}'."; false
	esac ||
	{
		gcu_util_path='' gcu_ext=''
		reg_fail "Compression utility '${gcu_util_name}' can not be used."
		if detect_util gcu_util_path "gzip" "" "/usr/libexec/gzip-gnu"
		then
			log_msg "Falling back to gzip compression."
			gcu_ext=.gz
		else
			log_msg "Intermediate and final blockset compression will be disabled."
			gcu_ext=
		fi
	}

	export -n "${util_path_out_var}=${gcu_util_path}" "${ext_out_var}=${gcu_ext}"

	:
}

# 1: blockset ID
# 2: input file
# 3: command including options
# 4: (optional) var name to output path to compressed file
try_compress()
{
	local IFS="${DEFAULT_IFS}" tc_cmd opts tc_err \
		tc_dir tc_fname tc_ext \
		tc_set_id="${1:?}" tc_in_file="${2}" tc_cmd="${3}" out_file_var="${4}"

	unset_vars "${out_file_var}"
	split_path tc_dir tc_fname _ "${tc_in_file}" && [ -n "${tc_fname}" ] && is_valid_dir "${tc_dir}" &&
	{
		is_dir_writable "${tc_set_id}" "${tc_dir}" ||
			{ tc_err="Logic bug: attempted to compress file '${tc_in_file}' to protected dir '${tc_dir}'."; false; }
	} &&

	case "${tc_cmd}" in
		*gzip*|*pigz*) tc_ext=.gz ;;
		*zstd*) tc_ext=.zst ;;
		*) tc_err="unexpected command '${tc_cmd}'."; false
	esac &&

	${tc_cmd} "${tc_in_file}" ||
		{
			reg_fail "try_compress: ${tc_err}${tc_err:+ }Failed to compress '${tc_in_file}'."
			rm_if_writable "${tc_set_id}" "${tc_in_file}";
			return 1
		}

	[ -n "${out_file_var}" ] && export -n "${out_file_var}=${tc_in_file}${tc_ext}"

	:
}

# 0 (optional): '-stdout' (does not remove source file)
# 1: path to file to extract
# 2 (optional): blockset ID
try_extract()
{
	local stdout=
	[ "${1}" = '-stdout' ] && { stdout=1; shift; }

	local IFS="${DEFAULT_IFS}" cmd opts \
		file_opts \
		stdout_opts \
		te_dir te_fname te_ext \
		te_err \
		te_file="${1:?}" te_set_id="${2}"

	split_path te_dir te_fname te_ext "${te_file}" && [ -n "${te_fname}" ] && is_valid_dir "${te_dir}" &&
	{
		[ -n "${stdout}" ] || is_dir_writable "${te_set_id}" "${te_dir}" ||
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
		[ -n "${stdout}" ] || rm_if_writable "${te_file}" # removes src and dest files
		reg_fail "try_extract: ${te_err}${te_err:+ }Failed to extract '${te_file}'."
		return 1
	}
}

detect_all_netdevs()
{
	[ -n "${ALL_NETDEVS}" ] && return 0
	ALL_NETDEVS="$(${SED_CMD:?} -n '/^\s*[^\s]*:/{s/^\s*//;s/:.*//p}' < /proc/net/dev | tr '\n' ' ')" &&
	trim_spaces ALL_NETDEVS &&
	[ -n "${ALL_NETDEVS}" ] &&
		return 0
	reg_fail "Failed to detect network devices."
	return 1
}


### dnsmasq support implementation

# Verifies that configured dnsmasq instances are running and that their names and conf-dirs match the config
#
# 1 - (optional) '-q' to quiet
check_dmsq_instances()
{
	cdi_fatal()
	{
		CDI_FATAL=1
		cdi_fail "${1}" "${2}"
		log_msg "Please run 'service adblock-lean select_dnsmasq_instances ${2}'." 
	}

	cdi_fail()
	{
		[ -n "${quiet}" ] && return 0
		reg_fail -fb "${2}" "${1}"
	}

	what_failed()
	{
		local set_id instance dmsq_instances conf_dirs param cfg_opt cfg_val _fail_ind _fail_sets
		unset_vars "${1}" "${2}"
		for set_id in ${SET_IDS}
		do
			for param in dmsq_instances conf_dirs
			do
				get_params "${set_id}" "${param}"
				get_params "${set_id}" "cfg_val=${param}"
				[ -n "${cfg_val}" ] ||
					{
						get_cfg_opt cfg_opt "${param}"
						cdi_fatal "'${cfg_opt}' config option is not set{}." "${set_id}"
						return 1
					}
			done

			for instance in ${dmsq_instances}
			do
				eval "[ \"\${RUNNING_${instance}}\" = 1 ]" && continue
				add2list _fail_ind "${instance}"
				add2list _fail_sets "${set_id}"
				set_params "${set_id}" run_state=1
			done
		done
		[ -n "${_fail_ind}" ] &&
		cdi_fail "dnsmasq instances '${_fail_ind//" "/"', '"}' are not running."
		export -n "${1}=${_fail_ind}" "${2}=${_fail_sets}"
		:
	}


	[ -n "${SET_IDS}" ] || return 0
	[ -n "${CDI_FATAL}" ] && return 1

	local me=check_dmsq_instances \
		quiet instance dir \
		set_id \
		instance_conf_dirs conf_dir_reg \
		conf_dirs \
		all_bl_conf_dirs \
		dmsq_instances \
		failed_instances failed_set_ids \
		skip_conf_dir_check \
		ok_seen \
		inst_pr

	[ "${1:-??}" = '-q' ] && quiet=1

	parse_dmsq_cfg || return 1
	parse_dmsq_runtime
	[ ${?} = 1 ] && return 1

	what_failed failed_instances failed_set_ids || return 1
	[ -n "${failed_instances}" ] &&
	{
		[ -n "${DMSQ_RESTART_TRIED}" ] && return 1
		case "${CUR_CMD}" in
			start|pause|resume|setup) ;;
			*) return 1
		esac
		DMSQ_RESTART_TRIED=1

		do_stop "${failed_set_ids}" || exit 1
		parse_dmsq_runtime
		[ ${?} = 1 ] && return 1

		what_failed failed_instances failed_set_ids || return 1
	}

	case "${CUR_ACT}" in
		start|stop|pause|resume|status|create_addnmounts|gen_persist_blockset) : ;;
		*) false
	esac ||
	case "${CUR_CMD}" in
		start|stop|pause|resume|create_addnmounts) : ;;
		*) false
	esac ||
		skip_conf_dir_check=1

	for set_id in ${SET_IDS}
	do
		is_included "${set_id}" "${failed_set_ids}" && continue
		get_params -f "${me}" "${set_id}" conf_dirs dmsq_instances || return 1
		all_bl_conf_dirs=

		for instance in ${dmsq_instances}
		do
			inst_pr="dnsmasq instance '${instance}'"
			# check if config section exists in /etc/config/dhcp
			uci show "dhcp.${instance}" &>/dev/null ||
			{
				cdi_fail "${inst_pr} is running but not registered in /etc/config/dhcp. Use the command 'service dnsmasq restart' and then re-try."
				CDI_FATAL=1
				return 1
			}

			[ -n "${skip_conf_dir_check}" ] && continue

			eval "instance_conf_dirs=\"\${R_CONF_DIRS_${instance}}\""
			[ -n "${instance_conf_dirs}" ] ||
				{ cdi_fail "Failed to detect conf-dirs for ${inst_pr}."; set_params "${set_id}" run_state=1; continue 2; }
			abl_append all_bl_conf_dirs "${instance_conf_dirs}"

			conf_dir_reg=
			for dir in ${instance_conf_dirs}
			do
				is_included "${dir}" "${conf_dirs}" && conf_dir_reg=1
				[ -d "${dir}" ] ||
				{
					cdi_fail "Conf-dir '${dir}' does not exist. ${inst_pr} is misconfigured."
					set_params "${set_id}" run_state=1
					continue 3
				}
			done

			[ -n "${conf_dir_reg}" ] ||
			{
				cdi_fatal "Conf-dirs for ${inst_pr} changed." "${set_id}"
				return 1
			}
		done

		[ -n "${skip_conf_dir_check}" ] && { ok_seen=1; continue; }

		for dir in ${conf_dirs}
		do
			is_included "${dir}" "${all_bl_conf_dirs}" ||
			{
				cdi_fatal "conf-dir directory '${dir}' is set in config{} but not used by configured dnsmasq instances '${dmsq_instances}'." "${set_id}"
				return 1
			}
		done
		ok_seen=1
	done

	[ -n "${ok_seen}" ]
}

# Sets vars:
#   C_PROCESSED
#   C_CONF_DIRS
#   C_DEVICES_${inst}
#   ADDNMOUNTS_${inst}
# shellcheck disable=SC2329
parse_dmsq_cfg()
{
	accum_list_nl()
	{
		add2list "${2}" "${1}" "${_NL_}"
	}

	config_get_list_nl()
	{
		config_list_foreach "${2}" "${3}" accum_list_nl "${1}"
	}

	get_devices()
	{
		local dev iface
		export -n "${1}="
		for iface in ${2}
		do
			network_get_device dev "${iface}" || dev="${iface}"
			add2list "${1}" "${dev}"
		done
	}

	process_instance()
	{
		local dir conf_dirs_nl ifaces notifaces devs notdevs

		unset "C_DEVICES_${1}" "ADDNMOUNTS_${1}"

		config_get_list_nl conf_dirs_nl "${1}" confdir
		case "${conf_dirs_nl}" in *" "*)
			reg_fail "dnsmasq instance '${1}' in /etc/config/dhcp specifies conf-dirs which have a space in their path - this is not supported."
			return 1
		esac
		for dir in ${conf_dirs_nl//"${_NL_}"/ }
		do
			is_valid_dir "${dir}" || continue
			add2list C_CONF_DIRS "${dir%/}"
		done

		config_get_list_nl "ADDNMOUNTS_${1}" "${1}" addnmount

		config_get ifaces "${1}" interface
		: "${ifaces:="${ALL_NETDEVS}"}"
		config_get notifaces "${1}" notinterface

		get_devices devs "${ifaces}"
		get_devices notdevs "${notifaces}"

		subtract_a_from_b "${notdevs}" "${devs}" devs
		export -n "C_DEVICES_${1}=${devs}"
		ok_seen=1
	}

	[ -n "${C_PROCESSED}" ] && return 0

	local ok_seen \
		net_sh=/lib/functions/network.sh
	unset C_CONF_DIRS C_PROCESSED

	debug_msg "" "Parsing dnsmasq config."

	detect_all_netdevs || return 1

	dbg_off
	# gather conf dirs from /etc/config/dhcp, assemble C_DEVICES_${inst}
	config_load_a dhcp || { dbg_on; return 2; }
	dbg_on
	assert_file_found "${net_sh}" || return 1
	. "${net_sh}"

	config_foreach process_instance dnsmasq

	[ -n "${ok_seen}" ] || return 1

	C_PROCESSED=1
	:
}

# Env vars: PDR_QUIET
#
# Populates global vars:
#   R_CONF_DIRS, DMSQ_RUNNING_INSTANCES, DMSQ_RUNNING_INST_CNT
#   R_DEVICES_${instance}, R_CONF_DIRS_${instance}, R_CONF_DIRS_CNT_${instance}, RUNNING_${instance}
#   R_PROCESSED
#
# return codes:
# 0: OK
# 1: Fatal error
# 2: No running instances
parse_dmsq_runtime()
{
	j_unwind()
	{
		while [ ${j_level} -gt 0 ]
		do
			j_level=$((j_level-1))
			json_select ..
		done
	}

	j_sel_obj()
	{
		json_select "${1}" &&
		case "${1}" in
			..) j_level=$((j_level - 1)) ;;
			*) j_level=$((j_level + 1))
		esac
	}

	parse_fail() { reg_fail "Failed to process info for dnsmasq instance '${1}'${2:+ (code ${2})}."; }
	no_running_inst() {
		[ -n "${PDR_QUIET}" ] && return
		reg_fail "No running dnsmasq instances found in dnsmasq runtime info${1:+ (code ${1})}."
		reg_msg "netstat output:" "'${netstat_output}'"
	}

	[ -n "${R_PROCESSED}" ] &&
		is_gr_eq 1 "${DMSQ_RUNNING_INST_CNT}" && return 0

	local me=parse_dmsq_runtime \
		IFS="${DEFAULT_IFS}" \
		nonempty instance instances running l1_conf_file l1_conf_files conf_dirs_cnt conf_dirs_nl i s f dir ujail_pid line \
		ns ns_parse_res \
		devs not_devs devs_by_instance instances_by_ujail_pid \
		j_level=0 \
		jshn_sh=/usr/share/libubox/jshn.sh

	assert_set "F_${me}" C_PROCESSED || { [ -n "${ASSERT_NOEXIT}" ] || exit 1; return 1; }

	unset DMSQ_RUNNING_INSTANCES R_CONF_DIRS R_PROCESSED
	DMSQ_RUNNING_INST_CNT=0
	debug_msg "" "Parsing dnsmasq runtime info."

	# gather conf dirs from /tmp/
	set +f
	for dir in /tmp/dnsmasq.d /tmp/dnsmasq.cfg*
	do
		set -f
		case "${dir}" in
			''|*".cfg*"|'/') continue ;;
			/*) add2list R_CONF_DIRS "${dir%/}" ;;
		esac
	done
	set -f

	# gather info from: ubus call service list

	assert_file_found "${jshn_sh}" || return 1
	dbg_off
	. "${jshn_sh}"
	json_load "$(ubus call service list '{"name":"dnsmasq"}')" &&
	json_get_keys nonempty &&
	[ -n "${nonempty}" ] &&
	json_is_a dnsmasq object &&
	json_select dnsmasq &&
	json_is_a instances object &&
	json_select instances &&
	json_get_keys instances &&
	[ -n "${instances}" ] || { no_running_inst 1; dbg_on; return 2; }

	dbg_on
	detect_all_netdevs || return 1
	dbg_off

	for instance in ${instances}
	do
		json_is_a "${instance}" object &&
		is_alphanum "${instance}" ||
			continue
		unset "RUNNING_${instance}" "R_DEVICES_${instance}" "R_CONF_DIRS_${instance}" "R_CONF_DIRS_CNT_${instance}"
		conf_dirs_nl=
		conf_dirs_cnt=0
		devs=
		not_devs=
		running=

		j_sel_obj "${instance}" ||
			{ parse_fail "${instance}" A; continue; }
		json_get_var running running &&

		[ "${running}" = 1 ] &&
		{
			json_get_var ujail_pid pid &&
			json_is_a command array &&
			j_sel_obj command &&
			[ -n "${ujail_pid}" ] ||
				{ parse_fail "${instance}" B; j_unwind; continue; }

			abl_append DMSQ_RUNNING_INSTANCES "${instance}"
			abl_append instances_by_ujail_pid "${ujail_pid}=${instance}" "${_DELIM_}"

			# look for '-C' in values, get next value which is instance's conf file
			l1_conf_files=
			i=0
			while json_is_a $((i+1)) string
			do
				i=$((i+1))
				json_get_var s ${i}
				[ "${s}" = '-C' ] || continue
				json_get_var l1_conf_file $((i+1)) ||
					{ parse_fail "${instance}" C; j_unwind; continue 2; }
				add2list l1_conf_files "${l1_conf_file}" "${_NL_}"
			done

			j_sel_obj ..

			IFS="${_NL_}"
			set -- ${l1_conf_files}
			IFS="${DEFAULT_IFS}"

			# get devices for instance
			devs="$( ${SED_CMD:?} -n '/^\s*interface=/{s/^.*=//;s/^\s*//;s/\s*$//;/^$/d;p}' "${@}")"
			: "${devs:="${ALL_NETDEVS}"}"
			not_devs="$( ${SED_CMD:?} -n '/^\s*except-interface=/{s/^.*=//;s/^\s*//;s/\s*$//;/^$/d;p}' "${@}")"
			subtract_a_from_b "${not_devs//"${_NL_}"/ }" "${devs//"${_NL_}"/ }" devs
			abl_append devs_by_instance "${instance}=${devs}" "${_DELIM_}"

			debug_msg "${me}: ${instance} devs: '${devs}'"

			# get conf-dirs for instance
			conf_dirs_nl="$(
				for f in "${@}"
				do
					${SED_CMD} -n '/^\s*conf-dir=/{s/.*=//;s/^\s*//;s~/$~~;/^$/d;/[^\s]/p;}' "${f}"
				done | ${SORT_CMD:?} -u
			)"

			case "${conf_dirs_nl}" in *" "*)
				reg_fail "Runtime info for dnsmasq instance '${instance}' specifies conf-dirs which have a space in their path - this is not supported."
				parse_fail "${instance}" D
				j_unwind
				continue
			esac
			cnt_lines conf_dirs_cnt "${conf_dirs_nl}"
			add2list R_CONF_DIRS "${conf_dirs_nl//"${_NL_}"/ }"
		}

		j_unwind

		export -n \
			"RUNNING_${instance}=${running}" \
			"R_CONF_DIRS_${instance}=${conf_dirs_nl//"${_NL_}"/ }" \
			"R_DEVICES_${instance}=${devs}" \
			"R_CONF_DIRS_CNT_${instance}=${conf_dirs_cnt}"
	done
	json_cleanup

	dbg_on
	cnt_lines DMSQ_RUNNING_INST_CNT "${DMSQ_RUNNING_INSTANCES// /"${_NL_}"}"

	# Get nameserver IP's

	# shellcheck disable=SC2155
	local \
		ip_output="$(${IP_CMD:?} -o addr show)" \
		netstat_output="$(${NETSTAT_CMD:?} -plnt 2>/dev/null)"

	[ "${DMSQ_RUNNING_INST_CNT}" -gt 0 ] || { no_running_inst 2; return 2; }


	ns_parse_res="$(
		set +f
		set +x
		{ cat /proc/[0-9]*/stat 2>/dev/null || true; } |
	    ${AWK_CMD:?} \
			-v delim="${_DELIM_}" \
			-v instances_by_ujail_pid_str="${instances_by_ujail_pid}" \
			-v devs_by_instance_str="${devs_by_instance}" \
			-v netstat_output="${netstat_output}" \
			-v ip_output="${ip_output//"\ "/ }" \
			-v regex_4="^${IP_REGEX_4}(%[^:]+){0,1}#[0-9]+$" -v regex_6="^${IP_REGEX_6}(%[^:]+){0,1}#[0-9]+$" '

		function append(cur,new) {
			if (! cur) return new
			if (! new) return cur
			return cur " " new
		}

		function rank_ip(ip, inst_name,     dev, port) {
			# rank:
			# 0 = lo
			# 1 = RFC1918 ipv4
			# 2 = ULA ipv6
			# 3 = other ipv4
			# 4 = other ipv6

			if (inst_name !~ /^[a-zA-Z0-9_]+$/) {exit 1}

			ip=tolower(ip)

			# Use <ip%dev> syntax for ipv6 link-local unicast
			if (ip ~ /^fe[89ab]/) {
				match (ip, /#.*$/)
				port=substr(ip, RSTART, RLENGTH)
				sub(/#.*/, "", ip)
				dev = dev_by_ip[ip]
				if (dev) dev = "%" dev
				ip = ip dev port
			}

			if (ip ~ regex_4)
				if (ip ~ /^127\./)
					reg_ip(ip,"lo",inst_name)

				else if (ip ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/)
					reg_ip(ip,"rfc1918",inst_name)
				else
					reg_ip(ip,"other_4",inst_name)
			else if (ip ~ regex_6)
				if (ip ~ /^::1#[0-9]+$/)
					reg_ip(ip,"lo",inst_name)

				else if (ip ~ /^(fc|fd)/)
					reg_ip(ip,"ula",inst_name)

				else
					reg_ip(ip,"other_6",inst_name)
			# ignore non-matching input
		}

		function reg_ip(ip,type,inst_name) {
			cnt_local = cnt[inst_name "-" type] + 1
			cnt_global= cnt[inst_name] + 1
			if (cnt_local > max_local[type] || cnt_global > max_global) return
			cnt[inst_name "-" type]++
			cnt[inst_name]++

			instances[inst_name]
			ips_arr[inst_name "_" type "_" cnt_local] = ip
		}

		BEGIN {
			types[1] = "lo"
			types[2] = "rfc1918"
			types[3] = "ula"
			types[4] = "other_4"
			types[5] = "other_6"
			types_cnt=5

			max_global = 16
			max_local["lo"] = 2
			max_local["rfc1918"] = 5
			max_local["ula"] = 3
			max_local["other_4"] = 3
			max_local["other_6"] = 3

			# map ujail PIDs to instance names
			split( instances_by_ujail_pid_str, p, delim )
			for (e in p) {
				pair = p[e]
				if (! pair) continue
				split(pair,p_el,"=")
				instances_by_ujail_pid[p_el[1]] = p_el[2]
			}

			# map [dev] to [IP]
			split( ip_output, I, "\n" )
			for (e in I) {
				line = I[e]
				if (! line) continue
				split( line, l_el, " ")
				dev=l_el[2]
				ip = tolower( l_el[4] )
				sub(/\/.*/, "", ip)
				if (! ip) continue
				dev_by_ip[ip] = dev
				if (i2i_seen[ip]++) continue
				ips_by_dev[dev] = append( ips_by_dev[dev], ip )
			}

			# map [instance name] to <[IP] [IP] ...>
			split( devs_by_instance_str, f, delim )
			for (e in f) {
				pair = f[e]
				if (! pair) continue
				split( pair, f_el, "=" )
				inst_name=f_el[1]
				devs_str=f_el[2]
				if (! inst_name || ! devs_str) continue
				split( devs_str, devs_arr, " ")
				for (i in devs_arr) {
					dev=devs_arr[i]
					if (! dev) continue
					ips_by_instance[inst_name] = append( ips_by_instance[inst_name], ips_by_dev[dev] )
				}
			}
		}

		# find dnsmasq PIDs (children of ujail PIDs);
		# map PIDs to instance names
		/\([ 	]*dnsmasq[ 	]*\)/ {
			pid=$1
			sub(/^.*\) /, "", $0)
			$0 = $0
			ppid = $2
			if (ppid in instances_by_ujail_pid) {} else next
			inst_name = instances_by_ujail_pid[ppid]
			instances_by_pid[pid] = inst_name
		}

		END {
			n = split(netstat_output, n_lines, "\n")

			for (i=1; i<=n; i++) {
				line=n_lines[i]
				if ( line !~ /LISTEN[ ].*\/dnsmasq$/) continue
				$0 = line

				pid = $7
				if (pid !~ /\/dnsmasq$/) continue
				sub("/dnsmasq","",pid)

				inst_name=instances_by_pid[pid]
				if (! inst_name) continue

				ip = $4

				# separate port from ip
				port=ip
				sub(/:[0-9]+$/, "", ip)
				sub("^" ip ":", "", port)

				if (port !~ /^[0-9]+$/) {exit 1}

				# non-wildcard listeners
				if (ip != "0.0.0.0" && ip != "::") {
					# use port of the listener
					ip = ip "#" port
					# deduplicate
					if (seen[ip]++) continue
					rank_ip( ip, inst_name )
					continue
				}

				# wildcard listeners
				# uses port of the wildcard listener, per-instance IPs of devs gathered from l1_conf_files
				split( ips_by_instance[inst_name], ips_tmp_arr, " " )
				for (j in ips_tmp_arr) {
					ip=ips_tmp_arr[j] "#" port
					if (seen[ip]++) continue
					rank_ip( ip, inst_name )
				}
			}

			for (inst_name in instances) {
				printf "%s=", inst_name
				for (i = 1; i <= types_cnt; i++) {
					type = types[i]
					for (j = 1; j <= cnt[inst_name "-" type]; j++) {
						printf "%s ", ips_arr[inst_name "_" type "_" j]
					}
				}
				printf "\n"
			}
		}'
	)" ||
	{
		reg_fail "" "Failed to get nameserver IPs for dnsmasq instances."
		reg_msg \
			"For diagnostics:" \
			"" "devs_by_instance:" "'${devs_by_instance//"${_DELIM_}"/"${_NL_}"}'" \
			"" "netstat output:" "'${netstat_output}'" \
			"" "ip output:" "'${ip_output}'"
		return 1
	}


	debug_msg "ns_parse_res:${_NL_}'${ns_parse_res}'"

	[ -n "${ns_parse_res}" ] ||
		{ no_running_inst 3; return 2; }

	IFS="${_NL_}"
	for line in ${ns_parse_res}
	do
		IFS="${DEFAULT_IFS}"
		line="${line% }"

		case "${line}" in
			'') continue ;;
		esac

		instance="${line%%=*}"
		ns="${line#"${instance}="}"

		[ -n "${instance}" ] &&
		is_included "${instance}" "${instances}" ||
			{ reg_fail "${me}: invalid line in parser output: '${line}'."; return 1; }
		[ -n "${ns}" ] ||
			{ reg_fail "${me}: failed to detect active nameserver IP's for dnsmasq instance '${instance}'"; return 1; }
		export -n "NS_${instance}=${ns}"
	done
	IFS="${DEFAULT_IFS}"

	PRIMARY_NS=$( ${SED_CMD:?} -En '/^\s*nameserver/{s/\s*nameserver\s+//;s/\s+$//;/^$/d;p}' /etc/resolv.conf )
	export -n PRIMARY_NS="${PRIMARY_NS//"${_NL_}"/ }"
	: "${PRIMARY_NS:="127.0.0.1 ::1"}"

	R_PROCESSED=1
}

# Analyze dnsmasq instances and set params for each blockset: dmsq_instances, conf_dirs
# 1 (optional): blockset ID's (defaults to all), validity checked by caller
do_select_dnsmasq_instances() {
	get_pr_devs()
	{
		local devs r_devs c_devs instance instances="${2}"
		for instance in ${instances}
		do
			eval "devs=\"\${R_DEVICES_${instance}}\""
			add2list r_devs "${devs}"
			eval "devs=\"\${C_DEVICES_${instance}}\""
			add2list c_devs "${devs}"
		done
		if \
			subtract_a_from_b "${r_devs}" "${c_devs}" &&
			subtract_a_from_b "${c_devs}" "${r_devs}"
		then
			export -n "${1}=network devices: '${blue}${c_devs// /${n_c}, ${blue}}${n_c}'"
		else
			export -n "${1}=config network devices: '${blue}${c_devs// /${n_c}, ${blue}}${n_c}', runtime network devices: '${blue}${r_devs// /${n_c}, ${blue}}${n_c}'"
		fi
	}

	validate_input()
	{
		printf '%s\n' "${1}" |
		${SED_CMD} -E 's/\s+/ /g;s/^\s+//;s/\s+$//' |
		grep -E "^(${2// /|})( +(${2// /|}))*$"
	}

	local me=select_dnsmasq_instances \
		index indexes \
		conf_dirs conf_dirs_instance conf_dirs_seen conf_dirs_cnt \
		select_conf_dirs \
		instance luci_instances \
		force_instances \
		select_instances \
		select_devs_pr \
		devs_pr \
		REPLY \
		first diff \
		add_dir \
		set_id \
		set_ids="${1:-"${SET_IDS}"}"

	local CUR_CMD="${me}"

	assert_set "F_${me}" SET_IDS &&
	parse_dmsq_cfg &&
	parse_dmsq_runtime || return 1

	[ -n "${DMSQ_RUNNING_INSTANCES}" ] && [ "${DMSQ_RUNNING_INST_CNT}" -gt 0 ] ||
		{ reg_fail "Internal error parsing dnsmasq runtime info."; return 1; }

	first=1 diff=''
	if [ "${DMSQ_RUNNING_INST_CNT}" = 1 ]
	then
		force_instances="${DMSQ_RUNNING_INSTANCES%% *}"
		reg_msg "" "Detected only 1 dnsmasq instance." "Skipping manual dnsmasq instance selection."
	elif
		{
			# check if all instances share same conf-dirs
			for instance in ${DMSQ_RUNNING_INSTANCES}
			do
				eval "conf_dirs_instance=\"\${R_CONF_DIRS_${instance}}\""
				case "${first}" in
					1)
						first=
						conf_dirs="${conf_dirs_instance}" ;;
					'')
						# conf-dirs are sorted, so we can directly compare
						[ "${conf_dirs_instance}" = "${conf_dirs}" ] && continue
						diff=1
						break
				esac
				[ -n "${conf_dirs}" ] && conf_dirs_seen=1
			done
			[ -n "${conf_dirs_seen}" ] &&
			[ -z "${diff}" ]
		}
	then
		force_instances="${DMSQ_RUNNING_INSTANCES}"
		reg_msg "" "Detected multiple dnsmasq instances which are using the same conf-dirs: ${_NL_}${blue}${conf_dirs// /" ${_NL_}"}${n_c}" "Skipping manual dnsmasq instance selection."
	elif [ -z "${conf_dirs_seen}" ]
	then
		reg_fail "Failed to detect dnsmasq conf-dir paths for dnsmasq instances '${DMSQ_RUNNING_INSTANCES}'."
		return 1
	else
		reg_msg -blue "Multiple dnsmasq instances detected."
		if [ "${DO_DIALOGS}" = 1 ]
		then
			reg_msg "" "Running dnsmasq instances and assigned network devices:"
			index=1
			for instance in ${DMSQ_RUNNING_INSTANCES}
			do
				local "instance_${index}=${instance}"
				get_pr_devs devs_pr "${instance}"
				reg_msg "${index}: Instance '${orange}${instance}${n_c}', ${devs_pr}"
				abl_append indexes "${index}"
				index=$((index+1))
			done
		fi
	fi

	for set_id in ${set_ids}
	do
		select_instances='' select_devs_pr='' select_conf_dirs=''
		if [ -n "${force_instances}" ]
		then
			select_instances=${force_instances}
		else
			# Ask the user
			eval "luci_instances=\"\${luci_dmsq_instances_${set_id}}\""
			REPLY=a
			if [ "${DO_DIALOGS}" = 1 ]
			then
				print_msg -fb "${set_id}" "" "Please select which dnsmasq instance should have active adblocking{}, or 'a' to abort." \
					"To adblock on multiple instances, enter multiple instances separated by spaces."
				while :
				do
					printf %s "${lblue}${indexes// /${n_c}|${lblue}}${n_c}|${lblue}a${n_c}: " > "${MSGS_DEST}"
					read -r REPLY
					if [ "${REPLY}" = a ]
					then
						reg_msg "Aborted config generation."
						exit 0
					elif REPLY="$(validate_input "${REPLY}" "${indexes}")"
					then
						for index in ${REPLY}
						do
							eval "instance=\"\${instance_${index}}\""
							add2list select_instances "${instance}"
						done
					elif REPLY="$(validate_input "${REPLY}" "${DMSQ_RUNNING_INSTANCES}")"
					then
						add2list select_instances "${REPLY}"
					else
						printf '\n%s\n\n' "Please enter any combination of [${indexes}], or 'a' to abort." > "${MSGS_DEST}"
						continue
					fi
					break
				done
			elif [ -n "${luci_instances}" ]
			then
				REPLY="$(validate_input "${luci_instances}" "${DMSQ_RUNNING_INSTANCES}")" ||
					{ reg_fail "Invalid dnsmasq instances '${luci_instances}' (running instances: '${DMSQ_RUNNING_INSTANCES}')."; return 1; }
				add2list select_instances "${REPLY}"
			else
				reg_fail -fb "${set_id}" "dnsmasq instances not specified{}."
				return 1
			fi
		fi

		get_pr_devs select_devs_pr "${select_instances}"
		log_msg -fb "${set_id}" "Selected dnsmasq instances{}: '${select_instances}', ${select_devs_pr}."

		for instance in ${select_instances}
		do
			add_dir=
			eval "conf_dirs=\"\${R_CONF_DIRS_${instance}}\"
				conf_dirs_cnt=\"\${R_CONF_DIRS_CNT_${instance}}\""

			if [ "${conf_dirs_cnt}" = 1 ]
			then
				add_dir="${conf_dirs}"
			else
				if is_included "/tmp/dnsmasq.d" "${conf_dirs}"
				then
					add_dir="/tmp/dnsmasq.d"
				elif is_included "/tmp/dnsmasq.cfg01411c.d" "${conf_dirs}"
				then
					add_dir="/tmp/dnsmasq.cfg01411c.d"
				else
					# fall back to first conf-dir
					add_dir="${conf_dirs%% *}"
				fi
			fi
			[ -n "${add_dir}" ] && add2list select_conf_dirs "${add_dir}"
		done

		[ -n "${select_conf_dirs}" ] || { reg_fail "Failed to detect conf-dirs for dnsmasq instances '${select_instances}'."; return 1; }

		log_msg "Selected dnsmasq conf-dirs: '${blue}${select_conf_dirs// /"${n_c}', '${blue}"}${n_c}'"
		set_params "${set_id}" dmsq_instances="${select_instances}" conf_dirs="${select_conf_dirs}"
	done

	check_dmsq_instances || return 1

	:
}


### GENERAL HELPER FUNCTIONS

get_affected_set_ids()
{
	local ges_id ges_all ges_inst ges_inst_tmp ges_state
	unset_vars "${1}"
	for ges_id in ${2}
	do
		get_params "${ges_id}" ges_inst=dmsq_instances
		add2list ges_all "${ges_inst}"
	done

	for ges_id in ${SET_IDS}
	do
		is_included "${ges_id}" "${2}" && continue
		get_params "${ges_id}" ges_state=run_state ges_inst=dmsq_instances
		[ "${ges_state}" = 0 ] || continue
		subtract_a_from_b "${ges_inst}" "${ges_all}" ges_inst_tmp
		[ "${#ges_inst_tmp}" = "${#ges_all}" ] && continue
		abl_append "${1}" "${ges_id}"
	done
}

# shellcheck disable=SC2046,SC2086
unset_param_vars()
{
	[ -n "${BL_PARAMS_MAP}" ] && [ -n "${1}" ] || return 0
	local vars
	vars=$(
		${AWK_CMD:?} -v MAP="${BL_PARAMS_MAP}" -v IDS="${1}" \
		'
			BEGIN{
				split(MAP,map_in,"\n")
				split(IDS,ids_in," ")
				for (ind in ids_in) {
					id=ids_in[ind]
					if (! id) continue
					ids_arr[id]
				}
				for (ind in map_in) {
					param_var=map_in[ind]
					sub(/^.*=/,"",param_var)
					sub(/[ \t]+$/,"",param_var)
					if (!param_var) continue
					for (id in ids_arr) {if (id) printf "%s ", param_var "_" id}
				}
			}
		'
	)
	debug_msg "unset ${vars}"
	unset ${vars}
}

mv_blockset()
{
	local me=mv_blockset mv_rv \
		mv_src_f="${1:?}" mv_dst_f="${2:?}" mv_compr_cmd="${3}" mv_set_id="${4:?}"

	debug_msg "${me} start: '${mv_src_f}' to '${mv_dst_f}'"

	assert_set "F_${me}" mv_src_f mv_dst_f &&
	try_mv_blockset "${@}"
	mv_rv=${?}

	debug_msg "${me} end"
	[ "${mv_rv}" = 0 ] &&
		{ set_params "${mv_set_id}" cur_path="${mv_dst_f}"; return 0; }

	rm_if_writable "${mv_set_id}" "${mv_src_f}" "${mv_dst_f}"
	reg_fail "Failed to move blockset '${mv_set_id}' from '${mv_src_f}' to '${mv_dst_f}' (cmd: '${mv_compr_cmd}')."
	return 1
}

# Args:
# 1: src path
# 2: dst path
# 3: compression cmd
# 4: blockset ID
# If src dir is protected, copy file instead of moving
try_mv_blockset()
{
	local me=try_mv_blockset \
		transfer_cmd="try_mv -q" \
		md5_changed \
		cur_md5 \
		mv_src_d mv_src_ext \
		mv_dst_d mv_dst_ext \
		mv_src_f="${1}" mv_dst_f="${2}" mv_compr_cmd="${3}" mv_set_id="${4:?}"

	split_path mv_src_d _ mv_src_ext "${mv_src_f}" &&
	split_path mv_dst_d _ mv_dst_ext "${mv_dst_f}" || return 1

	is_valid_dir "${mv_src_d}" && is_valid_dir "${mv_dst_d}" || { reg_fail "${me}: unexpected src dir '${mv_src_d}' or dest dir '${mv_dst_d}'."; return 1; }

	[ -f "${mv_src_f}" ] || { reg_fail "${me}: file '${mv_src_f}' not found."; return 1; }

	[ "${mv_src_f}" = "${mv_dst_f}" ] && return 0

	is_dir_writable "${mv_set_id}" "${mv_dst_d}" || { reg_fail "${me}: logic bug: attempted write into protected dir '${mv_dst_d}'."; return 1; }

	is_dir_writable "${mv_set_id}" "${mv_src_d}" || transfer_cmd="cp"

	if [ -n "${mv_src_ext}" ] && [ "${mv_src_ext}" != "${mv_dst_ext}" ]
	then
		try_extract "${mv_src_f}" "${mv_set_id}" || return 1
		mv_src_f="${mv_src_f%.*}"
		mv_src_ext=
		md5_changed=1
	fi

	if [ -n "${mv_dst_ext}" ] && [ -z "${mv_src_ext}" ]
	then
		try_compress "${mv_set_id}" "${mv_src_f}" "${mv_compr_cmd:?}" mv_src_f || return 1
		md5_changed=1
	fi

	${transfer_cmd} "${mv_src_f}" "${mv_dst_f}" || return 1

	[ -n "${md5_changed}" ] &&
	{
		get_md5 cur_md5 "${mv_dst_f}" || return 1
		set_params "${mv_set_id}" cur_md5
	}

	:
}

is_persist()
{
	local persist_dir
	get_params "${2}" persist_dir
	[ -n "${persist_dir}" ] &&
	[ -n "${1%/*}" ] &&
	[ "${1%/*}" = "${persist_dir}" ]
}

# Make sure the directory is not the same as the mount point
check_persist_dir()
{
	local quiet
	[ "${1}" = '-q' ] && { quiet=1; shift; }
	local mnt_point persist_dir \
		set_id="${1}"

	get_params "${set_id}" persist_dir

	[ -d "${persist_dir}" ] ||
	{
		[ -n "${quiet}" ] ||
		case "${persist_dir}" in
			''|/) reg_fail "Empty or invalid persistent blockset directory '${persist_dir}' specified in config option persist_blockset_dir." ;;
			*) reg_fail "Can not find persistent blockset directory: ${persist_dir}"
		esac
		return 1
	}

	mnt_point="$(${DF_CMD} "${persist_dir}" |
		${AWK_CMD} '/^[ \t]*Filesystem[ \t]/{next} {i++; print $6} END{ if(i == 1) exit 0; exit 1}')" &&
	[ -d "${mnt_point}" ] ||
		{ [ -n "${quiet}" ] || reg_fail "Failed to get the mount point for partition where the persistent blockset is stored (got '${mnt_point}')."; return 1; }

	[ "${persist_dir}" != "${mnt_point}" ] ||
		{  [ -n "${quiet}" ] || reg_fail "Persistent directory '${persist_dir}' is the same as the mount point. Please use a subdirectory."; return 1; }

	:
}

check_persist_blockset()
{
	local max_set_size min_entries min_entries_human \
		persist_check_rv \
		persist_ext persist_mode persist_dir \
		cur_persist_path cur_persist_cnt cur_persist_cnt_human cur_persist_size_b \
		run_state \
		set_id="${1}" final_compr_ext="${2}"

	get_params -f "check_persist_blockset" "${set_id}" persist_mode persist_dir min_entries=min_blockset_entries max_set_size || return 1
	get_params "${set_id}" run_state cur_persist_path
	debug_msg "Checking persistent blockset file: ${blue}${cur_persist_path}${n_c}"

	{
		[ -n "${cur_persist_path}" ] ||
			{
				[ "${CUR_ACT}" != gen_persist_blockset ] &&
				{ [ "${run_state}" != 4 ] || [ "${persist_mode}" = manual ]; } &&
					reg_fail -fb "${set_id}" "Persistent blockset file{} not found in directory '${persist_dir}'."
				false
			}
	} &&

	{
		get_compr_spec persist_ext _ "${cur_persist_path}" ||
			{ reg_fail "Can not find utility to extract persistent blockset file '${cur_persist_path}'."; false; }
	} &&

	{
		[ "${persist_ext}" = "${final_compr_ext}" ] ||
		{
			reg_fail "Extension '${persist_ext}' of persistent blockset file '${cur_persist_path}' does not match required extension '${final_compr_ext}'."
			persist_check_rv=1
		}
	} &&

	cur_persist_size_b="$(get_file_size "${cur_persist_path}")" &&
	{
		[ $(( cur_persist_size_b/1024 )) -le "${max_set_size}" ] ||
		{ reg_fail "Persistent blockset file '${cur_persist_path}' is larger than the maximum value set in config (${max_set_size} KiB)."; false; }
	} &&

	{
		read_blockset_metadata -persist "${cur_persist_path%/*}/${META_BASE_FNAME_PERSIST:?}-${set_id}" "${set_id}" "${cur_persist_path}" &&
		get_params "${set_id}" cur_persist_cnt &&
		[ -n "${cur_persist_cnt}" ] ||
		{ reg_fail "Failed to process metadata for persistent blockset file '${cur_persist_path}'."; false; }
	} &&

	{
		[ "${cur_persist_cnt}" -ge "${min_entries}" ] ||
			{
				int2human cur_persist_cnt_human "${cur_persist_cnt}"
				int2human min_entries_human "${min_entries}" || return 1
				reg_fail "Entries count (${cur_persist_cnt_human}) in the persistent blockset file '${cur_persist_path}' is below the minimum value set in config (${min_entries_human})."
				false
			}
	} &&
	[ "${persist_check_rv}" != 1 ] &&
		return 0

	return 1
}

# 1: var name for printable missing paths output
# 2: dnsmasq instances to check
# 3: list of newline-separated paths
# shellcheck disable=SC2120
check_addnmounts()
{
	try_check_addnmounts "${@}" || { reg_fail "Failed to check addnmount entries."; return 1; }
}

try_check_addnmounts()
{
	local me=check_addnmounts \
		IFS="${DEFAULT_IFS}" i \
		ca_instance ca_path ca_path_tmp ca_addnmounts \
		ca_missing_var="${1}" ca_instances="${2}" ca_req_addnm="${3}"

	unset_vars "${ca_missing_var}"
	assert_set "F_${me}" ca_instances C_PROCESSED || return 1

	[ -n "${ca_req_addnm}" ] || return 0

	for ca_instance in ${ca_instances}
	do
		is_alphanum "${ca_instance}" || { reg_fail "${me}: Invalid dnsmasq instance name '${ca_instance}'."; return 1; }
		IFS="${_NL_}"
		for ca_path in ${ca_req_addnm}
		do
			[ -n "${ca_path}" ] || continue
			IFS="${DEFAULT_IFS}"

			eval "ca_addnmounts=\"\${ADDNMOUNTS_${ca_instance}}\""
			case "${ca_path}" in
				/*) ;;
				*) reg_fail "${me}: invalid path '${ca_path}'."; return 1
			esac

			ca_path_tmp="${ca_path}"
			i=1
			while [ -n "${ca_path_tmp}" ] && [ "${i}" -le 10 ]
			do
				i=$((i+1))
				is_included "${ca_path_tmp}" "${ca_addnmounts}" "${_NL_}" && continue 2
				ca_path_tmp="${ca_path_tmp%/*}"
			done

			[ -n "${ca_missing_var}" ] && add2list "${ca_missing_var}" "${ca_path}" ", "
		done
		IFS="${DEFAULT_IFS}"
	done
	:
}

set_all_env()
{
	set_global_env &&
	set_blocksets_env "${@}"
}

# Populates global vars required for processing, status and cleanup
# 1 (optional): blockset IDs (defaults to all)
set_global_env()
{
	[ -n "${SKIP_SET_ENV}" ] && return 0

	local \
		me=set_global_env \
		set_id \
		compr_util_path \
		compr_ext \
		cpu_cnt

	export -n \
		PARALLEL_JOBS='' \
		INTERM_COMPR_OR_CAT_STDOUT="${CAT_CMD}" \
		INTERM_COMPR_EXT='' \
		INTERM_COMPR_TO_FILE=''

	debug_msg "" "start ${me}()"

	assert_set "F_${me}" CONFIG_LOADED || return 1

	[ -n "${ABL_HOSTNAME_SET}" ] || ABL_HOSTNAME="$(uci get system.@system[0].hostname)"
	export -n ABL_HOSTNAME ABL_HOSTNAME_SET=1

	# Parallel processing
	case "${MAX_PARALLEL_JOBS}" in
		auto)
			cpu_cnt="$(grep -c '^processor\s*:' /proc/cpuinfo)"
			if is_uint "${cpu_cnt}"
			then
				# cap PARALLEL_JOBS to 4 in 'auto' mode
				PARALLEL_JOBS=$(( (cpu_cnt>4)*4 + (cpu_cnt<=4)*cpu_cnt ))
			else
				reg_fail "Failed to detect CPU core count. Parallel processing will be disabled."
				PARALLEL_JOBS=1
			fi ;;
		*)
			PARALLEL_JOBS="${MAX_PARALLEL_JOBS}"
	esac

	# Compression util
	get_compr_util_spec compr_util_path compr_ext "${compression_util:?}" || return 1

	# dnsmasq instances
	check_dmsq_instances || return 1

	# check for missing addnmounts during version update
	if [ -n "${ABL_IN_INSTALL:-"${upd_channel}"}" ] && [ -n "${SET_IDS}" ] && [ -z "${ADDNMOUNTS_CHECKED}" ]
	then
		export -n ADDNMOUNTS_CHECKED=1
		do_create_addnmounts
	fi

	# Interm compr commands
	[ -n "${compr_ext}" ] &&
	{
		INTERM_COMPR_OR_CAT_STDOUT="${compr_util_path} -c"
		INTERM_COMPR_TO_FILE="${compr_util_path} -f"
		INTERM_COMPR_EXT=${compr_ext}
	}

	debug_msg "compr_util_path: '${compr_util_path}', compr_ext: '${compr_ext}'"

	read_blockset_metadata "${META_FILE:?}" "${SET_IDS}"

	export -n GLOBAL_ENV_SET=1
	[ "${CUR_ACT}" = start ] && export -n SKIP_SET_ENV=1

	debug_msg "" "End ${me}()"

	:
}

# Blockset run states:
# 0 - running
# 1 - error
# 2 - transitional
# 3 - paused
# 4 - stopped
#
set_blocksets_env()
{
	local \
		me=set_blocksets_env \
		IFS="${DEFAULT_IFS}" \
		some_ok \
		valid_ids active_ids \
		set_id \
		compr_util_path compr_ext compr_cmd_to_file compr_cmd_stdout extr_cmd_stdout \
		rm_extra \
		cs_res \
		conf_dir conf_dirs all_conf_dirs cs_file \
		set_ids="${*:-"${SET_IDS}"}"

	debug_msg "" "${me} start, set_ids '${set_ids}'"

	[ -z "${set_ids}" ] && return 0

	get_valid_set_ids valid_ids "${set_ids}" "${me}" ||
		{
			[ -n "${ASSERT_NOEXIT}" ] || exit 1
			return 1
		}

	get_compr_util_spec compr_util_path compr_ext "${compression_util:?}" || return 1

	export -n PART_EXTR_OR_CAT_STDOUT="${CAT_CMD:?}"
	[ -n "${compr_ext}" ] &&
	{
		compr_cmd_to_file="${compr_util_path} -f"
		compr_cmd_stdout="${compr_util_path} -c"
		extr_cmd_stdout="${compr_util_path} -cd"
		PART_EXTR_OR_CAT_STDOUT="try_extract -stdout"
	}

	[ -n "${METADATA_BAD}" ] && [ "${CUR_ACT}" != status ] &&
	{
		COMMIT_META_LOCATIONS=RAM FORCE_STOP_ALL=1 do_stop
		[ -n "${SET_IDS}" ] && set_params "${SET_IDS}" "run_state="
		METADATA_BAD=
	}

	# Test adblocking: whether abl_test_domain is resolved, for all blocksets at once
	CA_NOERR=1 check_active_blocksets active_ids "${SET_IDS}" 0

	add2list all_conf_dirs "${R_CONF_DIRS} ${C_CONF_DIRS}"

	[ "${CUR_ACT}" != status ] && rm_extra=1

	for set_id in ${SET_IDS}
	do
		local "cs_res_${set_id}="
	done

	# Register existing conf-scripts and check for stray ones
	local cs_files cd_index=0 cs_fatal=
	for conf_dir in ${all_conf_dirs}
	do
		cd_index=$((cd_index+1))
		cs_files=
		for set_id in ${SET_IDS}
		do
			local "cs_found_${set_id}_${cd_index}="
		done
		find_files cs_files "${conf_dir}" "${CS_BASE_FNAME:?}" "*"
		IFS="${_NL_}"
		for cs_file in ${cs_files}
		do
			conf_dirs=
			IFS="${DEFAULT_IFS}"
			split_path _ _ set_id "${cs_file}"
			if [ -n "${set_id}" ] && is_included "${set_id}" "${SET_IDS}"
			then
				get_params "${set_id}" conf_dirs
			else
				set_id=
			fi
			[ -n "${conf_dirs}" ] &&
			is_included "${conf_dir}" "${conf_dirs}" &&
				{ export -n "cs_found_${set_id}_${cd_index}=1"; continue; }

			reg_fail "Found conf-script '${cs_file}' in ${conf_dir} where it doesn't belong. This may cause dnsmasq to crash loop or to load the wrong blockset."
			[ -n "${set_id}" ] && export -n "cs_res_${set_id}=2"
			[ "${CUR_ACT}" = status ] || { rm -f "${cs_file}"; cs_fatal=1; }
		done
		IFS="${DEFAULT_IFS}"
	done
	[ -n "${cs_fatal}" ] && { export -n FAIL_STOP_REQ=1; exit 1; }

	for set_id in ${SET_IDS}
	do
		local \
			run_state='' \
			sbe_state='' \
			sbe_path='' \
			bl_check_res='' \
			bl_in_conf_dir='' \
			cur_persist_path='' \
			bl_1_inst='' \
			cd_state='' \
			bl_file_exists=0 \
			dns_check_res=0 \
			path_1 path_2 s_i_cnt=0 \
			cur_path='' \
			cur_1_instance='' \
			cur_md5='' \
			persist_mode='' \
			persist_dir='' \
			set_base_fname="${BLOCKSET_BASE_FNAME:?}-${set_id}"

		debug_msg -bf "${set_id}" "Checking state of{}."

		assert_set "F_${me}" GLOBAL_ENV_SET || return 1

		get_params "${set_id}" run_state cur_path cur_1_instance cur_md5 conf_dirs persist_mode persist_dir
		eval "cs_res=\"\${cs_res_${set_id}}\""

		# Check persistent files
		case "${persist_mode}" in manual|managed)
			if check_persist_dir "${set_id}"
			then
				FF_RM_EXTRA="${rm_extra}" find_files cur_persist_path "${persist_dir}" "${set_base_fname}." "*" "" "${set_id}" ||
				FF_RM_EXTRA="${rm_extra}" find_files cur_persist_path "${persist_dir}" "${set_base_fname}"  ""  "" "${set_id}"
				set_params "${set_id}" cur_persist_path
			else
				log_msg -warn -fb "${set_id}" "" "Persistent blockset file can not be used or updated{}."
			fi
		esac

		# Avoid permanently changing empty (unknown) cur_1_instance param value to unobserved "0"
		bl_1_inst="${cur_1_instance:-0}"

		debug_msg "${me}: bl_1_inst=${bl_1_inst};cur_md5=${cur_md5}"

		is_included "${set_id}" "${active_ids}" && dns_check_res=1

		[ -n "${cur_path}" ] && [ -f "${cur_path}" ] || cur_path=

		# conf-scripts codes:
		# 0: all conf-scripts not found
		# 1: all conf-scripts found
		# 2: inconsistent state
		cd_index=0
		for conf_dir in ${all_conf_dirs}
		do
			cd_index=$((cd_index+1))
			is_included "${conf_dir}" "${conf_dirs}" || continue
			eval "[ -n \"\${cs_found_${set_id}_${cd_index}}\" ]" && cd_state=1 || cd_state=0
			[ -n "${cs_res}" ] || { cs_res="${cd_state}"; continue; }
			[ "${cs_res}" = "${cd_state}" ] || cs_res=2
		done
		: "${cs_res:=0}"

		[ -n "${cur_path}" ] ||
			# Look for blockset file in all conf-dirs
			{
				for conf_dir in ${all_conf_dirs}
				do
					FF_FIRST=1 find_files path_1 "${conf_dir}" "${BLOCKSET_BASE_FNAME:?}-${set_id}" && s_i_cnt=$((s_i_cnt+1)) && cur_path="${path_1}"
					FF_FIRST=1 find_files path_2 "${conf_dir}" "${BLOCKSET_BASE_FNAME}-${set_id}." "*" && s_i_cnt=$((s_i_cnt+1)) && cur_path="${path_2}"
					[ -n "${path_1}${path_2}" ] || continue
					bl_1_inst=1
					cur_1_instance=1
				done

				# blockset in conf-dir should only be found once, otherwise contradicts single-instance
				[ "${s_i_cnt}" -gt 1 ] &&
				{
					reg_fail -fb "${set_id}" "Found ${s_i_cnt} blockset files{} in dnsmasq conf-dirs, expected to find one."
					sbe_state=1
				}
			}

		sbe_path=${cur_path}

		# Check persist blockset
		[ -z "${sbe_path}" ] && [ -n "${cur_persist_path}" ] &&
			sbe_path="${cur_persist_path}"

		[ -n "${sbe_path}" ] &&
		{
			bl_file_exists=1
			[ -z "${bl_in_conf_dir}" ] &&
			for conf_dir in ${all_conf_dirs}
			do
				case "${sbe_path}" in
					"${conf_dir}/"*) bl_in_conf_dir=1; break
				esac
			done
		}

		# Summarize
		bl_check_res="${dns_check_res}${bl_file_exists}${cs_res}${bl_1_inst}"

		# 0: running; 3: paused; 4: stopped
		[ "${sbe_state}" = 1 ] ||
		is_included "${run_state}" "1 2" ||
			case "${bl_check_res}" in
				1110|1101) sbe_state=0 ;; # running
				0100|0101)
					if [ -n "${bl_in_conf_dir}" ]
					then
						sbe_state=1
					elif [ -n "${sbe_path}" ] && [ "${sbe_path}" = "${cur_path}" ]
					then
						sbe_state=3 # paused
					else
						sbe_state=4 # stopped
					fi ;;
				0000|0001) sbe_state=4 ;; # stopped
				*) sbe_state=1 ;;
			esac

		case "${sbe_state}" in
			0|3|4) ;;
			*)
				[ "${run_state}" = 1 ] ||
					reg_fail "Unexpected state '${sbe_state}' for blockset '${set_id}' (path '${sbe_path}')." \
						"DNS:${dns_check_res};file_exists:${bl_file_exists};conf-scripts:${cs_res};single_inst:${bl_1_inst};"
		esac

		run_state="${sbe_state:-"${run_state}"}"

		debug_msg "${me}: set_id:${set_id}; run_state:${run_state}; check res:${bl_check_res};"

		set_params "${set_id}" run_state cur_path cur_1_instance
	done

	for set_id in ${valid_ids}
	do
		set_blockset_env "${set_id}" "${compr_ext}" "${extr_cmd_stdout}" "${compr_cmd_stdout}" "${compr_cmd_to_file}" ||
			{ reg_fail -fb "${set_id}" "Failed to load environment{}."; continue; }
		some_ok=1
	done

	debug_msg "${me} end, rv: $(( some_ok + 1 < 2))" ""

	[ -n "${some_ok}" ]
}


# Sets blockset-specific dnsmasq context
# Populates global vars for individual blockset IDs
# Env vars:
#   SBE_STATUS: do not exit on non-critical errors
set_blockset_env()
{
	rebuild_req_notice() { log_msg -warn "Please run 'service adblock-lean ${2} ${1}' to rebuild the ${3}${3:+ }blockset file."; }
	wont_work() {
		reg_fail -wb "${set_id}" "" "${1} can not be used{} because of missing addnmounts in /etc/config/dhcp: ${2}" \
			"Please run 'service adblock-lean create_addnmounts' to create required addnmount entries."
	}

	local set_id="${1:?}" compr_ext="${2}" extr_cmd_stdout="${3}" compr_cmd_stdout="${4}" compr_cmd_to_file="${5}"

	local me=set_blockset_env \
		IFS="${DEFAULT_IFS}" \
		\
		dmsq_instances \
		conf_dirs \
		\
		conf_script_log_avail \
		\
		first_conf_dir \
		\
		c_s_missing_addnm \
		compr_missing_addnm \
		m_i_missing_addnm \
		persist_missing_addnm \
		\
		set_base_fname \
		bl_full_fname_check \
		bl_full_fname \
		bl_path_persist \
		\
		pause_path \
		\
		install_path \
		install_path_ram \
		install_path_ram_check \
		install_1_instance \
		install_1_instance_ram \
		\
		persist_req=0 \
		persist_dir \
		persist_mode \
		\
		run_state \
		cur_path \
		\
		cur_persist_path \
		cur_persist_cnt \
		\
		final_compress \
		final_compr_ext \
		final_extr_or_cat_stdout="${CAT_CMD}" \
		final_compr_or_cat_stdout="${CAT_CMD}" \
		final_compr_to_file \
		\
		start_action=gen

	# Check addnmounts, possibility of final compression, multiple dnsmasq instances and persistent blockset creation,
	#   get final blockset paths,
	#   compression util path and extension

	debug_msg -fb "${set_id}" "Preparing blockset environment{}." "CUR_ACT: ${CUR_ACT}" "CUR_CMD: ${CUR_CMD}"

	get_params -f "${me}" "${set_id}" \
		dmsq_instances \
		conf_dirs \
		persist_mode || return 1

	get_params "${set_id}" persist_dir cur_persist_path run_state cur_path

	set_base_fname=${BLOCKSET_BASE_FNAME:?}-${set_id}

	# conf-script error logging
	check_addnmounts c_s_missing_addnm "${dmsq_instances}" "${LOG_CMD:?}" || return 1
	[ -z "${c_s_missing_addnm}" ] && conf_script_log_avail=1

	# Compression
	if [ -n "${compr_ext}" ]
	then
		assert_set "F_${me}" compr_cmd_to_file compr_cmd_stdout extr_cmd_stdout || return 1
		bl_full_fname_check=${set_base_fname:?}${compr_ext}
		install_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname_check}
		check_addnmounts compr_missing_addnm "${dmsq_instances}" "${extr_cmd_stdout%% *}${_NL_}${install_path_ram_check}" || return 1

		if [ -z "${compr_missing_addnm}" ]
		then
			bl_full_fname=${bl_full_fname_check}
			install_path_ram=${install_path_ram_check}

			install_1_instance_ram=0
			final_compress=1
			final_compr_ext=${compr_ext}
			final_compr_to_file=${compr_cmd_to_file}
			final_compr_or_cat_stdout=${compr_cmd_stdout}
			final_extr_or_cat_stdout=${extr_cmd_stdout}
		else
			wont_work "Final blockset compression" "${compr_missing_addnm}"
		fi
	fi

	# Final blockset full filename
	: "${bl_full_fname:="${set_base_fname:?}"}"

	# Multiple dnsmasq instances
	case "${dmsq_instances}" in
		*[a-zA-Z0-9_]*" "*[a-zA-Z0-9_]*)
			install_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname:?}
			check_addnmounts m_i_missing_addnm "${dmsq_instances}" "${install_path_ram_check}" || return 1
			if [ -z "${m_i_missing_addnm}" ]
			then
				install_path_ram=${install_path_ram_check}
				install_1_instance_ram=0
			else
				wont_work "adblock-lean" "${m_i_missing_addnm}"
				[ -n "${SBE_STATUS}" ] || return 1
			fi ;;
		*)
			first_conf_dir="${conf_dirs%% *}"
			is_valid_dir "${first_conf_dir}" || return 1

			[ "${final_compress}" = 1 ] ||
				{
					install_path_ram="${first_conf_dir}/${bl_full_fname}"
					install_1_instance_ram=1
				}
	esac

	# addnmount for blockset on ramdisk - required regardless of compr/persist/multi_inst availability
	[ -n "${install_path_ram}" ] || [ -n "${SBE_STATUS}" ] || { reg_fail "Internal error: install_path_ram is not set."; return 1; }

	case "${run_state}" in
		0|3|4) ;;
		*)
			case "${CUR_CMD}" in start|pause|resume)
				KEEP_PERSIST=1 stop_blocksets "${set_id}" || exit 1
				run_state=4 cur_path='' # param-store already updated by stop_blocksets
			esac
	esac

	# Persistent blockset
	local persist_ok=0 cat_addnm
	is_included "${persist_mode}" "manual managed" &&
	is_included "${CUR_CMD}" "start pause resume status gen_persist_blockset" &&
	check_persist_dir -q "${set_id}" &&
	{
		[ "${final_compress}" = 1 ] || cat_addnm="${_NL_}${CAT_CMD}"
		check_addnmounts persist_missing_addnm "${dmsq_instances}" "${persist_dir}${cat_addnm}" || return 1

		if [ -z "${persist_missing_addnm}" ]
		then
			check_persist_blockset "${set_id}" "${final_compr_ext}" &&
				persist_ok=1
			debug_msg "persist_ok: ${persist_ok}"

			get_params "${set_id}" cur_persist_cnt

			[ "${persist_ok}" = 1 ] ||
			{
				# Persistent blockset file not found or fails checks
				[ "${persist_mode}" = manual ] &&
					rebuild_req_notice "${set_id}" "gen_persist_blockset" "persistent"

				[ "${CUR_ACT}" != status ] &&
				{
					[ -n "${cur_persist_path}" ] &&
					{
						if [ "${cur_path}" = "${cur_persist_path}" ]
						then
							KEEP_PERSIST=0 stop_blocksets "${set_id}" || exit 1
							run_state=4 cur_path='' # param-store already updated by stop_blocksets
						elif is_dir_writable "${set_id}" "${cur_persist_path%/*}"
						then
							reg_msg -fb "${set_id}" "Removing disqualified persistent blockset file{}."
							rm -f "${cur_persist_path}" "${cur_persist_path%/*}/${META_BASE_FNAME_PERSIST:?}-${set_id}"
						fi
					}

					UNSET_PREFIX=PERSIST_ unset_metadata "${set_id}"
					cur_persist_path='' cur_persist_cnt=''
				}
			}

			persist_req=1
			[ "${persist_mode}" = managed ] &&
			{
				bl_path_persist="${persist_dir}/${bl_full_fname}"
				install_path="${bl_path_persist}"
				install_1_instance=0
			}
		else
			wont_work "Persistent blockset" "${persist_missing_addnm}"
		fi
	}

	debug_msg "persist_req: ${persist_req}"

	if [ "${persist_req}" = 1 ]
	then
		if \
			[ "${ABL_INIT_ACT}" = boot ] ||
			case "${CUR_ACT}" in
				status|pause) : ;;
				resume) [ "${run_state}" = 3 ] && is_persist "${cur_path}" "${set_id}" ;;
				*) false
			esac
		then
			if [ "${persist_ok}" = 1 ]
			then
				[ "${CUR_ACT}" = resume ] || [ "${ABL_INIT_ACT}" = boot ] &&
				{
					start_action=load
					install_path=${cur_persist_path}
					install_1_instance=0
					set_params "${set_id}" install_cnt="${cur_persist_cnt}"
				}
			else
				[ "${CUR_CMD}" = start ] &&
				{
					local start_act_msg="Will create a new blockset file on the ramdisk"
					[ "${persist_mode}" = managed ] &&
						start_act_msg="Will rebuild the persistent blockset file"
					log_msg -fb "${set_id}" "${start_act_msg}{}."
				}
			fi
		elif [ "${persist_mode}" = managed ] && [ "${CUR_CMD}" = start ]
		then
			reg_msg -fb "${set_id}" "Will update the persistent blockset file{}."
		fi
	fi

	: "${install_path:="${install_path_ram}"}"
	: "${install_1_instance:="${install_1_instance_ram}"}"

	case "${CUR_CMD}" in start|resume)
		[ -n "${FORCE_PERSIST_INSTALL}" ] && ! is_persist "${install_path}" "${set_id}" &&
			{ reg_fail -fb "${set_id}" "Can not generate persistent blockset file{}."; return 1; }
	esac

	pause_path="${install_path}"
	[ "${persist_mode}" = manual ] && [ -n "${cur_path}" ] && [ "${cur_path}" = "${cur_persist_path}" ] &&
		pause_path="${cur_persist_path}"
	[ "${install_path}" = "${install_path_ram}" ] && [ "${install_1_instance}" = 1 ] &&
		pause_path="${ABL_RUN_DIR}/${bl_full_fname}"

	[ -n "${install_path}" ] ||
		{ reg_fail -fb "${set_id}" "No usable path to install or load the blockset file{}."; rebuild_req_notice "${set_id}" "restart"; [ -n "${SBE_STATUS}" ] || return 1; }

	[ "${CUR_CMD}" = start ] &&
	case "${start_action}" in
		load) add2list BLOCKSETS_TO_INSTALL "${set_id}" ;;
		gen) add2list BLOCKSETS_TO_GEN "${set_id}" ;;
	esac

	set_params "${set_id}" \
		install_path \
		install_path_ram \
		install_1_instance \
		install_1_instance_ram \
		pause_path \
		bk_ext="${INTERM_COMPR_EXT}" \
		final_compress \
		final_compr_ext \
		final_extr_or_cat_stdout \
		final_compr_or_cat_stdout \
		final_compr_to_file \
		conf_script_log_avail

	: \
		"${pause_path}" \
		"${final_compr_to_file}" \
		"${final_compr_or_cat_stdout}" \
		"${conf_script_log_avail}"

	:
}

get_valid_set_ids()
{
	local gvi_id gvi_ok gvi_out_var="${1}" gvi_ids="${2}" gvi_caller="${3}"
	[ -n "${gvi_out_var}" ] || bad_args get_valid_set_ids "${@}"
	unset_vars "${gvi_out_var}"
	[ -n "${gvi_ids}" ] || return 0

	for gvi_id in ${gvi_ids}
	do
		is_known_set_id "${gvi_id}" || continue
		add2list "${gvi_out_var}" "${gvi_id}"
		gvi_ok=1
	done
	[ -n "${gvi_ok}" ] && return 0
	reg_msg -yellow "${gvi_caller:+"${gvi_caller}: "}No known blockset IDs specified."
	return 1
}

# Env vars: ACCEPT_UNKNOWN_SET_IDS
is_known_set_id()
{
	local akb_err
	{
		is_alphanum "${1}" ||
			{ akb_err="Invalid blockset ID '${1}'."; false; }
	} &&
	{
		[ -n "${ACCEPT_UNKNOWN_SET_IDS}" ] ||
		is_included "${1}" "${SET_IDS}" ||
			{ akb_err="Blockset '${1}' is not included in registered blockset IDs '${SET_IDS// /\', \'}'."; false; }
	} ||
		{ reg_fail "${2:+"${2}: "}${akb_err}"; return 1; }
	:
}

# Env vars: GBP_PREFIX
get_bl_param_gl_var()
{
	local _gl_var
	eval "
		case \"${2:?}\" in
			${BL_PARAMS_CLAUSES:?}
			*) return 1 ;;
		esac
	"

	export -n "${1:?}=${GBP_PREFIX}${_gl_var}"
}

# 0 (optional): '-f <func_name>' to error out if value is not set
# 1: blockset ID
# other args: params/output var names OR <var_name>=<param> ...
get_params()
{
	dbg_off
	local me=get_params \
		gl_var val force_err err_func err_func_pr var_exp var_name bl_param

	[ "${1}" = '-f' ] && { force_err=1 err_func="${2}" err_func_pr="-f ${2} "; shift 2; }
	local set_id="${1:?}"
	shift

	for var_exp in "${@}"
	do
		unset_vars "${var_exp%=*}"
	done

	is_known_set_id "${set_id}" "${me}${err_func:+": ${err_func}():"}" || exit 1

	for var_exp in "${@}"
	do
		bl_param="${var_exp#*=}"
		var_name="${var_exp%=*}"
		get_bl_param_gl_var gl_var "${bl_param}" ||
			bad_args "${me}" "${err_func_pr}${set_id} ${*}"

		eval "val=\"\${${gl_var}_${set_id}}\""
		[ -n "${val}" ] || [ -z "${force_err}" ] &&
			{ export -n "${var_name}=${val}"; continue; }

		reg_fail "${err_func}: Value not set for \${${gl_var}_${set_id}}."
		dbg_on
		return 1
	done
	:
	dbg_on
}

# 1: blockset IDs
# other args: any number of: 'param' to use current value, or 'param=value'
set_params()
{
	dbg_off
	local me=set_params \
		gl_var val param pair \
		set_id \
		set_ids="${1:?}"
	shift

	for set_id in ${set_ids}
	do
		is_known_set_id "${set_id}" "${me}" || exit 1

		for pair in "${@}"
		do
			case "${pair}" in
				*=*)
					param="${pair%%=*}"
					val="${pair#*=}"
					check_var_names "${param}" ;;
				*)
					param="${pair}"
					check_var_names "${param}"
					eval "val=\"\${${param}}\"" ;;
			esac &&
			get_bl_param_gl_var gl_var "${param}" || bad_args "${me}" "${set_id} ${*}"
			debug_msg "${blue}set_params${n_c}: ${gl_var}_${set_id}=${val}"
			export -n "${gl_var}_${set_id}=${val}"
		done
	done
	dbg_on
	:
}

inst_failed()
{
	local fail_report_ids fail_ids="${1}"

	subtract_a_from_b "${inst_fail_reported_ids}" "${fail_ids}" fail_report_ids
	[ -n "${fail_report_ids}" ] &&
	{
		set_params "${fail_report_ids}" run_state=1
		local set_pr=blockset
		case "${fail_report_ids}" in *" "*) set_pr=blocksets; esac
		reg_fail "Failed to install ${set_pr}: ${fail_ids}"
		add2list inst_fail_reported_ids "${fail_report_ids}"
	}
	KEEP_BK=1 stop_blocksets "${fail_ids}" || exit 1
}

install_blocksets()
{
	local set_id inst_ok_ids inst_fail_ids INST_PERM_FAIL_IDS inst_rv \
		inst_fail_reported_ids \
		install_path install_path_ram install_1_instance_ram persist_mode \
		ok_ids_out_var="${1:-_}" perm_fail_ids_out_var="${2:-_}" set_ids="${3:?}"

	unset_vars "${ok_ids_out_var}" "${perm_fail_ids_out_var}"

	try_install_blocksets inst_ok_ids "${set_ids}"
	inst_rv=${?}

	export -n "${ok_ids_out_var}=${inst_ok_ids}"
	subtract_a_from_b "${inst_ok_ids}" "${set_ids}" inst_fail_ids
	[ -n "${inst_fail_ids}" ] && inst_failed "${inst_fail_ids}"
	[ "${inst_rv}" = 1 ] && add2list INST_PERM_FAIL_IDS "${inst_fail_ids}"
	export -n "${perm_fail_ids_out_var}=${INST_PERM_FAIL_IDS}"

	for set_id in ${inst_fail_ids}
	do
		get_params "${set_id}" install_path install_path_ram install_1_instance_ram persist_mode

		[ "${CUR_CMD}" = start ] &&
		[ "${persist_mode}" = manual ] && is_persist "${install_path}" "${set_id}" || continue

		# fall back to RAM
		if [ -d "${install_path_ram%/*}" ]
		then
			set_params "${set_id}" install_path="${install_path_ram}" install_1_instance="${install_1_instance_ram}"
		else
			add2list INST_PERM_FAIL_IDS "${set_id}"
		fi
	done

	[ -n "${inst_ok_ids}" ]
}

try_install_blocksets()
{
	local \
		me=install_blocksets \
		\
		installed_ids \
		dmsq_ok_ids \
		dmsq_fail_ids \
		active_ids checked_ok_ids extra_ids \
		test_domains td_doms td_recs td_passed_ids \
		\
		dmsq_stop_ids \
		\
		run_state \
		dmsq_instances \
		persist_mode \
		skip_load_stop \
		\
		cur_path \
		cur_md5 \
		\
		install_path \
		install_path_ram \
		install_cnt \
		install_1_instance \
		\
		final_extr_or_cat_stdout \
		conf_dir conf_dirs \
		conf_script_log_avail \
		\
		set_id \
		\
		try_inst_ok_ids_out_var="${1:?}" set_ids="${2:?}"

	unset_vars "${try_inst_ok_ids_out_var}"

	for set_id in ${set_ids}
	do
		get_params "${set_id}" skip_load_stop
		[ -n "${skip_load_stop}" ] || add2list dmsq_stop_ids "${set_id}"
	done

	[ -z "${dmsq_stop_ids}" ] || stop_dnsmasq "${dmsq_stop_ids}" || return 1

	printf '\n' > "${MSGS_DEST}"

	for set_id in ${set_ids}
	do
		get_params -f "${me}" "${set_id}" dmsq_instances conf_dirs final_extr_or_cat_stdout install_path install_cnt || { inst_failed "${set_id}"; continue; }
		get_params "${set_id}" install_1_instance conf_script_log_avail

		log_msg -bf "${set_id}" "Installing{} at ${blue}${install_path}${n_c}"

		get_md5 cur_md5 "${install_path}" || { inst_failed "${set_id}"; continue; }

		[ "${install_1_instance}" = 1 ] ||
		# Make conf-script
		for conf_dir in ${conf_dirs}
		do
			is_valid_dir "${conf_dir}" || { inst_failed "${set_id}"; continue 2; }

			cat <<-EOF | ${SED_CMD} -E 's/\t+//g' > "${conf_dir}/${CS_BASE_FNAME}.${set_id}" || { reg_fail "Failed to create conf-script in directory '${conf_dir}'."; return 1; }
				conf-script="\
				${final_extr_or_cat_stdout} \"${install_path}\" && \
				printf '%s\\n' \"address=/${cur_md5}-${ABL_TEST_DOM_BASE}/#\" && \
				exit 0; \
				${conf_script_log_avail:+"${LOG_CMD} -t adblock-lean-conf-script -p user.err \\\"conf-script at '${conf_dir}/${CS_BASE_FNAME}.${set_id}' failed.\\\";"} \
				exit 0"
			EOF
		done

		set_params "${set_id}" \
			cur_md5 \
			cur_path="${install_path}" \
			cur_1_instance="${install_1_instance}" \
			cur_cnt="${install_cnt}"

		add2list installed_ids "${set_id}"
	done

	[ -n "${installed_ids}" ] && restart_dnsmasq 2 dmsq_ok_ids "${installed_ids}"
	subtract_a_from_b "${dmsq_ok_ids}" "${installed_ids}" dmsq_fail_ids
	[ -n "${dmsq_fail_ids}" ] && inst_failed "${dmsq_fail_ids}"
	[ -n "${dmsq_ok_ids}" ] || return 1

	# Test all blocksets related to restarted dnsmasq instances
	get_affected_set_ids extra_ids "${dmsq_ok_ids}"
	check_active_blocksets active_ids "${dmsq_ok_ids} ${extra_ids}" 25 || return 1
	subtract_a_from_b "${extra_ids}" "${active_ids}" active_ids

	# Only worth testing DNS resolution where adblocking works, so passing this check implies both
	for set_id in ${active_ids}
	do
		get_params "${set_id}" test_domains
		# a blockset with no valid test domains configured has nothing which could fail
		validate_doms td_doms "${test_domains}" &&
			abl_append td_recs "${set_id}=${td_doms}" "${_NL_}" ||
			add2list checked_ok_ids "${set_id}"
	done

	[ -n "${td_recs}" ] &&
	{
		reg_action -purple "Testing DNS resolution." || return 1
		lookup_test_doms td_passed_ids 5 "${td_recs}" || return 1
		add2list checked_ok_ids "${td_passed_ids}"
	}

	for set_id in ${dmsq_ok_ids}
	do
		if ! is_included "${set_id}" "${checked_ok_ids}"
		then
			reg_fail -fb "${set_id}" "Active blockset check failed{}."
			inst_failed "${set_id}"
			continue
		fi

		rm_bk "${set_id}"

		set_params "${set_id}" run_state=0

		add2list "${try_inst_ok_ids_out_var}" "${set_id}"
	done

	:
}

# Builds a dom name list for lookup_targets records
# Returns 1 if no valid dom name found
# 1: out-var for the space-separated list
# 2: domain names
validate_doms()
{
	local dom invalid_doms \
		vd_doms_var="${1:?}" vd_doms="${2}"

	unset_vars "${vd_doms_var}"

	for dom in ${vd_doms}
	do
		case "${dom}" in
			*[!A-Za-z0-9._-]*) abl_append invalid_doms "'${dom}'" ", "; continue
		esac
		abl_append "${vd_doms_var}" "${dom}"
	done

	[ -n "${invalid_doms}" ] && reg_fail "Ignoring invalid domain name(s): ${invalid_doms}"
	eval "[ -n \"\${${vd_doms_var}}\" ]"
}

# Checks whether adblocking is active for each blockset
#
# Env vars:
#   CA_NOERR: do not print error for test domain lookup failing
#
# 1: out-var for active blockset IDs
# 2: input blockset IDs
# 3 (optional): lookup timeout in seconds
#
# return values:
# 0: All blocksets tested OK
# 1: Some blockset tests failed
check_active_blocksets()
{
	local set_id md5 single_inst doms recs \
		ab_active_out_var="${1:?}"

	shift

	local ab_set_ids="${1:?}" timeout_s="${2}"

	unset_vars "${ab_active_out_var}"

	check_dmsq_instances || return 1

	for set_id in ${ab_set_ids}
	do
		get_params "${set_id}" md5=cur_md5 single_inst=cur_1_instance

		# In single-instance mode the test domain is identified by blockset ID, otherwise by checksum.
		# With no record of how the blockset was installed, try both
		case "${single_inst}" in
			1) doms="${set_id}-${ABL_TEST_DOM_BASE:?}" ;;
			'') doms="${set_id}-${ABL_TEST_DOM_BASE:?}${md5:+" ${md5}-${ABL_TEST_DOM_BASE}"}" ;;
			*) [ -n "${md5}" ] || continue
				doms="${md5}-${ABL_TEST_DOM_BASE:?}"
		esac

		abl_append recs "${set_id}=${doms}" "${_NL_}"
	done

	[ -n "${recs}" ] || return 0

	debug_msg "recs='${recs}'"

	reg_action -purple "Checking if adblocking is active." || return 1
	LOOKUP_NOERR="${CA_NOERR}" \
		lookup_test_doms "${ab_active_out_var}" "${timeout_s:-0}" "${recs}"
}

# Looks up test domains for multiple blocksets, in one go across all associated dnsmasq instances
# A blockset passes when, on every instance it uses, at least one of its domains resolved.
#
# Env vars:
#   LOOKUP_NOERR: do not report the blocksets which failed
#
# 1: var name for output of IDs of blocksets which passed
# 2: lookup timeout in seconds
# 3: newline-separated records: '<blockset ID>=<domain>...'
#
# return values:
# 0: Every blockset was checked
# 1: Lookups could not be performed
lookup_test_doms()
{
	local me=lookup_test_doms \
		IFS="${_NL_}" \
		set_id lt_checked_ids resolved_ids \
		rec lu_recs \
		instance instances set_insts failed_insts \
		dom doms set_doms ns_ips \
		hit ok cnt fail_report \
		lt_out_var="${1:?}" timeout_s="${2:-0}" recs="${3:?}"

	unset_vars "${lt_out_var}"

	for rec in ${recs}
	do
		IFS="${DEFAULT_IFS}"
		case "${rec}" in *=?*) ;; *) continue; esac # record without domains
		set_id="${rec%%=*}" doms="${rec#*=}"

		get_params "${set_id}" instances=dmsq_instances
		[ -n "${instances}" ] || continue

		local \
			"doms_${set_id}=${doms}" \
			"insts_${set_id}=${instances}"

		check_var_names ${instances}
		for instance in ${instances}
		do
			eval "ns_ips=\"\${NS_${instance}}\""
			: "${ns_ips:="127.0.0.1 ::1"}"

			debug_msg "Testing blockset '${set_id}' on dnsmasq instance '${instance}'." \
				"Nameservers: ${blue}${ns_ips// /"${n_c}, ${blue}"}${n_c}" \
				"Domains: ${doms}"

			# blocksets with identical contents share a domain, so the same target ID can be built twice.
			# lookup_targets keeps the first occurrence
			for dom in ${doms}
			do
				abl_append lu_recs "${instance}__${dom} ${dom} ${ns_ips}" "${_NL_}"
			done
		done

		add2list lt_checked_ids "${set_id}"
	done

	[ -n "${lt_checked_ids}" ] || return 0

	# Target IDs name their instance, so every instance shares one run, one job pool and one result list.
	LOOKUP_NOERR=1 lookup_targets resolved_ids "${lu_recs}" "${timeout_s}"
	case ${?} in 0|2) ;; *)
		reg_fail "${me}: failed to look up domains."
		[ -n "${ASSERT_NOEXIT}" ] || exit 1 # exit on internal scheduler errors
		return 1
	esac

	for set_id in ${lt_checked_ids}
	do
		eval "set_insts=\"\${insts_${set_id}}\" set_doms=\"\${doms_${set_id}}\""
		ok=0 cnt=0 failed_insts=
		for instance in ${set_insts}
		do
			cnt=$((cnt+1))
			# for each blockset, require at least one domain resolving
			hit=
			for dom in ${set_doms}
			do
				is_included "${instance}__${dom}" "${resolved_ids}" && { hit=1; break; }
			done
			[ -n "${hit}" ] && { ok=$((ok+1)); continue; }
			add2list failed_insts "${instance}"
		done

		[ "${ok}" = "${cnt}" ] &&
			{ add2list "${lt_out_var}" "${set_id}"; continue; }
		abl_append fail_report \
			"blockset '${set_id}' on dnsmasq instance(s): ${failed_insts}" "${_NL_}"
	done

	[ -n "${fail_report}" ] && [ -z "${LOOKUP_NOERR}" ] &&
		reg_fail "No domain resolved:${_NL_}${fail_report}"

	:
}

# Succeeds when every target resolved
#
# A target is a (domain, nameserver set) pair under a caller-chosen ID. It resolves as
# soon as any one of its own nameservers answers, so the same domain can be tested
# against several nameserver sets independently by giving each pair its own ID.
# A repeated target ID is ignored after its first occurrence.
#
# 1: (optional) var name for output of the IDs of the targets which resolved
# 2: newline-separated records: '<target ID> <domain> <nameserver>...'
#    Vet config-sourced domain names with validate_doms first
# 3: timeout (seconds)
#
# Env vars:
#   LOOKUP_NOERR: do not print a message when the condition is not satisfied
#   LOOKUP_FAIL_EARLY: stop as soon as the condition can no longer be satisfied. Leaves the
#     remaining targets untested, so don't set it when the per-target results are needed.
# shellcheck disable=SC2329
lookup_targets()
{
	lookup_dom_cb()
	{
		local port
		case "${ns}" in
			*"#"*)
				port="${ns##*"#"}"
				ns="${ns%"#${port}"}"
		esac
		${NSLOOKUP_CMD:?} -port="${port:-53}" "${dom:?}" "${ns:?}" 1>/dev/null 2>/dev/null
	}

	lookup_done_cb()
	{
		if [ "${2}" = 0 ]
		then
			ASSERT_NOEXIT=1 assert_set "F_lookup_done_cb" dom job_tgt_index || return 1
			# target may resolve on multiple nameservers - only count it once
			test_exp "resolved_${job_tgt_index} == 0" &&
				resolved_cnt=$((resolved_cnt+1))
			set_int "resolved_${job_tgt_index}=1"
			add2list RESOLVED_IDXS "${job_tgt_index}"
			# rv 80 = terminate on early success
			[ "${resolved_cnt}" = "${tgt_cnt}" ] && return 80
			return 0
		fi

		# target only counts as failed once every one of its nameservers failed
		set_int "failed_ns_${job_tgt_index} = failed_ns_${job_tgt_index} + 1"
		# this target can no longer resolve, so neither can all of them
		test_exp "failed_ns_${job_tgt_index} >= tgt_ns_cnt_${job_tgt_index}" &&
			[ -n "${LOOKUP_FAIL_EARLY}" ] && [ -n "${is_last_round}" ] &&
				return 2
		:
	}

	finalize_lookups_cb()
	{
		[ -n "${RESOLVED_IDXS}" ] && printf '%s\n' "${RESOLVED_IDXS}" > "${RESOLVED_IDXS_FILE}"
		[ "${1}" = 80 ] && return 0 # code 80 means early success
		[ "${resolved_cnt}" = "${tgt_cnt}" ] && return 0
		return 2
	}

	local \
		me=lookup_targets \
		IFS="${_NL_}" \
		lookup_max_jobs=24 \
		SCHED_ID=lookup \
		rec fld fld_index \
		tgt_id tgt_ids tgt_ns tgt_ns_cnt tgt_cnt=0 tgt_index \
		dom all_doms unresolved_doms \
		resolved_idxs resolved_cnt=0 \
		job_tgt_index \
		ns all_ns \
		id ids job_cnt=0 \
		lookup_rv \
		RESOLVED_IDXS \
		RESOLVED_IDXS_FILE="${ABL_TMP_DIR}/resolved-tgts" \
		is_last_round \
		sched_timeout_s \
		lookup_start_cs lookup_elapsed_cs \
			resolved_out_var="${1}" recs_in="${2}" lookup_timeout_s="${3:-0}"

	[ -n "${resolved_out_var}" ] && unset_vars "${resolved_out_var}"

	[ -n "${recs_in}" ] || return 0

	# the record list is split before the first iteration, so IFS can be restored inside the loop
	for rec in ${recs_in}
	do
		IFS="${DEFAULT_IFS}"
		tgt_id='' dom='' tgt_ns='' fld_index=0
		for fld in ${rec}
		do
			fld_index=$((fld_index+1))
			case "${fld_index}" in
				1) tgt_id="${fld}" ;;
				2) dom="${fld}" ;;
				*) add2list tgt_ns "${fld}" # remove duplicates
			esac
		done
		[ -n "${tgt_id}" ] && [ -n "${dom}" ] && [ -n "${tgt_ns}" ] || bad_args "${me}" "${@}"

		case "${dom}" in
			*[!A-Za-z0-9._-]*)
				reg_fail "${me}: invalid domain name '${dom}'."
				return 1
		esac
		is_included "${tgt_id}" "${tgt_ids}" && continue

		cnt_lines tgt_ns_cnt "${tgt_ns//[ $'\t']/$'\n'}"
		tgt_cnt=$((tgt_cnt+1))
		job_cnt=$((job_cnt+tgt_ns_cnt))
		abl_append tgt_ids "${tgt_id}"
		add2list all_doms "${dom}"
		add2list all_ns "${tgt_ns}"
		local \
			"tgt_id_${tgt_cnt}=${tgt_id}" \
			"tgt_dom_${tgt_cnt}=${dom}" \
			"tgt_ns_${tgt_cnt}=${tgt_ns}" \
			"tgt_ns_cnt_${tgt_cnt}=${tgt_ns_cnt}" \
			"resolved_${tgt_cnt}=0" \
			"failed_ns_${tgt_cnt}=0"
	done

	[ "${tgt_cnt}" = 0 ] && bad_args "${me}" "${@}"

	sched_timeout_s=$(( 5 * (job_cnt/lookup_max_jobs + (job_cnt % lookup_max_jobs > 0) ) + 1 ))
	[ "${sched_timeout_s}" -gt 30 ] && sched_timeout_s=30

	get_uptime_cs lookup_start_cs

	while :
	do
		: > "${RESOLVED_IDXS_FILE}"

		# Only give up early on last attempt.
		# Otherwise let running lookups finish to try and exclude more targets from the next round.
		is_last_round=1
		[ "${lookup_timeout_s}" -gt 0 ] &&
		{
			get_elapsed_time_cs lookup_elapsed_cs "${lookup_start_cs}"
			[ $(( lookup_elapsed_cs + sched_timeout_s*100 < lookup_timeout_s*100 )) = 1 ] &&
				is_last_round=
		}

		ids=
		id=0
		tgt_index=0
		while [ "${tgt_index}" -lt "${tgt_cnt}" ]
		do
			tgt_index=$((tgt_index+1))
			test_exp "resolved_${tgt_index} == 1" && continue # Ignore targets resolved earlier
			set_int "failed_ns_${tgt_index} = 0"
			eval "dom=\"\${tgt_dom_${tgt_index}}\" tgt_ns=\"\${tgt_ns_${tgt_index}}\""
			for ns in ${tgt_ns}
			do
				id=$((id+1))
				jobs_init "${id}"
				abl_append ids "${id}"
				job_set_params "${id}" \
					"dom=${dom}" \
					"ns=${ns}" \
					"job_tgt_index=${tgt_index}"
			done
		done

		DO_JOB_CB=lookup_dom_cb \
		JOB_DONE_CB=lookup_done_cb \
		SCHED_FINALIZE_CB=finalize_lookups_cb \
		SCHED_FAIL_MSG_CB=reg_fail \
		SCHED_DIR="${ABL_TMP_DIR}" \
		SCHED_MAX_JOBS=${lookup_max_jobs} \
		SCHED_JOB_TIMEOUT_S=3 \
		SCHED_TIMEOUT_S=${sched_timeout_s} \
		SCHED_IDLE_TIMEOUT_S=4 \
			schedule_jobs "${ids}" &

		SCHEDULER_PID=${!}
		wait ${SCHEDULER_PID}
		lookup_rv=${?}
		SCHEDULER_PID=

		# Record this round's hits, so the next round can skip them.
		resolved_idxs=
		read_str_from_file -D "resolved domains" -q -v resolved_idxs -f "${RESOLVED_IDXS_FILE}" -F "" -a 1 -n 4096 || [ ${?} = 2 ] || return 1
		for tgt_index in ${resolved_idxs}
		do
			is_uint "${tgt_index}" && [ "${tgt_index}" -ge 1 ] && [ "${tgt_index}" -le "${tgt_cnt}" ] &&
				set_int "resolved_${tgt_index} = 1"
		done

		resolved_cnt=0
		tgt_index=0
		while [ "${tgt_index}" -lt "${tgt_cnt}" ]
		do
			tgt_index=$((tgt_index+1))
			test_exp "resolved_${tgt_index} == 1" &&
				resolved_cnt=$((resolved_cnt+1))
		done

		case "${lookup_rv}" in
			0) break ;;
			2) : ;;
			*) reg_fail "Scheduler failure when testing domains resolution."; return 1
		esac

		[ "${resolved_cnt}" = "${tgt_cnt}" ] && { lookup_rv=0; break; }

		[ "${lookup_timeout_s}" -gt 0 ] || break
		get_elapsed_time_cs lookup_elapsed_cs "${lookup_start_cs}"
		[ $(( lookup_elapsed_cs < lookup_timeout_s*100 )) = 1 ] || break

		sleep 1 &
		wait ${!}
	done


	rm -f "${RESOLVED_IDXS_FILE}"

	tgt_index=0
	while [ "${tgt_index}" -lt "${tgt_cnt}" ]
	do
		tgt_index=$((tgt_index+1))
		eval "tgt_id=\"\${tgt_id_${tgt_index}}\" dom=\"\${tgt_dom_${tgt_index}}\""

		if test_exp "resolved_${tgt_index} == 1"
		then
			[ -n "${resolved_out_var}" ] && add2list "${resolved_out_var}" "${tgt_id}"
		else
			add2list unresolved_doms "${dom}"
		fi
	done

	[ "${lookup_rv}" = 0 ] && return 0

	[ -z "${LOOKUP_NOERR}" ] &&
		reg_fail "Failed to satisfy domain resolution condition: ${all_doms}" \
			"Unresolved domains: ${unresolved_doms}" "Tried nameservers: ${all_ns}"

	return "${lookup_rv:-1}"
}

### METADATA

# Env vars: UNSET_PREFIX
# 1 (optional): blockset IDs
unset_metadata()
{
	local meta_param set_id \
		unset_dbg \
		set_ids="${*:-"${SET_IDS}"}"

	for set_id in ${set_ids}
	do
		for meta_param in ${META_PARAMS:?}
		do
			unset "${UNSET_PREFIX}${meta_param}_${set_id}"
			abl_append unset_dbg "unset ${UNSET_PREFIX}${meta_param}_${set_id}" "${_NL_}"
		done
	done
	[ -n "${unset_dbg}" ] && debug_msg "${_NL_}${unset_dbg}"
}

# Env vars: COMMIT_META_LOCATIONS
commit_metadata()
{
	try_commit_metadata && return 0
	reg_fail "Failed to create or update the metadata file (return code ${?})."
	return 1
}

try_commit_metadata()
{
	uci_tmp() { uci -c "${meta_file%/*}" "${@}"; }

	# shellcheck disable=SC2034
	local me=commit_metadata \
		IFS="${DEFAULT_IFS}" \
		GBP_PREFIX \
		param_set param_set_bl param param_val uci_fail \
		set_id \
		cur_path \
		meta_fname \
		meta_locations="${COMMIT_META_LOCATIONS:-"RAM PERSIST"}" \
		meta_file="${META_FILE}"

	debug_msg "Creating metadata, blocksets: '${SET_IDS}'."

	rm -f "${meta_file}"

	[ -n "${SET_IDS}" ] || return 0

	# Common metadata
	is_included RAM "${meta_locations}" &&
	{
		try_mkdir -p "${meta_file%/*}" &&
		touch "${meta_file}" || return 1

		for set_id in ${SET_IDS}
		do
			get_params "${set_id}" cur_path
			[ -n "${cur_path}" ] || continue

			uci_tmp set "${META_FNAME}.${set_id}=blockset_id" || { uci_fail=1; break; }
			for param in ${META_PARAMS}
			do
				eval "param_val=\"\${${param}_${set_id}}\""
				[ -n "${param_val}" ] || continue
				uci_tmp set "${META_FNAME}.${set_id}.${param}"="${param_val}" || { uci_fail=1; break 2; }
				param_set=1
			done
		done

		[ -n "${param_set}" ] &&
		[ -z "${uci_fail}" ] &&
		uci_tmp commit "${META_FNAME}" ||
		{
			uci_tmp revert "${META_FNAME}"
			rm -f "${meta_file}"
			[ -n "${uci_fail}" ] &&
				{ reg_fail "Failed to create/update the metadata file '${meta_file}'."; return 2; }
		}
	}

	is_included PERSIST "${meta_locations}" || return 0

	# Persist metadata
	for set_id in ${SET_IDS}
	do
		meta_fname="${META_BASE_FNAME_PERSIST}-${set_id}"
		local persist_dir
		get_params "${set_id}" persist_dir cur_path
		is_persist "${cur_path}" "${set_id}" || continue

		[ -d "${persist_dir}" ] || { reg_fail -fb "${set_id}" "Can not update persistent metadata file{} because directory '${persist_dir}' is not found."; continue; }

		uci_fail=
		meta_file="${persist_dir%/}/${meta_fname:?}"
		rm -f "${meta_file}"

		touch "${meta_file}" &&
		uci_tmp set "${meta_fname}.${set_id}=blockset_id" &&
		for param in ${META_PARAMS_PERSIST}
		do
			eval "param_val=\"\${${param}_${set_id}}\""
			[ -n "${param_val}" ] || continue
			uci_tmp set "${meta_fname}.${set_id}.${param}"="${param_val}" || { uci_fail=1; break; }
		done &&

		[ -z "${uci_fail}" ] &&
		uci_tmp commit "${meta_fname}" && [ -s "${meta_file}" ] ||
			{
				reg_fail -fb "${set_id}" "Failed to create/update persistent metadata file '${meta_file}'{}."
				uci_tmp revert "${meta_fname}"
				rm -f "${meta_file}"
			}
	done

	:
}

# Reads the metadata file and assigns global vars:
#   IS_PAUSED_${id}, [PERSIST_]PATH_${id}, [PERSIST_]MD5_${id}, [PERSIST_]CNT_${id}
#
# Values are only assigned for files which actually exist, and reflect last known state
#   (updated at the end of each run of start/stop/pause/resume)
#
# 0 (optional): '-persist'
# 1: path to the meta file
# 2 (optional): required blockset IDs (errors with other read ID's will be ignored)
# 3 (optional): known blockset path to validate vs metadata record (for persist blockset files)
read_blockset_metadata()
{
	local me=read_blockset_metadata \
		rbm_rv meta_type=RAM \
		ACCEPT_UNKNOWN_SET_IDS=1

	[ "${1}" = '-persist' ] && { meta_type=PERSIST; shift; }

	local meta_file="${1}" rbm_ids="${2:-"${SET_IDS}"}" known_path="${3}"

	debug_msg "${me} start (${meta_type}): ${rbm_ids}"

	try_read_blockset_metadata "${meta_file}" "${rbm_ids}" "${meta_type}" "${known_path}"
	rbm_rv=${?}
	debug_msg "${me} end (${meta_type}): ${rbm_ids}"
	[ "${rbm_rv}" = 0 ] || [ "${meta_type}" = PERSIST ] || set_params "${rbm_ids}" run_state=1
	return ${rbm_rv}
}

# shellcheck disable=SC2329
try_read_blockset_metadata()
{
	append_err() {
		[ -n "${1}" ] && abl_append rbm_errors "${1}" "${_NL_}"
		[ "${meta_type}" = RAM ] && is_included "${set_id}" "${req_ids}" &&
			set_params "${set_id}" run_state=1
	}

	populate_vars()
	{
		local \
			pv_param \
			meta_val \
			bl_md5 \
			missing_val \
			cur_path cur_cnt cur_md5 \
			set_id="${1}"
		local set_id_pr="blockset '${set_id}'"

		debug_msg "Processing ${meta_type} metadata for ${set_id_pr}."

		is_alphanum "${set_id}" ||
			{ abl_append rbm_errors "${sp_f_pr} contains invalid blockset ID '${1}'." "${_NL_}"; rbm_force_rv=1; return 1; }

		for pv_param in ${meta_params}
		do
			config_get meta_val "${set_id}" "${pv_param}" # accept empty values
			[ "${pv_param}" = PATH ] && [ -n "${known_path}" ] &&
			{
				some_seen=1
				[ "${known_path}" = "${meta_val}" ] || { append_err "Unexpected PATH '${meta_val}' in ${sp_f_pr} (expecting '${known_path}')."; return 1; }
			}
			[ -n "${meta_val}" ] || missing_val=1
			export -n "${rbm_prefix}${pv_param}_${set_id}=${meta_val}"
			debug_msg "${blue}set metadata${n_c}: ${rbm_prefix}${pv_param}_${set_id}=${meta_val}"
		done

		GBP_PREFIX="${rbm_prefix}" get_params "${set_id}" cur_cnt cur_md5 cur_path
		[ -n "${cur_path}" ] || return 0
		some_seen=1

		is_included "${set_id}" "${req_ids}" ||
		{
			log_msg -warn "${sp_f_pr} contains stale entry for non-existing ${set_id_pr}."
			add2list stale_ids "${set_id}"
			return 1
		}

		[ -n "${missing_val}" ] &&
			{ append_err "Missing info in ${sp_f_pr} for ${set_id_pr}."; return 1; }

		# check md5
		get_md5 bl_md5 "${cur_path}" ||
			{ append_err; return 1; }

		[ "${cur_md5}" = "${bl_md5}" ] ||
			{ append_err "MD5 sum not matching in ${sp_f_pr} for ${set_id_pr}, path '${cur_path}'. Metadata file has: '${cur_md5}', blockset file has: '${bl_md5}'."; return 1; }

		# set persist params
		[ "${meta_type}" = PERSIST ] &&
		{
			[ "${cur_path%/*}" = "${meta_file%/*}" ] ||
			{
				append_err "Persistent blockset dir not matching in ${sp_f_pr} for ${set_id_pr}. Metadata file has: '${cur_path%/*}', metadata is at: '${meta_file%/*}'."
				return 1
			}
			set_params "${set_id}" cur_persist_md5="${cur_md5}" cur_persist_cnt="${cur_cnt}"
		}

		is_included "${set_id}" "${req_ids}" && some_ok=1
		:
	}

	local IFS="${DEFAULT_IFS}" \
		rbm_prefix \
		some_seen some_ok \
		rbm_force_rv \
		rbm_err rbm_errors \
		set_id \
		stale_ids \
		req_ids \
		meta_params="${META_PARAMS}" \
			meta_file="${1}" meta_ids="${2}" meta_type="${3}" known_path="${4}"

	local sp_f_pr="metadata file '${meta_file}'"

	METADATA_BAD=
	[ -n "${SET_IDS}" ] || return 0

	[ -n "${meta_ids}" ] || { reg_fail "${me}: no blockset configs specified."; return 1; }

	[ -f "${meta_file}" ] ||
		{ debug_msg "${me}: can not find ${sp_f_pr}."; return 0; }

	case "${meta_type}" in
		PERSIST)
			meta_params="${META_PARAMS_PERSIST}"
			req_ids="${meta_ids}"
			rbm_prefix=PERSIST_ ;;
		RAM)
			req_ids="${SET_IDS}"
	esac

	# Reset global vars
	UNSET_PREFIX="${rbm_prefix}" unset_metadata "${req_ids}"

	dbg_off
	UCI_CONFIG_DIR="${meta_file%/*}" config_load_a "${meta_file##*/}" || { dbg_on; return 1; }
	dbg_on

	config_foreach populate_vars blockset_id

	IFS="${_NL_}"
	for rbm_err in ${rbm_errors}
	do
		IFS="${DEFAULT_IFS}"
		reg_fail "${me}: ${rbm_err}"
	done
	IFS="${DEFAULT_IFS}"

	[ -n "${stale_ids}" ] &&
	{
		rbm_force_rv=1
		UNSET_PREFIX="${rbm_prefix}" unset_metadata "${req_ids}"
		[ "${meta_type}" = RAM ] && METADATA_BAD=1
		[ "${CUR_ACT}" != status ] &&
		case "${meta_type}" in
			PERSIST)
				set +f
				for set_id in ${meta_ids}
				do
					rm_if_writable "${set_id}" "${meta_file}" "${meta_file%/*}/${BLOCKSET_BASE_FNAME:?}"*
				done
				set -f ;;
			*) rm -f "${meta_file}"
		esac
	}

	[ -n "${rbm_force_rv}" ] && return "${rbm_force_rv}"
	[ -z "${some_seen}" ] || [ -n "${some_ok}" ]
}

: