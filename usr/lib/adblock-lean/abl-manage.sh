#!/bin/sh
# shellcheck disable=SC3043,SC2016,SC3060,SC3040,SC3003,SC3020,SC3045
# shellcheck source=/dev/null

META_FNAME="blockset-metadata"
META_FNAME_PERSIST="persist_blockset-metadata"
META_FILE="${ABL_RUN_DIR}/${META_FNAME}"
META_PARAMS="PATH SINGLE_INSTANCE MD5 CNT"
META_PARAMS_PERSIST="PATH MD5 CNT"

IP_REGEX_4='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])'
IP_REGEX_6='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}'

VAR2CFG_MAP="$(
	# Format: <var>[=<cfg_opt>]
	printf '%s\n' "
		whitelist_mode
		raw_block_lists
		raw_allow_lists
		raw_ipv4_block_lists
		dnsmasq_block_lists
		dnsmasq_allow_lists
		dnsmasq_ipv4_block_lists
		hosts_block_lists
		local_allowlist_path
		local_blocklist_path
		persist_mode=persist_blockset_mode
		persist_dir=persist_blockset_dir
		test_domains
		min_good_entries
		max_blockset_file_size_KB
		custom_script
		dnsmasq_indexes
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
	curr_persist_path=PERSIST_PATH
	curr_persist_cnt=PERSIST_CNT
	curr_persist_md5=PERSIST_MD5
	curr_path=PATH
	curr_md5=MD5
	curr_cnt=CNT
	curr_single_instance=SINGLE_INSTANCE
	install_path=INSTALL_PATH
	install_md5=INSTALL_MD5
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
	part_extr_or_cat_stdout=PART_EXTR_OR_CAT_STDOUT
	conf_script_log_avail=CONF_SCRIPT_LOG_AVAIL
	use_allowlist=USE_ALLOWLIST
	use_ipv4_blocklist=USE_IPV4_BLOCKLIST
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
		*.*) reg_failure "Unexpected extension '${gcs_file##*.}' in file '${gcs_path}'."; return 1
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
			reg_failure "try_compress: ${tc_err}${tc_err:+ }Failed to compress '${tc_in_file}'."
			rm_if_writable "${tc_set_id}" "${tc_in_file}";
			return 1
		}

	[ -n "${out_file_var}" ] && export -n "${out_file_var}=${tc_in_file}${tc_ext}"

	:
}

# 0 (optional): '-stdout' (does not remove source file)
# 1: blockset ID
# 2: path to file to extract
try_extract()
{
	local stdout=
	[ "${1}" = '-stdout' ] && { stdout=1; shift; }

	local IFS="${DEFAULT_IFS}" cmd opts \
		file_opts \
		stdout_opts \
		te_dir te_fname te_ext \
		te_err \
		te_set_id="${1}" te_file="${2:?}"

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
		[ -n "${stdout}" ] || rm_if_writable "${te_set_id}" "${te_fname}"*
		reg_failure "try_extract: ${te_err}${te_err:+ }Failed to extract '${te_file}'."
		return 1
	}
}


### dnsmasq support implementation

# Env vars:
#   GDI_NOFORCE: skip re-processing instances if DNSMASQ_INST_SET is non-empty
# populates global vars:
#   ALL_CONF_DIRS, DNSMASQ_RUNNING_INDEXES, DNSMASQ_INSTANCES_CNT
#   DNSMASQ_INST_NAME_${index}, IFACES_${index}, CONF_DIRS_${index}, CONF_DIRS_CNT_${index}, RUNNING_${index}, ADDNMOUNTS_${index}
#   ADDNMOUNTS_SET, DNSMASQ_INST_SET
#   DHCP_LOADED
get_dnsmasq_instances() {
	# shellcheck disable=SC2317,SC2329
	add_conf_dir_and_addnmounts()
	{
		local confdir
		config_get confdir "${1}" confdir
		[ -n "${confdir}" ] && add2list ALL_CONF_DIRS "${confdir}" "${_NL_}"
		config_get "ADDNMOUNTS_${index}" "${1}" addnmount
		index=$((index+1))
	}

	[ -n "${GDI_NOFORCE}" ] && [ -n "${DNSMASQ_INST_SET}" ] && [ -n "${ADDNMOUNTS_SET}" ] &&
		is_uint "${DNSMASQ_INSTANCES_CNT}" && [ "${DNSMASQ_INSTANCES_CNT}" -gt 0 ] && return 0

	local me=get_dnsmasq_instances \
		nonempty instance instances running_instances index l1_conf_file l1_conf_files conf_dirs i s f dir

	unset DNSMASQ_RUNNING_INDEXES ALL_CONF_DIRS ADDNMOUNTS_SET DNSMASQ_INST_SET
	DNSMASQ_INSTANCES_CNT=0
	reg_action "" "Checking dnsmasq instances."

	dbg_off
	[ -n "${DHCP_LOADED}" ] ||
	{
		# gather conf dirs from /etc/config/dhcp
		{ check_func config_load 1>/dev/null || { [ -f /lib/functions.sh ] && . /lib/functions.sh; }; } &&
		config_load dhcp ||
			{ reg_failure "Failed to load /etc/config/dhcp"; return 1; }
		DHCP_LOADED=1
	}

	index=0
	config_foreach add_conf_dir_and_addnmounts dnsmasq
	export -n ADDNMOUNTS_SET=1

	# gather conf dirs from /tmp/
	for dir in /tmp/dnsmasq.d /tmp/dnsmasq.cfg*
	do
		case "${dir}" in ''|*".cfg*") continue; esac
		add2list ALL_CONF_DIRS "${dir}" "${_NL_}"
	done

	# gather info from '/etc/init.d/dnsmasq info'

	. /usr/share/libubox/jshn.sh &&
	json_load "$(/etc/init.d/dnsmasq info)" &&
	json_get_keys nonempty &&
	[ -n "${nonempty}" ] &&
	json_select dnsmasq &&
	json_select instances &&
	json_get_keys instances &&
	[ -n "${instances}" ] || { reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."; return 1; }

	index=0
	for instance in ${instances}
	do
		unset "DNSMASQ_INST_NAME_${index}" "RUNNING_${index}" "IFACES_${index}" "CONF_DIRS_${index}" "CONF_DIRS_CNT_${index}"

		case "${instance}" in
			*[!a-zA-Z0-9_]*) log_msg -warn "" "Detected dnsmasq instance with invalid name '${instance}'. Ignoring."; continue
		esac
		json_is_a "${instance}" object || continue # skip if $instance is not object
		json_select "${instance}" &&
		json_get_var "RUNNING_${index}" running &&
		json_is_a command array &&
		json_select command || { reg_failure "Failed to process info for dnsmasq instance '${instance}'."; return 1; }

		add2list running_instances "${instance}" "${_NL_}"
		add2list DNSMASQ_RUNNING_INDEXES "${index}"
		l1_conf_files=

		# look for '-C' in values, get next value which is instance's conf file
		i=0
		while json_is_a $((i+1)) string
		do
			i=$((i+1))
			json_get_var s ${i}
			[ "${s}" = '-C' ] || continue
			json_get_var l1_conf_file $((i+1)) || return 1
			add2list l1_conf_files "${l1_conf_file}" "${_NL_}"
		done
		json_select ..
		json_select ..

		IFS="${_NL_}"
		set -- ${l1_conf_files}
		IFS="${DEFAULT_IFS}"

		# get ifaces for instance
		ifaces="$( ${SED_CMD} -n '/^\s*interface=/{s/^.*=//;s/\s*$//;/^\s*$/d;p}' "${@}" | sort -u )"
		: "${ifaces:="$(fw4 zone lan)"}" # fall back to all LAN interfaces

		# get conf-dirs for instance
		conf_dirs="$(
			for f in "${@}"
			do
				$SED_CMD -n '/^\s*conf-dir=/{s/.*=//;/[^\s]/p;}' "${f}"
			done | $SORT_CMD -u
		)"

		IFS="${_NL_}"
		set -- ${conf_dirs}
		IFS="${DEFAULT_IFS}"
		for dir in "${@}"
		do
			add2list ALL_CONF_DIRS "${dir}" "${_NL_}"
		done

		export -n "DNSMASQ_INST_NAME_${index}=${instance}" \
			"CONF_DIRS_${index}=${conf_dirs}" \
			"IFACES_${index}=${ifaces}"
		cnt_lines "CONF_DIRS_CNT_${index}" "${conf_dirs}"
		index=$((index+1))
	done
	json_cleanup
	cnt_lines DNSMASQ_INSTANCES_CNT "${running_instances}"
	dbg_on

	export -n DNSMASQ_INST_SET=1

	:
}

# Checks that configured dnsmasq instances are running and verifies that their indexes and conf-dirs match the config
# 1 - (optional) '-q' to quiet
# return codes:
# 0 - configured dnsmasq instances running
# 1 - dnsmasq instance is not running or other error
# shellcheck disable=SC2120
check_dnsmasq_instances()
{
	please_run() { log_msg "Please run 'service adblock-lean select_dnsmasq_instances ${1}'."; }

	cdi_fail()
	{
		[ -n "${quiet}" ] && return 0
		reg_failure -fb "${2}" "${1}"
	}

	what_failed()
	{
		local set_id index dnsmasq_indexes cfg_opt _fail_ind _fail_sets
		unset_vars "${1}" "${2}"
		for set_id in ${SET_IDS}
		do
			get_params "${set_id}" dnsmasq_indexes
			[ -n "${dnsmasq_indexes}" ] ||
				{ get_cfg_opt cfg_opt "dnsmasq_indexes"; cdi_fail "'${cfg_opt}' config option is not set{}." "${set_id}"; please_run "${set_id}"; return 1; }

			for index in ${dnsmasq_indexes}
			do
				eval "[ \"\${RUNNING_${index}}\" = 1 ]" && continue
				add2list _fail_ind "${index}"
				add2list _fail_sets "${set_id}"
			done
		done
		[ -n "${_fail_ind}" ] &&
		cdi_fail "dnsmasq instances with indexes '${_fail_ind//" "/"', '"}' are not running."
		export -n "${1}=${_fail_ind}" "${2}=${_fail_sets}"
		:
	}


	local quiet instance index dir \
		set_id \
		instance_conf_dirs conf_dir_reg \
		conf_dirs \
		all_bl_conf_dirs \
		failed_indexes failed_set_ids \
		inst_ind="dnsmasq instance with index"

	[ "${1}" = '-q' ] && quiet=1

	[ -n "${DNSMASQ_INST_SET}" ] || get_dnsmasq_instances || return 1

	what_failed failed_indexes failed_set_ids || return 1
	[ -n "${failed_indexes}" ] &&
	{
		do_stop "${failed_set_ids}" &&
		get_dnsmasq_instances &&
		what_failed failed_indexes failed_set_ids || return 1
		[ -z "${failed_indexes}" ] ||
		{
			# TODO: make sure stop all is executed on failure
			cdi_fail "dnsmasq service is not working correctly."
			return 1
		}
	}

	for set_id in ${SET_IDS}
	do
		all_bl_conf_dirs=

		for index in ${dnsmasq_indexes}
		do
			eval "instance_conf_dirs=\"\${CONF_DIRS_${index}}\""
			[ -n "${instance_conf_dirs}" ] ||
				{ cdi_fail "Config directory is not set for dnsmasq instance with index ${index}."; return 1; }
			all_bl_conf_dirs="${all_bl_conf_dirs}${instance_conf_dirs}${_NL_}"

			conf_dir_reg=
			local IFS="${_NL_}"
			for dir in ${instance_conf_dirs}
			do
				IFS="${DEFAULT_IFS}"
				is_included "${dir}" "${conf_dirs}" && conf_dir_reg=1
				[ -d "${dir}" ] ||
				{
					cdi_fail "Conf-dir '${dir}' does not exist. ${inst_ind} ${index} is misconfigured."
					please_run "${set_id}"
					return 1
				}
			done
			IFS="${DEFAULT_IFS}"

			[ -n "${conf_dir_reg}" ] ||
			{
				cdi_fail "Conf-dirs for ${inst_ind} ${index} changed."
				please_run "${set_id}"
				return 1
			}

			# check if config section exists in /etc/config/dhcp
			uci show "dhcp.@dnsmasq[${index}]" &>/dev/null ||
			{
				cdi_fail "${inst_ind} ${index} is running but not registered in /etc/config/dhcp. Use the command 'service dnsmasq restart' and then re-try."
				return 1
			}
		done

		for dir in ${conf_dirs}
		do
			is_included "${dir}" "${all_bl_conf_dirs}" "${_NL_}" ||
			{
				cdi_fail "conf-dir directory '${dir}' is set in config{} but not used by configured dnsmasq instances '${dnsmasq_indexes}'." "${set_id}"
				return 1
			}
		done
	done

	:
}

# analyze dnsmasq instances and set $dnsmasq_conf_dirs
# 1 (optional): blockset ID's (defaults to all)
do_select_dnsmasq_instances() {
	validate_indexes() { printf '%s\n' "${1}" | grep -qE "^ *(a|${indexes_regex})( +(${indexes_regex}))*$"; }

	local me=select_dnsmasq_instances \
		conf_dirs conf_dirs_instance \
		conf_dirs_cnt \
		select_conf_dirs \
		select_skip_msg \
		select_indexes \
		instance index luci_indexes indexes_regex \
		ifaces \
		REPLY \
		first diff \
		add_dir \
		set_id set_ids \
		set_ids_arg="${1:-"${SET_IDS}"}"

	local CUR_CMD="${me}"

	assert_set "F_${me}" SET_IDS || return 1

	get_valid_set_ids set_ids "${set_ids_arg}" || return 1

	get_dnsmasq_instances && [ -n "${DNSMASQ_RUNNING_INDEXES}" ] ||
	{
		reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."
		do_stop
		get_dnsmasq_instances && [ -n "${DNSMASQ_RUNNING_INDEXES}" ] || return 1
	}

	for set_id in ${set_ids}
	do
		select_skip_msg="Detected only 1 dnsmasq instance"
		first=1 diff='' conf_dirs_cnt='' REPLY='' select_indexes='' indexes_regex='' conf_dirs=''
			ifaces='' select_ifaces=''
			select_conf_dirs=''
		if \
		{
			[ "${DNSMASQ_INSTANCES_CNT}" = 1 ] &&
				select_indexes="${DNSMASQ_RUNNING_INDEXES%% *}"
		} ||
		{
			# check if all instances share same conf-dirs
			for index in ${DNSMASQ_RUNNING_INDEXES}
			do
				eval "conf_dirs_instance=\"\${CONF_DIRS_${index}}\""
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
			done
			[ -z "${diff}" ] &&
			select_indexes="${DNSMASQ_RUNNING_INDEXES}" &&
			select_skip_msg="Detected multiple dnsmasq instances which are using the same conf-dirs: ${_NL_}${blue}${conf_dirs// /" ${_NL_}"}${n_c}"
		}
		then
			reg_msg "" "${select_skip_msg}" "Skipping manual dnsmasq instance selection."
		else
			# Ask the user
			reg_msg -blue "Multiple dnsmasq instances detected."
			eval "luci_indexes=\"\${luci_dnsmasq_indexes_${set_id}}\""
			REPLY=a
			if [ "${DO_DIALOGS}" = 1 ]
			then
				reg_msg "" "Existing dnsmasq instances and assigned network interfaces:"
				for index in ${DNSMASQ_RUNNING_INDEXES}
				do
					eval "instance=\"\${DNSMASQ_INST_NAME_${index}}\"" \
						"ifaces=\"\${IFACES_${index}}\""
					ifaces="${ifaces//"${_NL_}"/, }"
					reg_msg "${index}. Instance '${instance}': network interfaces '${ifaces}'"
					indexes_regex="${indexes_regex}${indexes_regex:+|}${index}"
				done
				print_msg -fb "${set_id}" "" "Please select which dnsmasq instance should have active adblocking{}, or 'a' to abort." \
					"To adblock on multiple instances, enter their indexes separated by whitespaces."
				while :
				do
					printf %s "${indexes_regex}|a: " > "${MSGS_DEST}"
					read -r REPLY
					validate_indexes "${REPLY}" ||
						{ printf '\n%s\n\n' "Please enter ${indexes_regex}|a" > "${MSGS_DEST}"; continue; }
					break
				done
			elif [ -n "${luci_indexes}" ]
			then
				REPLY="${luci_indexes}"
				validate_indexes "${REPLY}" ||
					{ reg_failure "Invalid dnsmasq instance indexes '${REPLY}'."; return 1; }
			else
				reg_failure -fb "${set_id}" "dnsmasq indexes not specified{}."
				return 1
			fi

			[ "${REPLY}" = a ] && { reg_msg "Aborted config generation."; exit 0; }
			select_indexes="${REPLY}"
		fi

		for index in ${select_indexes}
		do
			eval "ifaces=\"\${IFACES_${index}}\""
			add2list select_ifaces "${ifaces}"
		done

		log_msg -fb "${set_id}" "Selected dnsmasq indexes{}: '${select_indexes}' (network intefaces: ${select_ifaces//" "/, })."

		for index in ${select_indexes}
		do
			add_dir=
			eval "conf_dirs=\"\${CONF_DIRS_${index}}\"
				conf_dirs_cnt=\"\${CONF_DIRS_CNT_${index}}\""

			if [ "${conf_dirs_cnt}" = 1 ]
			then
				add_dir="${conf_dirs}"
			else
				if is_included "/tmp/dnsmasq.d" "${conf_dirs}" "${_NL_}"
				then
					add_dir="/tmp/dnsmasq.d"
				elif is_included "/tmp/dnsmasq.cfg01411c.d" "${conf_dirs}" "${_NL_}"
				then
					add_dir="/tmp/dnsmasq.cfg01411c.d"
				else
					# fall back to first conf-dir
					add_dir="${conf_dirs%%"${_NL_}"*}"
				fi
			fi
			[ -n "${add_dir}" ] && add2list select_conf_dirs "${add_dir}" "${_NL_}"
		done

		[ -n "${select_conf_dirs}" ] || { reg_failure "Failed to detect conf-dirs for dnsmasq indexes '${select_indexes}'."; return 1; }

		log_msg "Selected dnsmasq conf-dirs: '${select_conf_dirs//"${_NL_}"/"', '"/}'"
		set_params "${set_id}" dnsmasq_indexes="${select_indexes}" conf_dirs="${select_conf_dirs}"
	done

	:
}

# Get interfaces each dnsmasq instance is listening on and associated IP addresses
# Populates global vars: NS4_${dnsmasq_index}, NS6_${dnsmasq_index}
get_dnsmasq_ips()
{
	local me=get_dnsmasq_ips \
		IFS="${DEFAULT_IFS}" \
		odevs linux_ifaces dnp_res \
		set_ids="${*:-"${SET_IDS}"}"

	# get list of OpenWrt device names, store in $odevs
	# shellcheck disable=SC2329
	get_odevs_cb()
	{
		local dev section_id="$1"
		config_get dev "${section_id}" name
		odevs="${odevs}${odevs:+$'\n'}${dev}"
	}

	dbg_off
	config_load network &&
	config_foreach get_odevs_cb device &&

	# get list of all linux ifaces + IP addresses
	linux_ifaces="$(
		${IP_CMD} -o addr show |
		${SED_CMD} -nE "/^\s*[0-9]+:\s*/{s/^\s*[0-9]+\s*:\s+//;s/inet[6]*\s+//;s/\s(${IP_REGEX_4:?}|${IP_REGEX_6:?})(\/[0-9]+)\s.*/\1/;s/\s+/ /;s/\s+$//;p;}"
	)" &&

	dnp_res="$(
		${NETSTAT_CMD} -plnt 2>/dev/null |
		${AWK_CMD} -v regex_4="${IP_REGEX_4//\\./.}" -v regex_6="${IP_REGEX_6}" -v l_ifaces="${linux_ifaces}" -v odevs_str="${odevs}" '
			function print_id(id)
			{
				if (out_4[id]) {rv = 0; out_val_4 = out_4[id]} else out_val_4 = "NIL"
				if (out_6[id]) {rv = 0; out_val_6 = out_6[id]} else out_val_6 = "NIL"
				print id " " out_val_4 " " out_val_6
			}

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
				if (pid !~ /\/dnsmasq$/) next
				sub("/dnsmasq","",pid)
				if (! iface || ! pid) next

				id = pid " " iface

				if (iface in odevs) odevs_out[id]
				else out[id]

				if (ip ~ regex_4)
				{
					if (out_4[id] != "") {next}
					out_4[id] = ip
				}
				else if (ip ~ regex_6)
				{
					if (out_6[id] != "") {next}
					out_6[id] = ip
				}
				else next
			}

			END {
				for (id in odevs_out) print_id(id)
				for (id in out) print_id(id)
				exit rv
			}
		'
	)" &&
	[ -n "${dnp_res}" ] ||
		{ reg_failure "Failed to get network params for dnsmasq instances. Found Linux ifaces: '${linux_ifaces//"${_NL_}"/ }', OpenWrt devices: '${odevs}', "; return 1; }
	dbg_on

	# dnsmasq nameserver IP's
	local line index dnsmasq_indexes \
		all_dnsmasq_indexes \
		set_id \
		inst_name inst_pid inst_iface \
		inst_ip_4 inst_ip_6 ip4_present ip6_present

	for set_id in ${set_ids}
	do
		get_params -f "${me}" "${set_id}" dnsmasq_indexes || continue
		add2list all_dnsmasq_indexes "${dnsmasq_indexes}"
	done

	for index in ${all_dnsmasq_indexes}
	do
		# iface and nameservers
		inst_iface='' inst_ip_4='' inst_ip_6='' ip4_present='' ip6_present=''

		eval "inst_name=\"\${DNSMASQ_INST_NAME_${index}}\""
		inst_pid="$(${PGREP_CMD:?} -f '^/usr/sbin/dnsmasq.*'"${inst_name:-???}"'.pid$')" ||
			{ reg_failure "No PID found for dnsmasq instance with index '${index}' (name: '${inst_name}')."; return 1; }

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

		export -n \
			"NS4_${index}=${inst_ip_4}" \
			"NS6_${index}=${inst_ip_6}"
	done

	:
}


### GENERAL HELPER FUNCTIONS

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
				for (ind in ids_in) {if (ids_in[ind]) ids_arr[ids_in[ind]]}
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
		{ set_params "${mv_set_id}" curr_path="${mv_dst_f}"; return 0; }

	rm_if_writable "${mv_set_id}" "${mv_src_f}" "${mv_dst_f}"
	reg_failure "Failed to move blockset '${mv_set_id}' from '${mv_src_f}' to '${mv_dst_f}' (cmd: '${mv_compr_cmd}')."
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
	local transfer_cmd="try_mv -q" \
		md5_changed \
		curr_md5 \
		mv_src_d mv_src_ext \
		mv_dst_d mv_dst_ext \
		mv_src_f="${1}" mv_dst_f="${2}" mv_compr_cmd="${3}" mv_set_id="${4:?}"

	split_path mv_src_d _ mv_src_ext "${mv_src_f}" &&
	split_path mv_dst_d _ mv_dst_ext "${mv_dst_f}" || return 1

	is_valid_dir "${mv_src_d}" && is_valid_dir "${mv_dst_d}" || { reg_failure "${me}: unexpected src dir '${mv_src_d}' or dest dir '${mv_dst_d}'."; return 1; }

	[ -f "${mv_src_f}" ] || { reg_failure "${me}: file '${mv_src_f}' not found."; return 1; }

	[ "${mv_src_f}" = "${mv_dst_f}" ] && return 0

	is_dir_writable "${mv_set_id}" "${mv_dst_d}" || { reg_failure "${me}: logic bug: attempted write into protected dir '${mv_dst_d}'."; return 1; }

	is_dir_writable "${mv_set_id}" "${mv_src_d}" || transfer_cmd="cp"

	if [ -n "${mv_src_ext}" ] && [ "${mv_src_ext}" != "${mv_dst_ext}" ]
	then
		try_extract "${mv_set_id}" "${mv_src_f}" || return 1
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
		get_md5 curr_md5 "${mv_dst_f}" || return 1
		set_params "${mv_set_id}" curr_md5
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
	local mnt_point persist_dir \
		set_id="${1}"

	get_params "${set_id}" persist_dir

	[ -d "${persist_dir}" ] ||
	{
		case "${persist_dir}" in
			''|/) reg_failure "Empty or invalid persistent blockset directory '${persist_dir}' specified in config option persist_blockset_dir." ;;
			*) reg_failure "Can not find persistent blockset directory: ${persist_dir}"
		esac
		return 1
	}

	mnt_point="$(${DF_CMD} "${persist_dir}" |
		${AWK_CMD} '/^[ \t]*Filesystem[ \t]/{next} {i++; print $6} END{ if(i == 1) exit 0; exit 1}')" &&
	[ -d "${mnt_point}" ] ||
		{ reg_failure "Failed to get the mount point for partition where the persistent blockset is stored (got '${mnt_point}')."; return 1; }

	[ "${persist_dir}" != "${mnt_point}" ] ||
		{  reg_failure "Persistent directory '${persist_dir}' is the same as the mount point. Please use a subdirectory."; return 1; }

	:
}

check_persist_blockset()
{
	local max_blockset_file_size_KB min_good_entries min_good_entries_human \
		persist_check_rv \
		persist_ext persist_mode curr_persist_path curr_persist_cnt curr_persist_cnt_human curr_persist_size_b \
		run_state \
		curr_cnt \
		set_id="${1}" final_compr_ext="${2}"

	get_params -f "check_persist_blockset" "${set_id}" persist_mode min_good_entries max_blockset_file_size_KB run_state || return 1
	get_params "${set_id}" curr_persist_path
	debug_msg "Checking persistent blockset file: ${blue}${curr_persist_path}${n_c}"

	{
		[ -n "${curr_persist_path}" ] ||
			{
				[ "${run_state}" != 4 ] || [ "${persist_mode}" = manual ] &&
					reg_failure "Persistent blockset not found in directory '${persist_dir}'."
				false
			}
	} &&

	{
		get_compr_spec persist_ext _ "${curr_persist_path}" ||
			{ reg_failure "Can not find utility to extract persistent blockset file '${curr_persist_path}'."; false; }
	} &&

	{
		[ "${persist_ext}" = "${final_compr_ext}" ] ||
		{
			reg_failure "Extension '${persist_ext}' of persistent blockset file '${curr_persist_path}' does not match required extension '${final_compr_ext}'."
			persist_check_rv=1
		}
	} &&

	curr_persist_size_b="$(get_file_size "${curr_persist_path}")" &&
	{
		[ $(( curr_persist_size_b/1024 )) -le "${max_blockset_file_size_KB}" ] ||
		{ reg_failure "Persistent blockset file '${curr_persist_path}' is larger than the maximum value set in config (${max_blockset_file_size_KB} KiB)."; false; }
	} &&

	{
		read_blockset_metadata -persist "${curr_persist_path%/*}/${META_FNAME_PERSIST:?}" "${set_id}" &&
		get_params "${set_id}" curr_persist_cnt &&
		[ -n "${curr_persist_cnt}" ] ||
		{ reg_failure "Failed to process metadata for persistent blockset file '${curr_persist_path}'."; false; }
	} &&

	{
		[ "${curr_persist_cnt}" -ge "${min_good_entries}" ] ||
			{
				int2human curr_persist_cnt_human "${curr_persist_cnt}"
				int2human min_good_entries_human "${min_good_entries}" || return 1
				reg_failure "Entries count (${curr_persist_cnt_human}) in the persistent blockset file '${curr_persist_path}' is below the minimum value set in config (${min_good_entries_human})."
				false
			}
	} &&
	[ "${persist_check_rv}" != 1 ] &&
		return 0

	return 1
}

# Env vars:
#   CA_CHECK_DOMAINS: test DNS resolution
#   CA_NOERR: do not print error for test domain lookup failing
#
# return values:
# 0: All checks passed
# 1: General error
# 2: The blockset test domain failed to resolve (blockset not loaded)
# 3: One of the test domains failed to resolve
check_active_blockset()
{
	lookup_failed() { reg_failure "Lookup of test domain '${1}' failed (dnsmasq instance ${2}, IP addresses '${3}')."; }

	local me=check_active_blockset \
		test_domains \
		family index dnsmasq_indexes instance_ns def_ns ns_ips ca_ns_4 ca_ns_6 ns_ips_sp ca_test_dom ca_id \
		set_id="${1:?}" ca_md5="${2:?}" ca_single_instance="${3}"

	reg_action -fb "${set_id}" "Checking if adblocking is active{}." || return 1

	GDI_NOFORCE=1 get_dnsmasq_instances || return 1

	get_params -f "${me}" "${set_id}" dnsmasq_indexes || return 1
	get_params "${set_id}" test_domains

	if [ "${ca_single_instance}" = 1 ]
	then
		ca_id="${set_id}" # blockset ID is used in test domain for single instance
	else
		ca_id="${ca_md5}"
	fi
	ca_test_dom="${ca_id}-${ABL_TEST_DOM_BASE:?}"

	debug_msg "${me}: set_id:${set_id}; indexes:${dnsmasq_indexes}; id:${ca_id}; ca_single_instance:${ca_single_instance};"

	for index in ${dnsmasq_indexes}
	do
		ns_ips='' ns_ips_sp=''

		eval "ca_ns_4=\"\${NS4_${index}}\"" "ca_ns_6=\"\${NS6_${index}}\""
		debug_msg "${me}: ips:${ca_ns_4};${ca_ns_6};"

		for family in 4 6
		do
			case "${family}" in
				4) def_ns=127.0.0.1 ;;
				6) def_ns=::1
			esac
			eval "instance_ns=\"\${ca_ns_${family}:-${def_ns}}\""
			add2list ns_ips "${instance_ns}" "${_NL_}"
			add2list ns_ips_sp "${blue}${instance_ns}${n_c}" ", "
		done

		debug_msg "Testing dnsmasq instance ${index}." \
			"Using following nameservers for DNS resolution verification: ${ns_ips_sp}" \
			"Testing adblocking."

		try_lookup_domain "${ca_test_dom}" "${ns_ips}" 1 -n ||
			{
				[ -n "${CA_NOERR}" ] || lookup_failed "${ca_test_dom}" "${index}" "${ns_ips_sp}"
				return 2
			}

		[ -n "${CA_CHECK_DOMAINS}" ] &&
		{
			debug_msg "Testing DNS resolution."
			for domain in ${test_domains}
			do
				try_lookup_domain "${domain}" "${ns_ips}" 5 || { lookup_failed "${domain}"; return 3; }
			done
		}
	done

	:
}

# 1: var name for printable missing paths output
# 2: dnsmasq instance indexes to check
# 3: list of newline-separated paths
# shellcheck disable=SC2120
check_addnmounts()
{
	try_check_addnmounts "${@}" || { reg_failure "Failed to check addnmount entries."; return 1; }
}

try_check_addnmounts()
{
	local me=check_addnmounts \
		IFS="${DEFAULT_IFS}" \
		ca_index ca_path ca_addnmounts \
		ca_missing_var="${1}" ca_indexes="${2}" ca_req_addnm="${3}"

	unset_vars "${ca_missing_var}"
	assert_set "F_${me}" ca_indexes ADDNMOUNTS_SET || return 1

	[ -n "${ca_req_addnm}" ] || return 0

	for ca_index in ${ca_indexes}
	do
		is_uint "${ca_index}" || { reg_failure "${me}: Invalid dnsmasq index '${ca_index}'."; return 1; }
		IFS="${_NL_}"
		for ca_path in ${ca_req_addnm}
		do
			[ -n "${ca_path}" ] || continue
			IFS="${DEFAULT_IFS}"

			eval "ca_addnmounts=\"\${ADDNMOUNTS_${ca_index}}\""
			case "${ca_path}" in
				/*) ;;
				*) reg_failure "${me}: invalid path '${ca_path}'."; return 1
			esac

			ca_path_tmp="${ca_path}"
			i=1
			while [ -n "${ca_path_tmp}" ] && [ "${i}" -le 10 ]
			do
				i=$((i+1))
				is_included "${ca_path_tmp}" "${ca_addnmounts}" && continue 2
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
# Env vars:
#   SBE_STATUS: do not exit on non-critical errors
#
# 1 (optional): blockset IDs (defaults to all)
set_global_env()
{
	[ -n "${SKIP_SET_ENV}" ] && return 0

	local \
		compr_util_path \
		compr_ext \
		cpu_cnt

	export -n \
		PARALLEL_JOBS='' \
		INTERM_COMPR_OR_CAT_STDOUT="${CAT_CMD}" \
		INTERM_COMPR_EXT='' \
		INTERM_COMPR_TO_FILE=''

	debug_msg "Preparing environment."

	set -o pipefail

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
				reg_failure "Failed to detect CPU core count. Parallel processing will be disabled."
				PARALLEL_JOBS=1
			fi ;;
		*)
			PARALLEL_JOBS="${MAX_PARALLEL_JOBS}"
	esac

	# Compression util
	get_compr_util_spec compr_util_path compr_ext "${compression_util:?}" || return 1

	# dnsmasq instances
	get_dnsmasq_instances ||
	{
		[ -n "${DNSMASQ_RESTART_TRIED}" ] && return 1
		restart_dnsmasq &&
		get_dnsmasq_instances ||
			return 1
	}

	check_dnsmasq_instances || return 1

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

	export -n GLOBAL_ENV_SET=1
	[ "${CUR_ACT}" = start ] && export -n SKIP_SET_ENV=1

	debug_msg "End set_global_env()"

	:
}

set_blocksets_env()
{
	local \
		me=set_blocksets_env \
		valid_ids \
		set_id \
		sbe_rv \
		compr_util_path compr_ext compr_cmd_to_file compr_cmd_stdout extr_cmd_stdout \
		set_ids="${*:-"${SET_IDS}"}"

	debug_msg "" "${me} start, set_ids '${set_ids}'"

	get_valid_set_ids valid_ids "${set_ids}"

	[ -n "${valid_ids}" ] || {
		[ -z "${set_ids}" ] && return 0
		reg_msg -yellow "No known blockset IDs specified."
		[ -n "${ASSERT_NOEXIT}" ] || exit 1
		return 1
	}

	get_compr_util_spec compr_util_path compr_ext "${compression_util:?}" || return 1

	[ -n "${compr_ext}" ] &&
	{
		compr_cmd_to_file="${compr_util_path} -f"
		compr_cmd_stdout="${compr_util_path} -c"
		extr_cmd_stdout="${compr_util_path} -cd"
	}

	read_blockset_metadata "${META_FILE:?}" "${valid_ids}" &&
	get_dnsmasq_ips "${valid_ids}" || sbe_rv=1

	for set_id in ${valid_ids}
	do
		set_bl_env "${set_id}" "${compr_ext}" "${extr_cmd_stdout}" "${compr_cmd_stdout}" "${compr_cmd_to_file}"
		sbe_rv=$(( ${sbe_rv:-0} + ${?} ))
	done

	debug_msg "${me} end" ""

	return ${sbe_rv}
}


# Populates global vars for individual blockset IDs
# Env vars:
#   SBE_STATUS: do not exit on non-critical errors
set_bl_env()
{
	rebuild_req_notice() { log_msg -warn "Please run 'service adblock-lean ${1}' to rebuild the ${2}${2:+ }blockset."; }
	wont_work() {
		reg_failure -wb "${set_id}" "" "${1} can not be used{} because of missing addnmounts in /etc/config/dhcp: ${2}" \
			"Please run 'service adblock-lean create_addnmounts' to create required addnmount entries."
	}

	# Run states:
	# 0 - running
	# 1 - error
	# 2 - (reserved)
	# 3 - paused
	# 4 - stopped
	#
	get_run_state()
	{
		local me=get_run_state \
			grs_curr_path grs_single_inst \
			curr_md5 install_1_instance bk_file \
			bl_check_res \
			grs_state \
			bl_in_conf_dir \
			cs_res \
			cd_state \
			bl_file_exists=0 \
			dns_check_res=0 \
			conf_dir conf_dirs \
			set_id="${1:?}" state_out_var="${2:-_}" path_out_var="${3:-_}" single_inst_out_var="${4:-_}"

		debug_msg "Checking state of blockset ${lblue}${set_id}${n_c}."

		unset_vars "${state_out_var}" "${path_out_var}" "${single_inst_out_var}"
		assert_set "F_${me}" GLOBAL_ENV_SET || return 1

		get_params "${set_id}" grs_curr_path=curr_path grs_single_inst=curr_single_instance curr_md5 install_1_instance conf_dirs bk_file

		: "${grs_single_inst:="${install_1_instance}"}"
		: "${grs_single_inst:=0}"

		debug_msg "${me}: grs_single_inst=${grs_single_inst};curr_md5=${curr_md5}"

		# Test adblocking
		if [ -n "${curr_md5}" ]
		then
			check_active_blockset "${set_id}" "${curr_md5}" "${grs_single_inst}"
			case ${?} in
				0) dns_check_res=1 ;; # pass
				2) dns_check_res=0 ;; # not pass
				*) dns_check_res=2 ;; # error
			esac
		fi

		[ -n "${grs_curr_path}" ] && [ -f "${grs_curr_path}" ] || grs_curr_path=

		# conf-scripts codes:
		# 0: all conf-scripts not found
		# 1: all conf-scripts found
		# 2: inconsistent state
		for conf_dir in ${conf_dirs}
		do
			[ -f "${conf_dir}/${CS_BASE_FNAME}-${set_id}" ] && cd_state=1 || cd_state=0
			[ -n "${cs_res}" ] || { cs_res="${cd_state}"; continue; }

			[ "${cs_res}" = "${cd_state}" ] || cs_res=2
		done
		: "${cs_res:=0}"

		[ -n "${grs_curr_path}" ] ||
			# Look for blockset file in all conf-dirs
			for conf_dir in ${ALL_CONF_DIRS}
			do
				for file in "${conf_dir}/${BLOCKSET_BASE_FNAME}-${set_id}" "${conf_dir}/${BLOCKSET_BASE_FNAME}-${set_id}."*
				do
					case "${file}" in *"*"*) continue; esac
					[ -f "${file}" ] && { grs_curr_path="${file}"; break; }
				done
				[ -n "${bl_in_conf_dir}" ] && grs_state=1 # blockset in conf-dir should only be found once, otherwise contradicts single-instance
				[ -n "${grs_curr_path}" ] && { bl_in_conf_dir=1 grs_single_inst=1; }
			done

		[ -n "${grs_curr_path}" ] && bl_file_exists=1

		# Summarize
		bl_check_res="${dns_check_res}${bl_file_exists}${cs_res}${grs_single_inst}"

		[ "${grs_state}" = 1 ] ||
			case "${bl_check_res}" in
				1110|1101) grs_state=0 ;; # running
				0100|0101)
					if [ -n "${bl_in_conf_dir}" ]
					then
						grs_state=1
					elif [ "${grs_curr_path}" = "${bk_file}" ]
					then
						grs_state=4 # stopped
					else
						grs_state=3  # paused
					fi ;;
				0000|0001) grs_state=4 ;; # stopped
				*) grs_state=1 ;;
			esac

		[ "${grs_state}" = 1 ] &&
			reg_failure "Unexpected state for blockset '${set_id}' (path '${grs_curr_path}')." \
				"DNS:${dns_check_res};file_exists:${bl_file_exists};conf-scripts:${cs_res};single_inst:${grs_single_inst};"

		export -n "${state_out_var}=${grs_state}" "${path_out_var}=${grs_curr_path}" "${single_inst_out_var}=${grs_single_inst}"

		debug_msg "${me}: set_id:${set_id}; run_state:${grs_state}; check res:${bl_check_res};"
		set_params "${set_id}" run_state="${grs_state}"

		:
	}

	local set_id="${1:?}" compr_ext="${2}" extr_cmd_stdout="${3}" compr_cmd_stdout="${4}" compr_cmd_to_file="${5}"

	local me=set_bl_env \
		IFS="${DEFAULT_IFS}" \
		\
		dnsmasq_indexes \
		conf_dirs \
		\
		run_state \
		\
		conf_script_log_avail \
		\
		first_conf_dir \
		sbe_missing_addnm \
		addnm_ignore_paths \
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
		persist_avail=0 \
		persist_dir \
		persist_mode \
		\
		curr_path \
		curr_single_instance \
		\
		curr_persist_path \
		curr_persist_cnt \
		\
		part_extr_or_cat_stdout \
		\
		final_compress \
		final_compr_ext \
		final_extr_or_cat_stdout="${CAT_CMD}" \
		final_compr_or_cat_stdout="${CAT_CMD}" \
		final_compr_to_file \
		\
		start_action=gen

	export -n "BL_ENV_SET_${set_id}="

	# Check addnmounts, possibility of final compression, multiple dnsmasq instances and persistent blockset creation,
	#   get final blockset paths,
	#   compression util path and extension

	debug_msg -fb "${set_id}" "Preparing blockset environment{}." "CUR_ACT: ${CUR_ACT}" "CUR_CMD: ${CUR_CMD}"

	get_params -f "${me}" "${set_id}" \
		dnsmasq_indexes \
		conf_dirs \
		persist_mode || return 1

	get_params "${set_id}" persist_dir

	set_base_fname=${BLOCKSET_BASE_FNAME:?}-${set_id}

	# conf-script error logging
	check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${LOG_CMD:?}" || return 1
	[ -z "${sbe_missing_addnm}" ] && conf_script_log_avail=1

	# Compression
	part_extr_or_cat_stdout="${CAT_CMD:?}"
	if [ -n "${compr_ext}" ]
	then
		assert_set "F_${me}" compr_cmd_to_file compr_cmd_stdout extr_cmd_stdout || return 1
		part_extr_or_cat_stdout="try_extract -stdout ${set_id}"
		bl_full_fname_check=${set_base_fname:?}${compr_ext}
		install_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname_check}
		check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${extr_cmd_stdout%% *}${_NL_}${install_path_ram_check}" || return 1

		if [ -z "${sbe_missing_addnm}" ]
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
			wont_work "Final blockset compression" "${sbe_missing_addnm}"
		fi
	fi
	set_params "${set_id}" part_extr_or_cat_stdout

	# Final blockset full filename
	: "${bl_full_fname:="${set_base_fname:?}"}"

	# Multiple dnsmasq instances
	case "${dnsmasq_indexes}" in
		*[0-9]*" "*[0-9]*)
			install_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname:?}
			check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${install_path_ram_check}" || return 1
			if [ -z "${sbe_missing_addnm}" ]
			then
				install_path_ram=${install_path_ram_check}
				install_1_instance_ram=0
			else
				wont_work "Multiple dnsmasq instances" "${sbe_missing_addnm}"
			fi ;;
		*)
			first_conf_dir="${conf_dirs%% *}"
			is_valid_dir "${first_conf_dir}" || return 1
			addnm_ignore_paths="${first_conf_dir}/${bl_full_fname}"

			[ "${final_compress}" = 1 ] ||
				{
					install_path_ram="${first_conf_dir}/${bl_full_fname}"
					install_1_instance_ram=1
				}
	esac

	# addnmount for blockset on ramdisk - required regardless of compr/persist/multi_inst availability
	sbe_missing_addnm=
	is_included "${install_path_ram}" "${addnm_ignore_paths}" "${_NL_}" ||
		check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${install_path_ram}" || return 1
	[ -z "${sbe_missing_addnm}" ] || { wont_work "adblock-lean" "${sbe_missing_addnm}"; [ -n "${SBE_STATUS}" ] || return 1; }

	CA_NOERR=1 get_run_state "${set_id}" run_state curr_path curr_single_instance || return 1
	case "${run_state}" in
		0|3|4) ;;
		*)
			case "${CUR_CMD}" in start|pause|resume)
				KEEP_PERSIST=1 stop_blocksets "${set_id}"
				CA_NOERR=1 get_run_state "${set_id}" run_state curr_path curr_single_instance || return 1
			esac
	esac
	set_params "${set_id}" curr_path curr_single_instance="${curr_single_instance}"

	# Persistent blockset
	case "${persist_mode}" in manual|managed)
		case "${CUR_ACT}" in start|pause|resume|status|gen_persist_blockset)
			if check_persist_dir "${set_id}"
			then
				local cat_addnm=''
				[ "${final_compress}" = 1 ] || cat_addnm="${_NL_}${CAT_CMD}"
				check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${persist_dir}${cat_addnm}" || return 1
				if [ -z "${sbe_missing_addnm}" ]
				then
					persist_avail=1
					[ "${persist_mode}" = managed ] &&
					{
						bl_path_persist="${persist_dir}/${bl_full_fname}"
						install_path="${bl_path_persist}"
						install_1_instance=0
					}
				else
					wont_work "Persistent blockset" "${sbe_missing_addnm}"
				fi
			else
				log_msg -warn -fb "${set_id}" "" "Persistent blockset file can not be used or updated{}."
			fi
		esac
	esac

	local cpb_rv=1
	[ "${persist_avail}" = 1 ] ||
	case "${CUR_ACT}" in
		stop|pause) : ;;
		*) false
	esac &&
		{
			FF_RM_EXTRA=1 find_files curr_persist_path "${persist_dir}" "${set_base_fname}." "*" ||
			FF_RM_EXTRA=1 find_files curr_persist_path "${persist_dir}" "${set_base_fname}"
			set_params "${set_id}" curr_persist_path
			[ -n "${curr_persist_path}" ] &&
			check_persist_blockset "${set_id}" "${final_compr_ext}"
			cpb_rv=${?}
		}

	if [ "${persist_avail}" = 1 ]
	then
		if \
			[ "${ABL_INIT_ACT}" = boot ] ||
			case "${CUR_ACT}" in
				status|pause) : ;;
				resume) [ "${run_state}" = 3 ] && is_persist "${curr_path}" "${set_id}" ;;
				*) false
			esac
		then
			if [ "${cpb_rv}" = 0 ]
			then
				[ "${CUR_ACT}" = resume ] || [ "${ABL_INIT_ACT}" = boot ] &&
				{
					start_action=load
					install_path=${curr_persist_path}
					install_1_instance=0
					get_params "${set_id}" curr_persist_cnt
					set_params "${set_id}" install_cnt="${curr_persist_cnt}"
				}
			else
				debug_msg "check_persist_blockset rv: ${cpb_rv}"
				[ "${persist_mode}" = manual ] && rebuild_req_notice "gen_persist_blockset" "persistent"

				[ "${CUR_ACT}" = status ] ||
				{
					KEEP_PERSIST=0 rm_if_writable "${set_id}" "${curr_persist_path}" "${curr_persist_path%/*}/${META_FNAME_PERSIST}"
					[ "${curr_path}" = "${curr_persist_path}" ] && unset_metadata "${set_id}"
					set_params "${set_id}" curr_persist_path= curr_persist_cnt=
				}

				[ "${CUR_CMD}" = start ] &&
				{
					local start_act_msg="Will create a new blockset file on the ramdisk."
					[ "${persist_mode}" = managed ] &&
						start_act_msg="Will rebuild the persistent blockset file."
					log_msg -fb "${set_id}" "${start_act_msg}{}"
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
		[ -z "${FORCE_PERSIST_INSTALL}" ] || is_persist "${install_path}" "${set_id}" ||
			{ reg_failure -b "${set_id}" "Can not generate persistent blockset file{}."; return 1; }
	esac

	[ -n "${install_path}" ] ||
		{ reg_failure "No usable path to install or load the blockset."; rebuild_req_notice "restart"; [ -n "${SBE_STATUS}" ] || return 1; }

	[ -n "${install_path}" ] &&
	case "${start_action}" in
		load) add2list BLOCKSETS_TO_INSTALL "${set_id}" ;;
		gen) add2list BLOCKSETS_TO_GEN "${set_id}" ;;
	esac

	pause_path="${install_path}"
	[ "${persist_mode}" = manual ] && [ -n "${curr_path}" ] && [ "${curr_path}" = "${curr_persist_path}" ] &&
		pause_path="${curr_persist_path}"
	[ "${install_path}" = "${install_path_ram}" ] && [ "${install_1_instance}" = 1 ] &&
		pause_path="${ABL_RUN_DIR}/${bl_full_fname}"

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

	export -n "BL_ENV_SET_${set_id}=1"

	: \
		"${pause_path}" \
		"${part_extr_or_cat_stdout}" \
		"${final_compr_to_file}" \
		"${final_compr_or_cat_stdout}" \
		"${conf_script_log_avail}"

	:
}

get_valid_set_ids()
{
	local gvi_id gvi_out_var="${1}" gvi_ids="${2}"
	[ -n "${gvi_out_var}" ] || bad_args get_valid_set_ids "${@}"
	unset_vars "${gvi_out_var}"
	shift

	for gvi_id in ${gvi_ids}
	do
		is_known_set_id "${gvi_id}" || continue
		add2list "${gvi_out_var}" "${gvi_id}"
	done
	:
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
		{ reg_failure "${2:+"${2}: "}${akb_err}"; return 1; }
	:
}

# Env vars: GBP_PREFIX
get_bl_param_gl_var()
{
	dbg_off
	local _gl_var
	eval "
		case \"${2:?}\" in
			${BL_PARAMS_CLAUSES:?}
			*) return 1 ;;
		esac
	"

	export -n "${1:?}=${GBP_PREFIX}${_gl_var}"
	dbg_on
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

		reg_failure "${err_func}: Value not set for \${${gl_var}_${set_id}}."
		return 1
	done
	:
	dbg_on
}

# 1: blockset IDs
# other args: any number of: 'param' to use current value, or 'param=value'
set_params()
{
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
				*=*=*) false ;;
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
	:
}

inst_failed()
{
	local fail_report_ids fail_ids="${1}"

	subtract_a_from_b "${inst_fail_reported_ids}" "${fail_ids}" fail_report_ids
	[ -n "${fail_report_ids}" ] &&
	{
		local set_pr=blockset
		case "${fail_report_ids}" in *" "*) set_pr=blocksets; esac
		reg_failure "Failed to install ${set_pr}: ${fail_ids}"
		add2list inst_fail_reported_ids "${fail_report_ids}"
	}
	KEEP_BK=1 stop_blocksets "${fail_ids}"
}

install_blocksets()
{
	local inst_ok_ids inst_fail_ids INST_PERM_FAIL_IDS inst_rv \
		inst_fail_reported_ids \
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
		dnsmasq_ok_ids \
		dnsmasq_fail_ids \
		\
		dnsmasq_stop_ids \
		\
		dnsmasq_indexes \
		persist_mode \
		skip_load_stop \
		\
		curr_path \
		\
		install_path \
		install_path_ram \
		install_md5 \
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
		[ -n "${skip_load_stop}" ] || add2list dnsmasq_stop_ids "${set_id}"
	done

	[ -z "${dnsmasq_stop_ids}" ] || stop_dnsmasq "${dnsmasq_stop_ids}" || return 1

	printf '\n' > "${MSGS_DEST}"

	for set_id in ${set_ids}
	do
		get_params -f "${me}" "${set_id}" dnsmasq_indexes conf_dirs final_extr_or_cat_stdout install_path || { inst_failed "${set_id}"; continue; }
		get_params "${set_id}" install_1_instance conf_script_log_avail

		log_msg "Installing blockset ${lblue}${set_id}${n_c} to ${blue}${install_path}${n_c}"

		get_md5 install_md5 "${install_path}" || { inst_failed "${set_id}"; continue; }

		[ "${install_1_instance}" = 1 ] ||
		# Make conf-script
		for conf_dir in ${conf_dirs}
		do
			is_valid_dir "${conf_dir}" || { inst_failed "${set_id}"; continue 2; }

			cat <<-EOF | ${SED_CMD} -E 's/\t+//g' > "${conf_dir}/${CS_BASE_FNAME}-${set_id}" || { reg_failure "Failed to create conf-script in directory '${conf_dir}'."; return 1; }
				conf-script=\
				${final_extr_or_cat_stdout} "${install_path}" && \
				printf '%s\n' "address=/${install_md5}-${ABL_TEST_DOM_BASE}/#" && \
				exit 0; \
				${conf_script_log_avail:+"${LOG_CMD} -t adblock-lean-conf-script -p user.err 'conf-script at '${conf_dir}/${CS_BASE_FNAME}-${set_id}' failed.';"} \
				exit 0
			EOF
		done

		set_params "${set_id}" install_md5

		add2list installed_ids "${set_id}"
	done

	[ -n "${installed_ids}" ] && restart_dnsmasq 5 dnsmasq_ok_ids "${installed_ids}"
	subtract_a_from_b "${dnsmasq_ok_ids}" "${installed_ids}" dnsmasq_fail_ids
	[ -n "${dnsmasq_fail_ids}" ] && inst_failed "${dnsmasq_fail_ids}"
	[ -n "${dnsmasq_ok_ids}" ] || return 1

	printf '\n' > "${MSGS_DEST}"

	for set_id in ${dnsmasq_ok_ids}
	do
		get_params -f "${me}" "${set_id}" install_path install_1_instance install_md5 install_cnt ||
			{ inst_failed "${set_id}"; continue; }

		CA_CHECK_DNS=1 check_active_blockset "${set_id}" "${install_md5}" "${install_1_instance}" ||
			{
				reg_failure -fb "${set_id}" "Active blockset check failed{}."
				inst_failed "${set_id}"
				continue
			}

		rm_bk "${set_id}"

		set_params "${set_id}" \
			curr_path="${install_path}" \
			curr_single_instance="${install_1_instance}" \
			curr_md5="${install_md5}" \
			curr_cnt="${install_cnt}" \
			run_state=0

		add2list "${try_inst_ok_ids_out_var}" "${set_id}"
	done

	:
}

# 1 - domain
# 2 - nameservers
# 3 - max attempts
# 4 - (optional) '-n': don't check if result is 127.0.0.1 or 0.0.0.0
try_lookup_domain()
{
	local ns_res ip lookup_ok i=0 IFS="${DEFAULT_IFS}"

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


### METADATA

# Env vars: UNSET_PREFIX
# 1 (optional): blockset IDs
unset_metadata()
{
	local meta_param set_id \
		unset_dbg \
		set_ids="${*-"${SET_IDS}"}"

	for set_id in ${set_ids}
	do
		for meta_param in ${META_PARAMS:?}
		do
			unset "${UNSET_PREFIX}${meta_param}_${set_id}"
			unset_dbg="${unset_dbg}${unset_dbg:+"${_NL_}"}unset ${UNSET_PREFIX}${meta_param}_${set_id}"
		done
	done
	[ -n "${unset_dbg}" ] && debug_msg "${_NL_}${unset_dbg}"
}

# Env vars: COMMIT_META_LOCATIONS
commit_metadata()
{
	try_commit_metadata && return 0
	reg_failure "Failed to create or update the metadata file (return code ${?})."
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
		curr_path \
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
			get_params "${set_id}" curr_path
			[ -n "${curr_path}" ] || continue

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
				{ reg_failure "Failed to create/update the metadata file '${meta_file}'."; return 2; }
		}
	}

	is_included PERSIST "${meta_locations}" || return 0

	# Persist metadata
	meta_fname="${META_FNAME_PERSIST}"
	for set_id in ${SET_IDS}
	do
		local persist_dir
		get_params "${set_id}" persist_dir curr_path
		is_persist "${curr_path}" "${set_id}" || continue

		[ -d "${persist_dir}" ] || { reg_failure -fb "${set_id}" "Can not update persistent metadata file{} because directory '${persist_dir}' is not found."; continue; }

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
				reg_failure -fb "${set_id}" "Failed to create/update persistent metadata file '${meta_file}'{}."
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
read_blockset_metadata()
{
	local me=read_blockset_metadata \
		_rbm_rv _rbm_ids _rbm_type
	try_read_blockset_metadata _rbm_ids _rbm_type "${@}"
	_rbm_rv=${?}
	debug_msg "${me} end (${_rbm_type}): ${_rbm_ids}"
	return ${_rbm_rv}
}

# shellcheck disable=SC2329
try_read_blockset_metadata()
{
	append_err() {
		rbm_errors="${rbm_errors}${rbm_errors:+"${_NL_}"}${1}"
		is_included "${set_id}" "${req_ids}" && rbm_rv=1
	}

	populate_vars()
	{
		local \
			pv_param \
			meta_val \
			bl_md5 \
			curr_path curr_cnt curr_md5 \
			set_id="${1}"
		local set_id_pr="blockset '${set_id}'"

		debug_msg "Processing ${rbm_type} metadata for ${set_id_pr}."

		is_alphanum "${set_id}" ||
			{ append_err "${sp_f_pr} contains invalid blockset ID '${1}'."; return 1; }

		for pv_param in ${meta_params}
		do
			config_get meta_val "${set_id}" "${pv_param}" # accept empty values
			export -n "${rbm_prefix}${pv_param}_${set_id}=${meta_val}"
			debug_msg "${blue}set metadata${n_c}: ${rbm_prefix}${pv_param}_${set_id}=${meta_val}"
		done

		GBP_PREFIX="${rbm_prefix}" get_params "${set_id}" curr_cnt curr_md5 curr_path
		[ -n "${curr_path}" ] || return 0

		is_included "${set_id}" "${req_ids}" ||
		{
			log_msg -warn "${sp_f_pr} contains stale entry for non-existing ${set_id_pr}."
			add2list stale_ids "${set_id}"
			return 1
		}

		# check md5
		get_md5 bl_md5 "${curr_path}" ||
			{ append_err "Failed to get MD5 sum of ${set_id_pr} file at ${curr_path}."; return 1; }

		[ "${curr_md5}" = "${bl_md5}" ] ||
			append_err "MD5 sum not matching in ${sp_f_pr} for ${set_id_pr}, path '${curr_path}'. Metadata file has: '${curr_md5}', blockset file has: '${bl_md5}'."

		# set persist params
		[ "${rbm_type}" = PERSIST ] &&
		{
			[ "${curr_path%/*}" = "${meta_file%/*}" ] ||
			{
				append_err "Persistent blockset dir not matching in ${sp_f_pr} for ${set_id_pr}. Metadata file has: '${curr_path%/*}', metadata is at: '${meta_file%/*}'."
				return 1
			}
			set_params "${set_id}" curr_persist_md5="${curr_md5}" curr_persist_cnt="${curr_cnt}"
		}
		:
	}

	local IFS="${DEFAULT_IFS}" \
		rbm_type=RAM \
		rbm_prefix \
		rbm_rv=0 \
		rbm_err rbm_errors \
		set_id \
		stale_ids \
		req_ids \
		meta_params="${META_PARAMS}" \
		meta_ids_out_var="${1}" meta_type_out_var="${2}"

	shift 2
	[ "${1}" = '-persist' ] && { rbm_type=PERSIST; shift; }

	local meta_file="${1}" meta_ids="${2:-"${SET_IDS}"}"
	local sp_f_pr="metadata file '${meta_file}'" \
		ACCEPT_UNKNOWN_SET_IDS=1

	export -n "${meta_ids_out_var}=${meta_ids}" "${meta_type_out_var}=${rbm_type}"

	debug_msg "${me} start (${rbm_type}): ${meta_ids}"

	[ -n "${SET_IDS}" ] || return 0

	[ -n "${meta_ids}" ] || { reg_failure "${me}: no blockset configs specified."; return 1; }

	[ -f "${meta_file}" ] ||
		{ debug_msg "${me}: can not find ${sp_f_pr}."; return 0; }

	case "${rbm_type}" in
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
	UCI_CONFIG_DIR="${meta_file%/*}" config_load "${meta_file##*/}" ||
		{ reg_failure "${me}: failed to load ${sp_f_pr}."; return 1; }
	dbg_on

	config_foreach populate_vars blockset_id

	IFS="${_NL_}"
	for rbm_err in ${rbm_errors}
	do
		IFS="${DEFAULT_IFS}"
		reg_failure "${me}: ${rbm_err}"
	done
	IFS="${DEFAULT_IFS}"

	[ -n "${stale_ids}" ] &&
		COMMIT_META_LOCATIONS=RAM FORCE_STOP_ALL=1 do_stop

	return ${rbm_rv}
}

: