#!/bin/sh
# shellcheck disable=SC3043,SC2016,SC3060,SC3040,SC3003,SC3020

# silence shellcheck warnings

META_FNAME="blocklist-metadata"
META_FNAME_PERSIST="persist_blocklist-metadata"
META_FILE="${ABL_RUN_DIR}/${META_FNAME}"
META_PARAMS="LOCATION PATH SINGLE_INSTANCE MD5 CNT"
PERSIST_META_PARAMS="PATH MD5 CNT"

IP_REGEX_4='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])'
IP_REGEX_6='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}'


: "${test_domains:=}" "${compression_util:=}" "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}" \
	"${blue:=}" "${green:=}" "${red:=}" "${n_c:=}"


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

# 1: blocklist ID
# 2: input file
# 3: command including options
# 4: (optional) var name to output path to compressed file
try_compress()
{
	local IFS="${DEFAULT_IFS}" tc_cmd opts='' tc_err='' \
		tc_dir tc_fname tc_ext \
		tc_bl_id="${1:?}" tc_in_file="${2}" tc_cmd="${3}" out_file_var="${4}"

	unset_vars "${out_file_var}" &&
	split_path tc_dir tc_fname _ "${tc_in_file}" && [ -n "${tc_fname}" ] && is_valid_dir "${tc_dir}" &&
	{
		is_dir_writable "${tc_bl_id}" "${tc_dir}" ||
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
			rm_if_writable "${tc_bl_id}" "${tc_in_file}";
			return 1
		}

	[ -n "${out_file_var}" ] && eval "${out_file_var}"='${tc_in_file}${tc_ext}'

	: "${tc_ext}"
	:
}

# 0 (optional): '-stdout' (does not remove source file)
# 1: blocklist ID
# 2: path to file to extract
try_extract()
{
	local stdout=
	[ "${1}" = '-stdout' ] && { stdout=1; shift; }

	local IFS="${DEFAULT_IFS}" cmd='' opts='' \
		file_opts='' \
		stdout_opts='' \
		te_dir te_fname te_ext \
		te_err='' \
		te_bl_id="${1}" te_file="${2:?}"

	split_path te_dir te_fname te_ext "${te_file}" && [ -n "${te_fname}" ] && is_valid_dir "${te_dir}" &&
	{
		[ -n "${stdout}" ] || is_dir_writable "${te_bl_id}" "${te_dir}" ||
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
		[ -n "${stdout}" ] || rm_if_writable "${te_bl_id}" "${te_fname}"*
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
		nonempty='' instance instances running_instances index l1_conf_file l1_conf_files conf_dirs i s f dir

	unset DNSMASQ_RUNNING_INDEXES ALL_CONF_DIRS ADDNMOUNTS_SET DNSMASQ_INST_SET
	DNSMASQ_INSTANCES_CNT=0
	reg_action -blue "Checking dnsmasq instances."

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
	export ADDNMOUNTS_SET=1

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

		add2list running_instances "${instance}" "${_NL_}" &&
		add2list DNSMASQ_RUNNING_INDEXES "${index}" || return 1
		l1_conf_files=

		# look for '-C' in values, get next value which is instance's conf file
		i=0
		while json_is_a $((i+1)) string
		do
			i=$((i+1))
			json_get_var s ${i}
			[ "${s}" = '-C' ] || continue
			json_get_var l1_conf_file $((i+1)) || return 1
			add2list l1_conf_files "${l1_conf_file}" "${_NL_}" || return 1
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

		eval "DNSMASQ_INST_NAME_${index}"='${instance}' \
			"CONF_DIRS_${index}"='${conf_dirs}' \
			"IFACES_${index}"='${ifaces}'
		cnt_lines "CONF_DIRS_CNT_${index}" "${conf_dirs}"
		index=$((index+1))
	done
	json_cleanup
	cnt_lines DNSMASQ_INSTANCES_CNT "${running_instances}"

	export DNSMASQ_INST_SET=1

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
	check_failed()
	{
		[ -n "${quiet}" ] && return 0
		reg_failure "${@}"
	}

	local quiet='' instance index dir instance_conf_dirs conf_dir_reg all_abl_conf_dirs='' \
		inst_ind="dnsmasq instance with index" \
		please_run="Please run 'service adblock-lean select_dnsmasq_instances'."

	[ "${1}" = '-q' ] && quiet=1

	assert_set F_check_dnsmasq_instances DNSMASQ_INST_SET || return 1

	[ -n "${DNSMASQ_INDEXES}" ] || { check_failed "DNSMASQ_INDEXES config option is not set."; return 1; }

	for index in ${DNSMASQ_INDEXES}
	do
		eval "[ \"\${RUNNING_${index}}\" = 1 ]" ||
		{
			check_failed "${inst_ind} ${index} is not running."
			do_stop
			get_dnsmasq_instances &&
			eval "[ \"\${RUNNING_${index}}\" = 1 ]" ||
			{
				check_failed "${inst_ind} ${index} is misconfigured or not running."
				return 1
			}
		}

		conf_dir_reg=
		eval "instance_conf_dirs=\"\${CONF_DIRS_${index}}\""
		[ -n "${instance_conf_dirs}" ] ||
			{ check_failed "dnsmasq config directory is not set for instance with index ${index}."; return 1; }
		all_abl_conf_dirs="${all_abl_conf_dirs}${instance_conf_dirs}${_NL_}"

		local IFS="${_NL_}"
		for dir in ${instance_conf_dirs}
		do
			IFS="${DEFAULT_IFS}"
			is_included "${dir}" "${DNSMASQ_CONF_DIRS}" && conf_dir_reg=1
			[ -d "${dir}" ] ||
			{
				check_failed "Conf-dir '${dir}' does not exist. ${inst_ind} ${index} is misconfigured. ${please_run}"
				return 1
			}
		done
		IFS="${DEFAULT_IFS}"

		[ -n "${conf_dir_reg}" ] ||
		{
			check_failed "Conf-dirs for ${inst_ind} ${index} changed. ${please_run}"
			return 1
		}

		# check if config section exists in /etc/config/dhcp
		uci show "dhcp.@dnsmasq[${index}]" &>/dev/null ||
		{
			check_failed "${inst_ind} ${index} is running but not registered in /etc/config/dhcp. Use the command 'service dnsmasq restart' and then re-try."
			return 1
		}
	done

	for dir in ${DNSMASQ_CONF_DIRS}
	do
		is_included "${dir}" "${all_abl_conf_dirs}" "${_NL_}" ||
			{ check_failed "conf-dir directory '${dir}' is set in config but not used by dnsmasq instances '${DNSMASQ_INDEXES}'."; return 1; }
	done

	:
}

# analyze dnsmasq instances and set $DNSMASQ_CONF_DIRS
# 1 - (optional) '-n' to only set vars (no config write)
do_select_dnsmasq_instances() {
	validate_indexes()
	{
		printf '%s\n' "${1}" | grep -qE "^(a|${indexes}|(${indexes} )+)$" &&
		case "${1}" in
			a) : ;;
			*[!0-9\ ]*) false ;;
			*) :
		esac
	}

	get_dnsmasq_instances && is_uint "${DNSMASQ_INSTANCES_CNT}" && [ "${DNSMASQ_INSTANCES_CNT}" -gt 0 ] ||
	{
		reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."
		do_stop
		get_dnsmasq_instances && is_uint "${DNSMASQ_INSTANCES_CNT}" && [ "${DNSMASQ_INSTANCES_CNT}" -gt 0 ] || return 1
	}

	local conf_dirs='' instance conf_dirs_instance index indexes='' ifaces='' REPLY first diff conf_dirs_cnt conf_dirs_print='' add_dir

	if [ "${DNSMASQ_INSTANCES_CNT}" = 1 ]
	then
		reg_msg -blue "Detected only 1 dnsmasq instance - skipping manual instance selection."
		DNSMASQ_INDEXES="${DNSMASQ_RUNNING_INDEXES%% *}"
	else
		# check if all instances share same conf-dirs
		REPLY='' first=1 diff='' conf_dirs_cnt=''
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

		# if conf-dirs are shared, attach to first instance
		if [ -z "${diff}" ]
		then
			reg_msg -blue "Detected multiple dnsmasq instances which are using the same conf-dir. Skipping manual instance selection."
			DNSMASQ_INDEXES="${DNSMASQ_RUNNING_INDEXES%% *}"
		else
			# if conf-dirs are not shared, ask the user
			reg_msg -blue "Multiple dnsmasq instances detected."
			REPLY=a
			if [ "${DO_DIALOGS}" = 1 ]
			then
				reg_msg "" "Existing dnsmasq instances and assigned network interfaces:"
				for index in ${DNSMASQ_RUNNING_INDEXES}
				do
					eval "instance=\"\${DNSMASQ_INST_NAME_${index}}\"" \
						"ifaces=\"\${IFACES_${index}}\""
					ifaces="${ifaces//"${_NL_}"/, }"
					reg_msg "${index}. Instance '${instance}': interfaces '${ifaces}'"
					indexes="${indexes}${index}|"
				done
				print_msg "" "Please select which dnsmasq instance should have active adblocking, or 'a' to abort." \
					"To adblock on multiple instances, enter their indexes separated by whitespaces."
				while :
				do
					printf %s "${indexes}a: " > "${MSGS_DEST}"
					read -r REPLY
					validate_indexes "${REPLY}" ||
						{ printf '\n%s\n\n' "Please enter ${indexes}a" > "${MSGS_DEST}"; continue; }
					break
				done
			elif [ -n "${LUCI_DNSMASQ_INDEXES}" ]
			then
				REPLY="${LUCI_DNSMASQ_INDEXES}"
				validate_indexes "${REPLY}" ||
					{ reg_failure "Invalid dnsmasq instance indexes '${REPLY}'."; return 1; }
			else
				reg_failure "dnsmasq indexes not specified."
				return 1
			fi

			[ "${REPLY}" = a ] && { reg_msg "Aborted config generation."; exit 0; }
			DNSMASQ_INDEXES="${REPLY}"
		fi
	fi

	local select_ifaces=
	for index in ${DNSMASQ_INDEXES}
	do
		eval "ifaces=\"\${IFACES_${index}}\""
		add2list select_ifaces "${ifaces}" "${_NL_}"
	done

	log_msg "Selected dnsmasq indexes: '${DNSMASQ_INDEXES}' (network intefaces: ${select_ifaces//"${_NL_}"/, })."

	DNSMASQ_CONF_DIRS=
	for index in ${DNSMASQ_INDEXES}
	do
		add_dir=''
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
		[ -n "${add_dir}" ] && { add2list DNSMASQ_CONF_DIRS "${add_dir}"; add2list conf_dirs_print "${add_dir}" ", "; }
	done

	[ -n "${DNSMASQ_CONF_DIRS}" ] || { reg_failure "Failed to detect conf-dirs for dnsmasq indexes '${DNSMASQ_INDEXES}'."; return 1; }

	log_msg "Selected dnsmasq conf-dirs: ${conf_dirs_print}"
	if [ "${1}" != '-n' ]
	then
		write_config "$(
			${SED_CMD} "
				s~^\s*DNSMASQ_INDEXES=.*~DNSMASQ_INDEXES=\"${DNSMASQ_INDEXES}\"~
				s~^\s*DNSMASQ_CONF_DIRS=.*~DNSMASQ_CONF_DIRS=\"${DNSMASQ_CONF_DIRS}\"~
			" "${ABL_CONFIG_FILE}"
		)" || return 1
	fi

	:
}

# Get interfaces each dnsmasq instance is listening on and associated IP addresses
# Populates global vars: NS4_${dnsmasq_index}, NS6_${dnsmasq_index}
get_dnsmasq_ips()
{
	local me=get_dnsmasq_ips \
		IFS="${DEFAULT_IFS}" \
		odevs linux_ifaces dnp_res

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
		${IP_CMD} -o addr show |
		${SED_CMD} -nE "/^\s*[0-9]+:\s*/{s/^\s*[0-9]+\s*:\s+//;s/inet[6]*\s+//;s/\s(${IP_REGEX_4:?}|${IP_REGEX_6:?})(\/[0-9]+)\s.*/\1/;s/\s+/ /;s/\s+$//;p;}"
	)" &&

	dnp_res="$(
		${NETSTAT_CMD} -plnt |
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


	# dnsmasq nameserver IP's
	local line index dnsmasq_indexes \
		all_dnsmasq_indexes='' \
		bl_id \
		inst_name inst_pid inst_iface \
		inst_ip_4 inst_ip_6 ip4_present ip6_present

	for bl_id in ${BL_IDS}
	do
		get_bl_params -f "${me}" "${bl_id}" dnsmasq_indexes || return 1
		add2list all_dnsmasq_indexes "${dnsmasq_indexes}"
	done

	for index in ${all_dnsmasq_indexes}
	do
		# iface and nameservers
		inst_iface='' inst_ip_4='' inst_ip_6='' ip4_present='' ip6_present=''

		eval "inst_name=\"\${DNSMASQ_INST_NAME_${index}}\""
		inst_pid="$(pgrep -f '^/usr/sbin/dnsmasq.*'"${inst_name:-???}"'.pid$')" ||
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

		eval "NS4_${index}"='${inst_ip_4}'
		eval "NS6_${index}"='${inst_ip_6}'
	done

	:
}


### GENERAL HELPER FUNCTIONS

mv_blocklist()
{
	local me=mv_blocklist mv_rv \
		mv_src_f="${1:?}" mv_dst_f="${2:?}" mv_compr_cmd="${3}" mv_bl_id="${4:?}"

	debug_msg "${me} start: '${mv_src_f}' to '${mv_dst_f}'"

	assert_set "F_${me}" mv_src_f mv_dst_f &&
	try_mv_blocklist "${@}"
	mv_rv=${?}
	
	debug_msg "${me} end"
	[ "${mv_rv}" = 0 ] &&
		{ set_bl_params "${mv_bl_id}" curr_path="${mv_dst_f}"; return 0; }

	rm_if_writable "${mv_bl_id}" "${mv_src_f}" "${mv_dst_f}"
	reg_failure "Failed to move blocklist '${mv_bl_id}' from '${mv_src_f}' to '${mv_dst_f}' (cmd: '${mv_compr_cmd}')."
	return 1
}

# Args:
# 1: src path
# 2: dst path
# 3: compression cmd
# 4: blocklist ID
# If src dir is protected, copy file instead of moving
try_mv_blocklist()
{
	local transfer_cmd="try_mv -q" \
		md5_changed='' \
		curr_md5 \
		mv_src_d mv_src_ext \
		mv_dst_d mv_dst_ext \
		mv_src_f="${1}" mv_dst_f="${2}" mv_compr_cmd="${3}" mv_bl_id="${4:?}"

	split_path mv_src_d _ mv_src_ext "${mv_src_f}" &&
	split_path mv_dst_d _ mv_dst_ext "${mv_dst_f}" || return 1

	is_valid_dir "${mv_src_d}" && is_valid_dir "${mv_dst_d}" || { reg_failure "${me}: unexpected src dir '${mv_src_d}' or dest dir '${mv_dst_d}'."; return 1; }

	[ -f "${mv_src_f}" ] || { reg_failure "${me}: file '${mv_src_f}' not found."; return 1; }

	[ "${mv_src_f}" = "${mv_dst_f}" ] && return 0

	is_dir_writable "${mv_bl_id}" "${mv_dst_d}" || { reg_failure "${me}: logic bug: attempted write into protected dir '${mv_dst_d}'."; return 1; }

	is_dir_writable "${mv_bl_id}" "${mv_src_d}" || transfer_cmd="cp"

	if [ -n "${mv_src_ext}" ] && [ "${mv_src_ext}" != "${mv_dst_ext}" ]
	then
		try_extract "${mv_bl_id}" "${mv_src_f}" || return 1
		mv_src_f="${mv_src_f%.*}"
		mv_src_ext=
		md5_changed=1
	fi

	if [ -n "${mv_dst_ext}" ] && [ -z "${mv_src_ext}" ]
	then
		try_compress "${mv_bl_id}" "${mv_src_f}" "${mv_compr_cmd:?}" mv_src_f || return 1
		md5_changed=1
	fi

	${transfer_cmd} "${mv_src_f}" "${mv_dst_f}" || return 1

	[ -n "${md5_changed}" ] &&
	{
		get_md5 curr_md5 "${mv_dst_f}" &&
		set_bl_params "${mv_bl_id}" curr_md5 ||
			return 1
	}

	:
}

# Make sure the directory is not the same as the mount point
check_persist_dir()
{
	local mnt_point persist_dir="${PERSIST_BLOCKLIST_DIR}"

	[ -d "${persist_dir}" ] ||
	{
		case "${persist_dir}" in
			''|/) reg_failure "Empty or invalid persistent blocklist directory'${persist_dir}' specified in config option PERSIST_BLOCKLIST_DIR." ;;
			*) reg_failure "Can not find persistent blocklist directory: ${persist_dir}."
		esac
		return 1
	}

	mnt_point="$(${DF_CMD} "${persist_dir}" |
		${AWK_CMD} '/^[ \t]*Filesystem[ \t]/{next} {i++; print $6} END{ if(i == 1) exit 0; exit 1}')" &&
	[ -d "${mnt_point}" ] ||
		{ reg_failure "Failed to get the mount point for partition where the persistent blocklist is stored (got '${mnt_point}')."; return 1; }

	[ "${persist_dir}" != "${mnt_point}" ] ||
		{  reg_failure "Persistent directory '${persist_dir}' is the same as the mount point. Please use a subdirectory."; return 1; }

	:
}

# Env vars:
#   CA_CHECK_DOMAINS: test DNS resolution
#   CA_NOERR: do not print error for test domain lookup failing
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

	local me=check_active_blocklist \
		family index dnsmasq_indexes instance_ns def_ns ns_ips ca_ns_4 ca_ns_6 ns_ips_sp ca_test_dom \
		bl_id="${1}" ca_md5="${2}" ca_single_instance="${3}"

	assert_set "F_${me}" bl_id ca_md5 || return 1

	GDI_NOFORCE=1 get_dnsmasq_instances || return 1

	get_bl_params -f "${me}" "${bl_id}" dnsmasq_indexes || return 1

	[ -n "${ca_single_instance}" ] && ca_md5='' # md5 not part of test domain for single instance
	ca_test_dom="${ca_md5}${ca_md5:+"-"}${ABL_TEST_DOM_BASE:?}"

	debug_msg "${me}: bl_id:'${bl_id}', indexes:'${dnsmasq_indexes}', md5:'${ca_md5}'"

	for index in ${dnsmasq_indexes}
	do
		ns_ips='' ns_ips_sp=''

		eval "ca_ns_4=\"\${NS4_${index}}\"" "ca_ns_6=\"\${NS6_${index}}\""
		debug_msg "${me}: ips: '${ca_ns_4}', '${ca_ns_6}'"

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

		ca_print "Testing dnsmasq instance ${index}."
		ca_print "Using following nameservers for DNS resolution verification: ${ns_ips_sp}"

		ca_print -blue "Testing adblocking."

		try_lookup_domain "${ca_test_dom}" "${ns_ips}" 1 -n || { [ -n "${CA_NOERR}" ] || lookup_failed "${ca_test_dom}"; return 2; }

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

# Sets global var RUN_STATE_${bl_id}
#
# 1: blocklist ID
#
# Run states:
# 0 - running
# 1 - error
# 2 - (reserved)
# 3 - paused
# 4 - stopped
#
# Return code is run state
get_bl_run_state()
{
	local me=get_bl_run_state \
		bl_id \
		curr_path curr_md5 curr_single_instance \
		bl_check_res \
		run_state \
		bl_file_exists \
		cs_res='' dns_check_res='' \
		conf_dir conf_dirs cd_state \
		bl_id="${1:?}"

	assert_set "F_${me}" ABL_ENV_SET || return 1

	print_msg -blue "Checking state of adblock-lean blocklist '${bl_id}'"

	get_bl_params "${bl_id}" curr_path curr_md5 curr_single_instance conf_dirs

	debug_msg "${me}: curr_path=${curr_path};curr_single_instance=${curr_single_instance};curr_md5=${curr_md5}"

	# Test adblocking
	if [ -n "${curr_md5}" ]
	then
		check_active_blocklist "${bl_id}" "${curr_md5}" "${curr_single_instance}"
		case ${?} in
			0|2) dns_check_res=${?} ;;
			*) dns_check_res=1 ;;
		esac
	else
		dns_check_res=2
	fi

	# Check conf-scripts
	# codes:
	# 0: all conf-scripts found
	# 1: inconsistent state
	# 2: all conf-scripts not found
	for conf_dir in ${conf_dirs}
	do
		[ -f "${conf_dir}/abl-conf-script" ] && cd_state=0 || cd_state=2
		[ -n "${cs_res}" ] || { cs_res="${cd_state}"; continue; }
		[ "${cs_res}" = "${cd_state}" ] || cs_res=1		
	done
	: "${cs_res:=2}"

	# Check if blocklist file exists
	[ -f "${curr_path}" ]
	bl_file_exists=${?}

	# Summarize
	bl_check_res="${dns_check_res}${bl_file_exists}${cs_res}${curr_single_instance:-0}"
	case "${bl_check_res}" in
		0000|0021) run_state=0 ;; # running
		2020|2001|2021) run_state=3 ;; # paused
		2120|2101) run_state=4 ;; # stopped
		*)
			run_state=1
			reg_failure "Unexpected state for blocklist '${bl_id}'. DNS:${dns_check_res};file_exists:${bl_file_exists};conf-scripts:${cs_res};single_inst:${curr_single_instance:-0};"
	esac
	set_bl_params "${bl_id}" run_state

	debug_msg "${me}: bl_id:'${bl_id}'; check res:'${bl_check_res}'"

	return "${run_state}"
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

	unset_vars "${ca_missing_var}" &&
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

			[ -n "${ca_missing_var}" ] && add2list "${ca_missing_var}" "'${ca_path}'" ", "
		done
		IFS="${DEFAULT_IFS}"
	done
	:
}

# Populates global vars required for processing, status and cleanup
# Env vars:
#   SBE_STATUS: do not exit on non-critical errors
#
# 1 (optional): blocklist IDs (defaults to all)
set_global_env()
{
	[ -n "${ABL_ENV_SET}" ] && return 0

	local me=set_global_env \
		IFS="${DEFAULT_IFS}" \
		compr_util_path \
		compr_ext \
		extr_cmd_stdout \
		compr_cmd_to_file \
		compr_cmd_stdout \
		cpu_cnt \
		bl_ids="${*:-"${BL_IDS}"}"

	export \
		PARALLEL_JOBS='' \
		INTERM_COMPR_OR_CAT_STDOUT="${CAT_CMD}" \
		INTERM_COMPR_EXT='' \
		INTERM_COMPR_TO_FILE=''

	debug_msg "Preparing environment." 

	assert_set "F_${me}" bl_ids || return 1

	set -o pipefail

	read_blocklist_metadata "${META_FILE}" "${bl_ids}" # ignore errors

	get_dnsmasq_instances &&
	check_dnsmasq_instances &&
	get_dnsmasq_ips ||
		return 1

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

		INTERM_COMPR_OR_CAT_STDOUT=${compr_cmd_stdout}
		INTERM_COMPR_TO_FILE=${compr_cmd_to_file}
		INTERM_COMPR_EXT=${compr_ext}
	}

	debug_msg "compr_util_path: '${compr_util_path}', compr_ext: '${compr_ext}'"

	export ABL_ENV_SET=1 # must precede call to get_bl_run_state()

	for bl_id in ${bl_ids}
	do
		set_bl_env "${bl_id}" "${compr_ext}" "${extr_cmd_stdout}" "${compr_cmd_stdout}" "${compr_cmd_to_file}" &&
		CA_NOERR=1 get_bl_run_state "${bl_id}"
	done

	debug_msg "End set_global_env()"

	:
}


# Populates global vars for individual blocklist IDs
# Env vars:
#   SBE_STATUS: do not exit on non-critical errors
set_bl_env()
{
	rebuild_req_notice() { log_msg -warn "Please run 'service adblock-lean ${1}' to rebuild the ${2}${2:+ }blocklist."; }
	wont_work() {
		reg_failure "${1} can not be used because of missing addnmounts in /etc/config/dhcp: ${2}" \
			"Please run 'service adblock-lean create_addnmounts' to create required addnmount entries."
	}

	local bl_id="${1}" compr_ext="${2}" extr_cmd_stdout="${3}" compr_cmd_stdout="${4}" compr_cmd_to_file="${5}"

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
		bl_base_fname \
		bl_full_fname_check \
		bl_full_fname \
		bl_path_persist \
		\
		pause_path \
		\
		install_location=RAM \
		install_path \
		install_path_ram \
		install_path_ram_check \
		new_single_instance \
		\
		persist_avail=0 \
		persist_dir \
		persist_mode \
		\
		curr_path \
		curr_location \
		curr_cnt \
		\
		curr_persist_path \
		curr_persist_cnt \
		curr_persist_cnt_human \
		curr_persist_size_b \
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

	# Check addnmounts, possibility of final compression, multiple dnsmasq instances and persistent blocklist creation,
	#   get final blocklist paths,
	#   compression util path and extension

	debug_msg "Preparing environment for blocklist ${bl_id}."

	get_bl_params -f "${me}" "${bl_id}" \
		dnsmasq_indexes \
		conf_dirs \
		persist_mode &&

	get_bl_params "${bl_id}" \
		persist_dir \
		curr_path \
		curr_location \
		curr_cnt \
		run_state || return 1

	bl_base_fname=${BLOCKLIST_BASE_FNAME:?}-${bl_id}

	# conf-script error logging
	check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${LOG_CMD:?}" || return 1
	[ -z "${sbe_missing_addnm}" ] && conf_script_log_avail=1

	# Compression
	part_extr_or_cat_stdout="${CAT_CMD:?}"
	set_bl_params "${bl_id}" part_extr_or_cat_stdout

	# Final blocklist compr commands, filenames, ramdisk blocklist path
	if [ -n "${compr_ext}" ]
	then
		assert_set "F_${me}" compr_cmd_to_file compr_cmd_stdout extr_cmd_stdout || return 1
		part_extr_or_cat_stdout="try_extract -stdout ${bl_id}"
		set_bl_params "${bl_id}" part_extr_or_cat_stdout
		bl_full_fname_check=${bl_base_fname:?}${compr_ext}
		install_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname_check}
		check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${extr_cmd_stdout%% *}${_NL_}${install_path_ram_check}" || return 1

		if [ -z "${sbe_missing_addnm}" ]
		then
			bl_full_fname=${bl_full_fname_check}
			install_path_ram=${install_path_ram_check}

			final_compress=1
			final_compr_ext=${compr_ext}
			final_compr_to_file=${compr_cmd_to_file}
			final_compr_or_cat_stdout=${compr_cmd_stdout}
			final_extr_or_cat_stdout=${extr_cmd_stdout}
		else
			wont_work "Final blocklist compression" "${sbe_missing_addnm}"
		fi
	fi

	# Final blocklist full filename
	: "${bl_full_fname:="${bl_base_fname:?}"}"

	# Multiple dnsmasq instances
	case "${dnsmasq_indexes}" in
		*[0-9]*" "*[0-9]*)
			install_path_ram_check=${ABL_RUN_DIR:?}/${bl_full_fname:?}
			check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${install_path_ram_check}" || return 1
			if [ -z "${sbe_missing_addnm}" ]
			then
				install_path_ram=${install_path_ram_check}
			else
				wont_work "Multiple dnsmasq instances" "${sbe_missing_addnm}"
			fi ;;
		*)
			first_conf_dir="${conf_dirs%% *}"
			is_valid_dir "${first_conf_dir}" || return 1
			addnm_ignore_paths="${first_conf_dir}/${bl_full_fname}"

			[ -n "${install_path_ram}" ] ||
				{ install_path_ram="${first_conf_dir}/${bl_full_fname}"; new_single_instance=1; }
	esac

	# addnmount for blocklist on ramdisk - required regardless of compr/persist/multi_inst availability
	sbe_missing_addnm=
	is_included "${install_path_ram}" "${addnm_ignore_paths}" "${_NL_}" ||
		check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${install_path_ram}" || return 1
	[ -z "${sbe_missing_addnm}" ] || { wont_work "adblock-lean" "${sbe_missing_addnm}"; [ -n "${SBE_STATUS}" ] || return 1; }

	# Persistent blocklist
	case "${persist_mode}" in manual|managed)
		if check_persist_dir
		then
			check_addnmounts sbe_missing_addnm "${dnsmasq_indexes}" "${persist_dir}" || return 1
			if [ -z "${sbe_missing_addnm}" ]
			then
				persist_avail=1
				[ "${persist_mode}" = managed ] && bl_path_persist="${persist_dir}/${bl_full_fname}"
			else
				wont_work "Persistent blocklist" "${sbe_missing_addnm}"
			fi
		else
			log_msg -warn "" "Persistent blocklist can not be used or updated."
		fi
	esac

	if [ "${persist_avail}" = 1 ]
	then
		FF_RM_EXTRA=1 find_files curr_persist_path "${persist_dir}" "${bl_base_fname}"
		set_bl_params "${bl_id}" curr_persist_path

		debug_msg "curr_persist_path for bl_id '${bl_id}': '${curr_persist_path}'"

		if \
			case "${ABL_INIT_ACTION}" in
				boot|status) : ;;
				resume) [ "${run_state}" = 3 ] && [ "${curr_path}" = "${curr_persist_path}" ] ;;
				*) false ;;
			esac
		then
			reg_msg -blue "Checking the persistent blocklist ${curr_persist_path}"
			local min_good_line_count_human='' persist_ext='' persist_fail='' curr_persist_cnt='' curr_persist_cnt_human=''

			if
				{
					[ -n "${curr_persist_path}" ] ||
						{
							[ "${persist_mode}" = manual ] && persist_mode=disable
							persist_fail="Persistent blocklist not found in directory '${persist_dir}'."
							false
						}
				} &&

				{
					get_compr_spec persist_ext _ "${curr_persist_path}" ||
						{ persist_fail="Can not find utility to extract persistent blocklist file '${curr_persist_path}'."; false; }
				} &&

				{
					[ "${persist_ext}" = "${final_compr_ext}" ] ||
						{
							persist_fail="Extension '${persist_ext}' of persistent blocklist file '${curr_persist_path}' does not match required extension '${final_compr_ext}'."
							false
						}
				} &&

				curr_persist_size_b="$(get_file_size "${curr_persist_path}")" &&
				{
					[ $(( curr_persist_size_b/1024 )) -le "${max_blocklist_file_size_KB}" ] ||
					{ persist_fail="Persistent blocklist file '${curr_persist_path}' is larger than the maximum value set in config (${max_blocklist_file_size_KB} KiB)."; false; }
				} &&

				{
					{ [ "${curr_location}" = PERSIST ] && [ -n "${curr_cnt}" ] && curr_persist_cnt="${curr_cnt}"; } ||
					{
						read_blocklist_metadata -persist "${curr_persist_path%/*}/${META_FNAME}" "${bl_id}" &&
						get_bl_params "${bl_id}" curr_persist_cnt
					}
				} &&

				{
					int2human curr_persist_cnt_human "${curr_persist_cnt}" &&
					int2human min_good_line_count_human "${min_good_line_count}" || return 1
				} &&

				{
					[ "${curr_persist_cnt}" -ge "${min_good_line_count}" ] ||
						{
							persist_fail="Entries count (${curr_persist_cnt_human}) in the persistent blocklist '${curr_persist_path}' is below the minimum value set in config (${min_good_line_count_human})."
							false
						}
				}
			then
				start_action=load
				install_path=${curr_persist_path}
			else
				{ [ "${ABL_INIT_ACTION}" = status ] ||
				{
					KEEP_PERSIST=0 rm_if_writable "${bl_id}" "${curr_persist_path}" "${curr_persist_path%/*}/${META_FNAME}"; }
					[ "${curr_path}" = "${curr_persist_path}" ] && unset_metadata "${bl_id}"
					curr_persist_path=
					curr_persist_cnt=
					set_bl_params "${bl_id}" curr_persist_path curr_persist_cnt
				}

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
			[ "${ABL_CMD}" = start ] && reg_msg "" "Will update the persistent blocklist." ""
			install_path=${bl_path_persist}
		fi
	fi

	: "${install_path:="${install_path_ram}"}"

	[ -n "${install_path}" ] &&
	case "${start_action}" in
		load) add2list BLOCKLISTS_TO_INSTALL "${bl_id}" ;;
		gen) add2list BLOCKLISTS_TO_GEN "${bl_id}" ;;
		*) reg_failure "${me}: invalid start action '${start_action}'."; return 1 ;;
	esac ||
		{ reg_failure "No usable path to install or load the blocklist."; rebuild_req_notice "restart"; [ -n "${SBE_STATUS}" ] || return 1; }

	[ "${install_path}" = "${bl_path_persist}" ] && install_location=PERSIST

	pause_path="${install_path}"
	[ -n "${new_single_instance}" ] &&
		pause_path="${ABL_RUN_DIR}/${bl_full_fname}"

	set_bl_params "${bl_id}" \
		install_location \
		install_path \
		install_path_ram \
		new_single_instance \
		pause_path \
		bk_ext="${INTERM_COMPR_EXT}" \
		final_compress \
		final_compr_ext \
		final_extr_or_cat_stdout \
		final_compr_or_cat_stdout \
		final_compr_to_file \
		conf_script_log_avail

	: \
		"${new_single_instance}" \
		"${pause_path}" \
		"${final_compress}" \
		"${final_compr_to_file}" \
		"${conf_script_log_avail}"

	debug_msg \
		"install_location: '${install_location}'" \
		"install_path: '${install_path}'" \
		"part_extr_or_cat_stdout: '${part_extr_or_cat_stdout}'" \
		"final_compr_or_cat_stdout: '${final_compr_or_cat_stdout}'" \
		"final_extr_or_cat_stdout: '${final_extr_or_cat_stdout}'" \
		"final_compr_ext: '${final_compr_ext}'"

	:
}


# Env vars: GBP_PREFIX
#
get_bl_param_gl_var()
{
	case "${2:?}" in
		run_state) gl_var=RUN_STATE ;;
		skip_load_stop) gl_var=SKIP_LOAD_STOP ;;
		bk_ext) gl_var=BK_EXT ;;
		bk_file) gl_var=BK_FILE ;;

		curr_persist_path) gl_var=PERSIST_PATH ;;
		curr_persist_cnt) gl_var=PERSIST_CNT ;;
		curr_persist_md5) gl_var=PERSIST_MD5 ;;

		curr_location) gl_var=LOCATION ;;
		curr_path) gl_var=PATH ;;
		curr_md5) gl_var=MD5 ;;
		curr_cnt) gl_var=CNT ;;
		curr_single_instance) gl_var=SINGLE_INSTANCE ;;

		install_location) gl_var=INSTALL_LOCATION ;;
		install_path) gl_var=INSTALL_PATH ;;
		install_cnt) gl_var=INSTALL_CNT ;;
		install_path_ram) gl_var=INSTALL_PATH_RAM ;;

		new_single_instance) gl_var=NEW_SINGLE_INSTANCE ;;

		pause_path) gl_var=PAUSE_PATH ;;

		final_compress) gl_var=FINAL_COMPRESS ;;
		final_compr_ext) gl_var=FINAL_COMPR_EXT ;;
		final_extr_or_cat_stdout) gl_var=FINAL_EXTR_OR_CAT_STDOUT ;;
		final_compr_or_cat_stdout) gl_var=FINAL_COMPR_OR_CAT_STDOUT ;;
		final_compr_to_file) gl_var=FINAL_COMPR_TO_FILE ;;
		part_extr_or_cat_stdout) gl_var=PART_EXTR_OR_CAT_STDOUT ;;
		conf_script_log_avail) gl_var=CONF_SCRIPT_LOG_AVAIL ;;

		# from config
		dnsmasq_indexes) gl_var=DNSMASQ_INDEXES ;;
		conf_dirs) gl_var=DNSMASQ_CONF_DIRS ;;
		persist_dir) gl_var=PERSIST_DIR ;;
		persist_mode) gl_var=PERSIST_MODE ;;

		*) return 1
	esac

	eval "${1:?}"='${GBP_PREFIX}${gl_var}'
}

assert_valid_bl_id()
{
	is_included "${1}" "${BL_IDS}" || { reg_failure "${2}: blocklist '${1}' is not included in registered blocklist IDs '${BL_IDS}'."; exit 1; }
}

# 0 (optional): '-f <func_name>' to error out if value is not set
# 1: blocklist ID
# other args: params/output var names
get_bl_params()
{
	local me=get_bl_params \
		gl_var val force_err err_func err_func_pr var_name

	[ "${1}" = '-f' ] && { err_func="${2}" err_func_pr="-f ${2} "; shift 2; }
	bl_id="${1:?}"
	shift

	for var_name in "${@}"
	do
		unset_vars "${var_name:?}" || exit 1
	done

	assert_valid_bl_id "${bl_id}" "${me}"

	for var_name in "${@}"
	do
		get_bl_param_gl_var gl_var "${var_name}" ||
		{
			bad_args "${me}" "${err_func_pr}${bl_id} ${*}"
			[ -n "${ASSERT_NOEXIT}" ] && return 1
			exit 1
		}

		eval "val=\"\${${gl_var}_${bl_id}}\""
		[ -n "${val}" ] || [ -z "${force_err}" ] &&
			{ eval "${var_name}"='${val}'; continue; }

		reg_failure "${err_func}: Value not set for \${${gl_var}_${bl_id}}."
		return 1
	done
	:
}

# 1: blocklist IDs
# other args: any number of: 'param' to use current value, or 'param=value'
set_bl_params()
{
	local me=set_bl_params \
		gl_var val param pair \
		bl_id \
		bl_ids="${1:?}"
	shift

	for bl_id in ${bl_ids}
	do
		assert_valid_bl_id "${bl_id}" "${me}"

		for pair in "${@}"
		do
			case "${pair}" in
				*=*=*) false ;;
				*=*)
					param="${pair%%=*}"
					val="${pair#*=}"
					are_var_names_safe "${param}" ;;
				*)
					param="${pair}"
					are_var_names_safe "${param}" &&
					eval "val=\"\${${param}}\"" ;;
			esac &&
			get_bl_param_gl_var gl_var "${param}" || { bad_args "${me}" "${bl_id} ${*}"; exit 1; }
			export "${gl_var}_${bl_id}=${val}"
		done
	done
	:
}

install_blocklists()
{
	local \
		me=install_blocklists \
		\
		dnsmasq_indexes \
		persist_mode \
		skip_load_stop \
		\
		curr_path \
		\
		install_location \
		install_path \
		install_path_ram \
		install_desc \
		install_md5 \
		install_cnt \
		new_single_instance \
		\
		final_extr_or_cat_stdout \
		conf_dir conf_dirs \
		conf_script_log_avail \
		\
		some_succeeded \
		\
		abl_cmd="${ABL_CMD}" \
		\
		ok_blocklists_out_var="${1}" perm_fail_blocklists_out_var="${2}" bl_ids="${3}"

	unset_vars "${ok_blocklists_out_var}" "${perm_fail_blocklists_out_var}" || exit 1

	for bl_id in ${bl_ids}
	do
		get_bl_params -f "${me}" "${bl_id}" conf_dirs dnsmasq_indexes final_extr_or_cat_stdout install_location install_path install_path_ram install_cnt
		get_bl_params "${bl_id}" curr_path skip_load_stop persist_mode new_single_instance conf_script_log_avail

		[ "${install_location}" = PERSIST ] && install_desc=persistent

		[ -n "${curr_path}" ] || KEEP_PERSIST=1 rm_blocklists "${bl_id}" # TODO: is this needed?

		[ -n "${skip_load_stop}" ] || stop_dnsmasq "${dnsmasq_indexes}" || exit 1

		if \
			reg_action -blue "Installing ${install_desc} blocklist file." && # TODO: desc from args?
			get_md5 install_md5 "${install_path}" &&
			[ -n "${new_single_instance}" ] ||
			# Make conf-script
			{
				for conf_dir in ${conf_dirs}
				do
					is_valid_dir "${conf_dir}" || return 1

					cat <<-EOF | ${SED_CMD} -E 's/\t+//g' > "${conf_dir}/abl-conf-script" || { reg_failure "Failed to create conf-script in directory '${conf_dir}'."; return 1; }
						conf-script=\
						${final_extr_or_cat_stdout} "${install_path}" && \
						printf '%s\n' "address=/${install_md5}-${ABL_TEST_DOM_BASE}/#" && \
						exit 0; \
						${conf_script_log_avail:+"${LOG_CMD} -t adblock-lean-conf-script -p user.err 'conf-script at '${conf_dir}/abl-conf-script' failed.';"} \
						exit 0
					EOF
				done
				:
			} &&
			restart_dnsmasq "${dnsmasq_indexes}" &&
			{
				CA_CHECK_DNS=1 check_active_blocklist "${bl_id}" "${install_md5}" "${new_single_instance}" ||
					{ reg_failure "Active blocklist check failed with ${install_desc} blocklist file."; false; }
			}
		then
			some_succeeded=1
			rm_bk "${bl_id}"
			add2list "${ok_blocklists_out_var}" "${bl_id}"
			set_bl_params "${bl_id}" \
				curr_path="${install_path}" \
				curr_location="${install_location}" \
				curr_single_instance="${new_single_instance}" \
				curr_md5="${install_md5}" \
				curr_cnt="${install_cnt}"
		else
			reg_failure "Failed to install blocklist '${bl_id}'"
			local keep_persist=1
			[ "${install_location}" = PERSIST ] && keep_persist=0
			KEEP_PERSIST=${keep_persist} do_stop "${bl_id}"
			[ "${abl_cmd}" = start ] &&
			[ "${install_location}" = PERSIST ] && [ "${persist_mode}" = manual ] || continue
			# fall back to RAM
			if [ -d "${install_path_ram%/*}" ]
			then
				set_bl_params "${bl_id}" install_location=RAM install_path="${install_path_ram}" || return 1
			else
				add2list "${perm_fail_blocklists_out_var}" "${bl_id}"
			fi

		fi
	done
	[ -n "${some_succeeded}" ]
}

# TODO: Parallelize domains lookup
test_url_domains()
{
	local list lists list_author url mirror all_urls='' list_type list_format dom IFS="${DEFAULT_IFS}"
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
		try_lookup_domain "${dom}" "127.0.0.1" 2 || # TODO: blocklist-specific NS
			{ reg_failure "Lookup of '${dom}' failed."; exit 1; }
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


### METADATA

# 1 (optional): blocklist IDs
unset_metadata()
{
	local meta_param bl_id \
		bl_ids="${*-"${BL_IDS}"}"

	for bl_id in ${bl_ids}
	do
		for meta_param in ${META_PARAMS:?}
		do
			unset "${meta_param}_${bl_id}"
		done
	done
}

# 1: path to the meta file
# 2: blocklist IDs to write
# 3: list of params
commit_metadata()
{
	try_commit_metadata "${@}" && return 0
	reg_failure "Failed to create or update the metadata file."
	return 1
}

try_commit_metadata()
{
	uci_tmp() { uci -c "${META_FILE%/*}" "${@}"; }
	uci_persist() { uci -c "${persist_dir}" "${@}"; }

	# shellcheck disable=SC2034
	local me=commit_metadata \
		IFS="${DEFAULT_IFS}" \
		param param_val uci_fail='' \
		bl_id \
		curr_location curr_path persist_dir persist_meta_file

	debug_msg "Creating metadata, blocklists: '${BL_IDS}'."

	rm -f "${META_FILE}"

	[ -n "${BL_IDS}" ] || return 0

	# Common metadata
	touch "${META_FILE}" || return 1
	for bl_id in ${BL_IDS}
	do
		# create/update section in meta file
		uci_tmp set "${META_FNAME}.${bl_id}=blocklist_id" || { uci_fail=1; break; }
		for param in ${META_PARAMS}
		do
			eval "param_val=\"\${${param}_${bl_id}}\""
			# TODO: remove?
			# [ -n "${param_val}" ] ||
			# 	{ reg_failure "${me}: metadata param ${param} has empty value for blocklist ${bl_id}."; uci_fail=1; break 2; }
			uci_tmp set "${META_FNAME}.${bl_id}.${param}"="${param_val}" || { uci_fail=1; break 2; }
		done
	done

	[ -z "${uci_fail}" ] &&
	uci_tmp commit "${META_FNAME}" ||
		{ uci_tmp revert "${META_FNAME}"; rm -f "${META_FILE}"; return 1; }

	# Persist metadata
	for bl_id in "${@}"
	do
		get_bl_params -f "${me}" "${bl_id}" curr_location curr_path curr_md5 curr_cnt || return 1

		[ "${curr_location}" = PERSIST ] || continue

		persist_dir="${curr_path%/*}"
		persist_meta_file="${persist_dir:?}/${META_FNAME_PERSIST}"
		uci_persist set "${META_FNAME_PERSIST}.${bl_id}=blocklist_id" &&
		uci_persist set "${META_FNAME_PERSIST}.${bl_id}.PATH=${curr_path}" &&
		uci_persist set "${META_FNAME_PERSIST}.${bl_id}.MD5=${curr_md5}" &&
		uci_persist set "${META_FNAME_PERSIST}.${bl_id}.CNT=${curr_cnt}" &&
		uci_persist commit "${META_FNAME_PERSIST}" && continue

		reg_failure "Failed to create/update persistent metadata file '${persist_meta_file}'."
		uci_persist revert "${META_FNAME_PERSIST}"
		rm -f "${persist_meta_file}"
	done

	:
}

# Reads the metadata file and assigns global vars:
#   IS_PAUSED_${inst} [PERSIST_]PATH_${inst} [PERSIST_]MD5_${inst} [PERSIST_]CNT_${inst}
#
# Values are only assigned for files which actually exist, and reflect last known state
#   (updated at the end of each adblock-lean run of start/stop/pause/resume)
#
# 0 (optional): '-persist'
# 1: path to the meta file
# 2: blocklist IDs

# shellcheck disable=SC2329
read_blocklist_metadata()
{
	append_err() { err_msgs=${err_msgs}${err_msgs:+"${_NL_}"}${1}; }

	populate_vars()
	{
		local \
			meta_params \
			meta_val \
			bl_md5 \
			curr_path curr_cnt curr_md5 \
			bl_id_pr="blocklist '${1}'"

		: "${meta_val}"

		debug_msg "Populating vars for ${bl_id_pr}."

		assert_valid_bl_id "${1}" "${me}"

		is_included "${seen_ids}" "${1}" &&
			append_err "Multiple entries for ${bl_id_pr} in ${sp_f_pr}."

		add2list seen_ids "${1}"

		meta_params="${META_PARAMS}"
		[ -n "${gbp_prefix}" ] && meta_params="${PERSIST_META_PARAMS}"

		for param in ${meta_params}
		do
			config_get "meta_val" "${1}" "${param}" # accept empty values
			eval "${gbp_prefix}${param}_${1}"='${meta_val}'
		done

		# check md5
		GBP_PREFIX="${gbp_prefix}" get_bl_params "${1}" curr_cnt curr_md5 curr_path
		[ -n "${curr_path}" ] || return 0

		get_md5 bl_md5 "${curr_path}" ||
			{ append_err "Failed to get MD5 sum of ${bl_id_pr} file at ${curr_path}."; return 1; }
		[ "${curr_md5}" = "${bl_md5}" ] ||
		{
			append_err "MD5 sum not matching in ${sp_f_pr} for ${bl_id_pr}, path '${curr_path}'. Metadata file has: '${curr_md5}', blocklist file has: '${bl_md5}'."
			return 1
		}

		# set persist params
		[ "${gbp_prefix}" = 'PERSIST_' ] &&
		{
			[ "${curr_path%/*}" = "${meta_file%/*}" ] ||
			{
				append_err "Persistent blocklist dir not matching in ${sp_f_pr} for ${bl_id_pr}. Metadata file has: '${curr_path%/*}', metadata is at: '${meta_file%/*}'."
				return 1
			}
			set_bl_params "${1}" curr_persist_md5="${curr_md5}" curr_persist_cnt="${curr_cnt}"
		}
		:
	}

	local gbp_prefix=
	[ "${1}" = '-persist' ] && { gbp_prefix=PERSIST_; shift; }
	: "${gbp_prefix}"

	local me=read_blocklist_metadata \
		param \
		IFS="${DEFAULT_IFS}" \
		rbm_rv=0 \
		err_msgs='' \
		seen_ids='' \
		missing_ids='' \
		meta_file="${1}" meta_ids="${2:-"${BL_IDS}"}" 

		local sp_f_pr="metadata file '${meta_file}'"

	debug_msg "${me} start, IDs ${meta_ids}"

	export META_PROCESSED=

	[ -n "${meta_ids}" ] || { reg_failure "${me}: no blocklist IDs found."; return 1; }

	# Reset global vars
	unset_metadata "${meta_ids}"

	[ -f "${meta_file}" ] ||
		{ debug_msg "${me}: can not find ${sp_f_pr}."; return 0; }

	UCI_CONFIG_DIR="${meta_file%/*}" config_load "${meta_file##*/}" ||
		{ reg_failure "${me}: failed to load ${sp_f_pr}."; return 1; }

	config_foreach populate_vars blocklist_id

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

	subtract_a_from_b "${seen_ids}" "${meta_ids}" missing_ids ||
		{ reg_failure "${me}: entries for blocklists '${missing_ids}' are missing from ${sp_f_pr}."; rbm_rv=1; }

	META_PROCESSED=1

	return ${rbm_rv}
}

: