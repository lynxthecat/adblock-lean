#!/bin/sh
# shellcheck disable=SC3043,SC3003,SC3001,SC3020,SC3044,SC2016,SC3057,SC3019,SC2018,SC2019,SC3060,SC3045
# shellcheck source=/dev/null

# silence shellcheck warnings
: "${blue:=}" "${lblue:=}" "${purple:=}" "${green:=}" "${red:=}" "${yellow:=}" "${orange:=}" "${n_c:=}"
: "${luci_cron_job_creation_failed}" "${luci_pkgs_install_failed}" "${luci_tarball_url}"

### GLOBAL VARIABLES
ABL_CRON_SVC_PATH=/etc/init.d/cron
ALL_PRESETS="mini small medium large huge"

# PRESETS
# lists_cnt - urls count, cnt - target elements count, mem - intended device memory in MB
# shellcheck disable=SC2034
{
	mini_lists="hagezi:pro.mini" mini_lists_cnt=1 mini_cnt=85000 mini_mem=64
	small_lists="hagezi:pro" small_lists_cnt=1 small_cnt=250000 small_mem=128
	medium_lists="hagezi:pro hagezi:tif.mini" medium_lists_cnt=2 medium_cnt=350000 medium_mem=256
	large_lists="hagezi:pro hagezi:tif.medium" large_lists_cnt=2 large_cnt=1200000 large_mem=512
	huge_lists="hagezi:pro hagezi:tif" huge_lists_cnt=2 huge_cnt=2400000 huge_mem=1024
}

### UTILITY FUNCTIONS

tolower()
{
	local tl_str
	case "${2}" in
		*[A-Z]*) tl_str="$(printf '%s' "${2}" | tr 'A-Z' 'a-z' )" ;;
		*) tl_str="${2}"
	esac
	export -n "${1}=${tl_str}"
}

try_mv()
{
	local mv_q=
	[ "${1}" = '-q' ] && { mv_q=1; shift; }
	[ -n "${1}" ] && [ -n "${2}" ] || bad_args "try_mv" "${@}"
	mv -f "${1}" "${2}" && return 0

	[ -n "${mv_q}" ] || reg_fail "Failed to move '${1}' to '${2}'."
	return 1
}

# 1 - var for output
# 2 - input lines
cnt_lines()
{
	local line cnt=0 IFS="${_NL_}"
	for line in ${2}; do
		case "${line}" in
			'') ;;
			*) cnt=$((cnt+1))
		esac
	done
	export -n "${1}=${cnt}"
}

get_file_size() { du -b "$1" | ${AWK_CMD} '{print $1}'; }

get_pad()
{
	local spaces='                                          ' \
		pad_len=$(( ${3} - ${#2} ))
	[ "$pad_len" -lt 0 ] && pad_len=0
	export -n "${1}=${spaces:1:${pad_len}}"
}

# converts unsigned integer to [xB|xKiB|xMiB|xGiB|xTiB]
# if result is not an integer, outputs up to 2 digits after decimal point
# 1 - output var name
# 2 - int
# 3 - (optional) '-p' to add padding
bytes2human()
{
	unset_vars "${1}"
	local i="${2:-0}" s=0 d=0 m=1024 fp S bh_res pad align
	[ "${3}" = '-p' ] && align=1
	is_uint "${i}" || { reg_fail "bytes2human: invalid uint '${i}'."; return 1; }
	for S in B KiB MiB GiB TiB
	do
		[ $((i > m && s < 4)) = 0 ] && break
		d=${i} i=$((i/m)) s=$((s+1))
	done
	d=$((d % m * 100 / m))
	case ${d} in
		0)
			if [ -n "${align}" ]
			then
				i="${i}.00"
				[ "${S}" = B ] && S="  B"
			fi
			bh_res="${i} ${S}" ;;
		[1-9]) fp="02" ;;
		*0)
			if [ -n "${align}" ]; then
				fp="02"
			else
				d=${d%0} fp="01"
			fi
	esac
	: "${bh_res:="$(printf "%s.%${fp}d %s\n" "${i}" "${d}" "${S}")"}"
	[ -n "${align}" ] && get_pad pad "${bh_res}" 10
	export -n "${1}=${pad}${bh_res}"
}

# 1 - var name for output
# 2 - uint
int2human()
{
	unset_vars "${1}"
	is_uint "${2}" || { reg_fail "int2human: invalid uint '${2}'."; return 1; }

	local in_num="${2#"${2%%[!0]*}"}" out_num=
	while :
	do
		case "${in_num}" in
			????*)
				out_num=",${in_num: -3}${out_num}"
				in_num="${in_num%???}" ;;
			*) break
		esac
	done
	export -n "${1}=${in_num:-0}${out_num}"
}

get_md5()
{
	unset_vars "${1}"
	local IFS="${DEFAULT_IFS}" g_md5
	g_md5="$(${MD5_CMD} "${2}")" &&
	g_md5="${g_md5%% *}" &&
	is_hex_lc "${g_md5}" &&
	export -n "${1}=${g_md5}" && return 0

	reg_fail "Failed to get MD5 sum for file '${2}'"
	return 1
}


### SETUP AND CONFIG MANAGEMENT

hp_scr_pr="the adblock-lean hotplug script"

mk_hotplug_script()
{
	try_mk_hotplug_script "${@}" && return 0
	reg_fail "Failed to activate ${hp_scr_pr}."
	disable_hotplug_script
	return 1
}

try_mk_hotplug_script()
{
	check_hp_script()
	{
		local installed_md5 dist_md5
		[ -f "${1}" ] &&
		get_md5 installed_md5 "${1}" &&
		get_md5 dist_md5 "${ABL_HOTPLUG_PATH_SRC}" &&
		[ "${installed_md5}" = "${dist_md5}" ]
	}

	local me=mk_hotplug_script IFS="${DEFAULT_IFS}" \
		hp_dev df_lines_cnt=0 \
		hp_fail_msg="Can not create or activate ${hp_scr_pr}" \
		bl_path="${1}"

	[ "${PERSIST_HOTPLUG_SCRIPT}" = 1 ] ||
	{
		reg_msg "" "Option PERSIST_HOTPLUG_SCRIPT is set to '${PERSIST_HOTPLUG_SCRIPT}'. Skipping hotplug script creation."
		disable_hotplug_script
		return 0
	}

	assert_set "F_${me}" ABL_HOTPLUG_REG_FILE ABL_HOTPLUG_PATH_ENABLED ABL_HOTPLUG_PATH_DISABLED bl_path || return 1

	hp_dev="$(${DF_CMD} "${bl_path}" | ${SED_CMD} -n '/^\s*Filesystem\s/n;s/^\s*//;s/\s.*//;p')" &&
	cnt_lines df_lines_cnt "${hp_dev}" &&
	[ "${df_lines_cnt}" = 1 ] ||
	{
		reg_fail "Unexpected or empty 'df' utility output '${hp_dev}' when checking device name for hotplug script. ${hp_fail_msg}."
		return 1
	}

	case "${hp_dev}" in /dev/root|tmpfs|/dev/loop*|overlayfs)
		reg_msg "" "Persistent blockset is on device '${hp_dev}'. Hotplug script not required."
		disable_hotplug_script
		return 0
	esac

	printf '%s\n' "${hp_dev#"/dev/"}" > "${ABL_HOTPLUG_REG_FILE}" &&

	if [ -f "${ABL_HOTPLUG_PATH_DISABLED}" ]
	then
		log_msg -blue "" "Activating ${hp_scr_pr}"
		try_mv "${ABL_HOTPLUG_PATH_DISABLED}" "${ABL_HOTPLUG_PATH_ENABLED}" && return 0
	fi

	if check_hp_script "${ABL_HOTPLUG_PATH_ENABLED}"
	then
		debug_msg "${hp_scr_pr} already exists"
		rm -f "${ABL_HOTPLUG_PATH_DISABLED}"
		return 0
	elif check_hp_script "${ABL_HOTPLUG_PATH_DISABLED}"
	then
		log_msg -blue "" "Activating ${hp_scr_pr}"
		try_mv "${ABL_HOTPLUG_PATH_DISABLED}" "${ABL_HOTPLUG_PATH_ENABLED}" && return 0
	else
		log_msg -blue "" "Installing ${hp_scr_pr}."
		rm -f "${ABL_HOTPLUG_PATH_DISABLED}"
		try_mkdir -p "${ABL_HOTPLUG_PATH_ENABLED%/*}" &&
		{
			cp "${ABL_HOTPLUG_PATH_SRC}" "${ABL_HOTPLUG_PATH_ENABLED}" || { reg_fail "Failed to copy ${hp_scr_pr} to ${ABL_HOTPLUG_PATH_ENABLED}."; false; }
		} &&
			return 0
	fi

	return 1
}

# optional: '-deactivate' to only remove the hotplug reg file
# shellcheck disable=SC2120
disable_hotplug_script()
{
	local deactiv_req=1 disable_req=1 hotpl_act="Disabling"
	[ "${1}" = "-deactivate" ] && { disable_req='' hotpl_act="Deactivating"; shift; }

	assert_set F_disable_hotplug_script ABL_HOTPLUG_REG_FILE ABL_HOTPLUG_PATH_ENABLED ABL_HOTPLUG_PATH_DISABLED || return 1

	[ -f "${ABL_HOTPLUG_PATH_ENABLED}" ] || disable_req=
	[ -f "${ABL_HOTPLUG_REG_FILE}" ] || deactiv_req=

	if [ -n "${disable_req}" ] || [ -n "${deactiv_req}" ]
	then
		reg_msg -blue "" "${hotpl_act} ${hp_scr_pr}."
	else
		debug_msg "Hotplug script disable or deactivate not required."
		return 0
	fi

	[ -n "${deactiv_req}" ] && rm -f "${ABL_HOTPLUG_REG_FILE}"

	[ -z "${disable_req}" ] ||
		try_mv "${ABL_HOTPLUG_PATH_ENABLED}" "${ABL_HOTPLUG_PATH_DISABLED}" && return 0

	reg_fail "" "Failed to disable ${hp_scr_pr}. Deleting it."
	rm -f "${ABL_HOTPLUG_PATH_ENABLED}" "${ABL_HOTPLUG_PATH_DISABLED}"

	return 1
}

do_create_addnmounts()
{
	process_addnm()
	{
		local missing_addnm instance \
			instances="${1}" req_addnm="${2}"
		check_addnmounts missing_addnm "${instances}" "${req_addnm}" || return 1
		for instance in ${instances}
		do
			add2list "req_addnm_${instance}" "${req_addnm}" "${_NL_}"
		done
		[ -z "${missing_addnm}" ] || is_included "${missing_addnm}" "${all_missing_addnm}" "${_NL_}" && return 0
		add2list all_missing_addnm "${missing_addnm}" "${_NL_}"
		abl_append all_missing_addnm_pr "${lblue}${missing_addnm}${n_c} (required for ${3})" "${_NL_}"
	}

	local me=create_addnmounts \
		IFS="${DEFAULT_IFS}" \
		REPLY \
		conf_dirs \
		instance dmsq_instances all_dmsq_instances \
		req_addnm_instance \
		\
		set_id \
		bl_full_fname \
		path_ram \
		ignore_paths \
		ram_addnm cat_addnm \
		\
		persist_mode \
		persist_dir \
		\
		all_missing_addnm  all_missing_addnm_pr \
		cra_compr_util_path cra_compr_ext \
		add_list_failed \
		path

	# reset req_addnm_${instance} vars, compile list of instances
	for set_id in ${SET_IDS:?}
	do
		get_params -f "${me}" "${set_id}" dmsq_instances || return 1
		for instance in ${dmsq_instances}
		do
			local "req_addnm_${instance}=" &&
			add2list all_dmsq_instances "${instance}"
		done
	done

	## Check addmounts
	for set_id in ${SET_IDS:?}
	do
		path_ram='' ignore_paths=''
		get_params -f "${me}" "${set_id}" dmsq_instances conf_dirs &&
		get_params "${set_id}" persist_mode persist_dir &&
		get_compr_util_spec cra_compr_util_path cra_compr_ext "${compression_util:?}" || return 1

		# Logger
		process_addnm "${dmsq_instances}" "${LOG_CMD}" "logging failed attempts by dnsmasq to load the blockset" || return 1

		bl_full_fname=${BLOCKSET_BASE_FNAME:?}-${set_id}${cra_compr_ext}

		# Compression
		if [ -n "${cra_compr_ext}" ]
		then
			path_ram=${ABL_RUN_DIR:?}/${bl_full_fname}
			process_addnm "${dmsq_instances}" "${cra_compr_util_path%% *}${_NL_}${path_ram}" "final blockset compression" || return 1
		fi

		# Multiple dnsmasq instances
		case "${dmsq_instances}" in
			*[0-9a-zA-Z_]*[" 	"]*[0-9a-zA-Z_]*)
				path_ram=${ABL_RUN_DIR:?}/${bl_full_fname}
				process_addnm "${dmsq_instances}" "${path_ram}" "final blockset compression or blockset loading by multiple dnsmasq instances" || return 1 ;;
			*)
				first_conf_dir="${conf_dirs%% *}"
				is_valid_dir "${first_conf_dir}" || return 1
				ignore_paths="${first_conf_dir}/${bl_full_fname}"

				: "${path_ram:="${first_conf_dir}/${bl_full_fname}"}" ;;
		esac

		assert_set "F_${me}" path_ram || return 1

		# Persistent blockset
		case "${persist_mode}" in
			manual|managed) : ;;
			*) false ;;
		esac &&
		check_persist_dir "${set_id}" &&
		{
			ram_addnm='' cat_addnm=''
			is_included "${path_ram}" "${ignore_paths}" "${_NL_}" ||
				ram_addnm="${_NL_}${path_ram}"
			[ -n "${cra_compr_ext}" ] || cat_addnm="${_NL_}${CAT_CMD}"
			process_addnm "${dmsq_instances}" "${persist_dir}${ram_addnm}${cat_addnm}" "persistent blockset functionality" || return 1
		}
	done

	[ -z "${all_missing_addnm}" ] &&
	{
		reg_msg -green "All required dnsmasq addnmount entries already exist."
		return 0
	}

	## Dialog
	log_msg "" "${yellow}Detected missing addnmount entries in /etc/config/dhcp for paths:${n_c}${_NL_}${all_missing_addnm_pr}"
	if [ "${DO_DIALOGS}" = 1 ] && [ -z "${APPROVE_UPD_CHANGES}" ]
	then
		print_msg -blue "" "Create missing addnmount entries automatically? (y|n)"
		pick_opt "y|n"
	else
		log_msg -blue "Automatically creating missing addnmount entries."
		REPLY=y
	fi
	[ "${REPLY}" = y ] || return 0

	del_addnmounts "${all_dmsq_instances}"
	case ${?} in 0|3) : ;; *) false; esac &&

	## Create addnmounts
	for instance in ${all_dmsq_instances}
	do
		eval "req_addnm_instance=\"\${req_addnm_${instance}}\""
		[ -n "${req_addnm_instance}" ] || continue

		log_msg "" "Creating addnmount entries for dnsmasq instance '${instance}':${_NL_}${blue}${req_addnm_instance}${n_c}"
		IFS="${_NL_}"
		for path in ${req_addnm_instance}
		do
			IFS="${DEFAULT_IFS}"
			uci add_list "dhcp.${instance}.addnmount=${path}" ||
				{ add_list_failed=1; break 2; }
		done
		IFS="${DEFAULT_IFS}"
	done &&
	[ -z "${add_list_failed}" ] &&

	uci commit dhcp ||
	{
		uci revert dhcp
		reg_fail "Failed to create or change addnmount entries."
		return 1
	}

	unset C_PROCESSED
	parse_dmsq_cfg &&
	check_dmsq_instances || return 1

	:
}

get_pkg_name()
{
	unset_vars "${1}"
	local _name
	case "${2}" in
		awk) _name="gawk" ;;
		sed) _name="sed" ;;
		sort) _name="coreutils-sort"
	esac
	export -n "${1}=${_name}"
}


# Error codes:
# 1 - general error
# 3 - set_all_env failed
# 4 - service enable failed
# 5 - creating addnmount entry failed
do_setup()
{
	# 1 - '|' - separated package names
	get_installed_pkgs()
	{
		local all_installed_pkgs pkgs_list_cmd filter_cmd
		case "${PKG_MANAGER}" in
			apk)
				pkgs_list_cmd="apk list -I"
				filter_cmd="$SED_CMD -En '/^[ \t]*($1)-[0-9]/{s/^[ \t]+//;s/[ \t].*//;p;}'"
				;;
			opkg)
				pkgs_list_cmd="opkg list-installed"
				filter_cmd="grep -E '^[ \t]*($1)([ \t]|$)'"
				;;
			*)
				reg_fail "Unexpected package manager '${PKG_MANAGER}'."
				return 1
		esac

		all_installed_pkgs="$(${pkgs_list_cmd})" && [ -n "${all_installed_pkgs}" ] || {
			reg_fail "Failed to check installed packages with package manager '$PKG_MANAGER'."
			return 1
		}
		printf '%s\n' "$all_installed_pkgs" | eval "${filter_cmd}"

		:
	}

	install_packages()
	{
		# determine if there are missing GNU utils
		local recomm_pkgs_regex="${RECOMMENDED_PKGS//" "/|}"
		local pkgs2install missing_packages missing_utils missing_utils_print util pkg_name \
			installed_pkgs util_size_B util_size_human utils_size_B=0 utils_size_human awk_size_B sort_size_B sed_size_B \
			free_space_human free_space_B free_space_KB mount_point

		: "${awk_size_B:=1048576}" "${sort_size_B:=122880}" "${sed_size_B:=153600}"

		installed_pkgs="$(get_installed_pkgs "${recomm_pkgs_regex}")" || return 1

		echo > "${MSGS_DEST}"
		for util in ${RECOMMENDED_UTILS}
		do
			case "${installed_pkgs}" in
				*"${util}"*) reg_msg -green "GNU ${util} is already installed." ;;
				*)
					get_pkg_name pkg_name "${util}" || return 1
					add2list missing_utils "${util}"
					add2list missing_packages "${orange}${pkg_name}${n_c}" ", "
					abl_append missing_utils_print "${lblue}GNU ${util}${n_c}" ", "
			esac
		done

		# make a list of GNU utils to install
		if [ -n "${missing_utils}" ]
		then
			free_space_KB="$(${DF_CMD} -k /usr/ | tail -n1 | ${SED_CMD} -E 's/^[ \t]*([^ \t]+[ \t]+){3}//;s/[ \t]+.*//')"
			mount_point="$(${DF_CMD} -k /usr/ | tail -n1 | ${SED_CMD} -E 's/.*[ \t]+//')"

			is_uint "${free_space_KB}" || { reg_fail "Failed to check available free space."; return 1; }

			free_space_B=$((free_space_KB*1024))

			if [ "${DO_DIALOGS}" = 1 ]
			then
				print_msg "" "For improved performance while processing the lists, it is recommended to install ${missing_utils_print}." \
					"Corresponding packages are: ${missing_packages}."
				[ -n "${free_space_B}" ] &&
				{
					bytes2human free_space_human "${free_space_B}" || return 1
					print_msg "" "Available free space at mount point '${mount_point}': ${yellow}${free_space_human}${n_c}." ""
				}
			fi

			for util in ${missing_utils}
			do
				REPLY=n
				if [ "${DO_DIALOGS}" = 1 ]
				then
					set_int "util_size_B = ${util}_size_B"
					bytes2human util_size_human "${util_size_B}" || return 1
					print_msg "Would you like to install ${lblue}GNU ${util}${n_c} automatically? Installed size: ${yellow}${util_size_human}${n_c}. (y|n)"
					pick_opt "y|n"
				elif [ -n "${luci_install_packages}" ]
				then
					REPLY=y
				fi

				if [ "${REPLY}" = y ]
				then
					get_pkg_name pkg_name "${util}" || return 1
					pkgs2install="${pkgs2install}${pkg_name} "
					utils_size_B=$((utils_size_B+util_size_B))
				fi
			done
		fi

		# install GNU utils
		if [ -n "${pkgs2install}" ]
		then
			REPLY=n
			if [ "${DO_DIALOGS}" = 1 ]
			then
				bytes2human utils_size_human "${utils_size_B}" || return 1
				print_msg "" "Selected packages: ${lblue}${pkgs2install% }${n_c}" \
					"Total installed size: ${yellow}${utils_size_human}${n_c}." \
					"Proceed with packages installation? (y|n)"
				pick_opt "y|n"
			elif [ -n "${luci_install_packages}" ]
			then
				REPLY=y
			fi

			if [ "${REPLY}" = y ]
			then
				if [ -z "${free_space_B}" ] || [ -z "${utils_size_B}" ] || [ "${free_space_B}" -gt ${utils_size_B} ]
				then
					echo > "${MSGS_DEST}"
					$PKG_MANAGER update && $PKG_INSTALL_CMD ${pkgs2install% } && return 0
					reg_fail "Failed to automatically install packages. You can install them manually later."
					return 1
				else
					reg_fail "Not enough free space at mount point '${mount_point}'."
					print_msg "Free up some space, then you can manually install the packages later by issuing the command:" \
						"$PKG_MANAGER update; $PKG_INSTALL_CMD ${pkgs2install% }"
					return 1
				fi
			fi
		else
			return 0
		fi
		:
	}

	# shellcheck disable=SC2329
	add_found_cfg()
	{
		local cfg_id
		split_path _ cfg_id _  "${1}"
		cfg_id="${cfg_id#"blockset-"}"
		is_alphanum "${cfg_id}" ||
		{
			reg_fail "Invalid blockset name '${cfg_id}' in file '${1}'. Only English letters, numbers and underlines are allowed. Deleting the file."
			rm -f "${1}"
			return 0
		}
		abl_append bl_cfgs_found "${1}" "${_NL_}"
	}


	local CUR_CMD=setup

	[ -f "${ABL_SERVICE_PATH}" ] || { reg_fail "adblock-lean service file doesn't exist at ${ABL_SERVICE_PATH}."; return 1; }

	# make the script executable
	if [ ! -x "${ABL_SERVICE_PATH}" ]
	then
		reg_msg "" "Making ${ABL_SERVICE_PATH} executable."
		chmod +x "${ABL_SERVICE_PATH}" || { reg_fail "Failed to make '${ABL_SERVICE_PATH}' executable."; return 1; }
	else
		reg_msg -green "" "${ABL_SERVICE_PATH} is already executable."
	fi

	REPLY=n

	if [ -s "${GLOBAL_CFG_FILE}" ]
	then
		if [ "${DO_DIALOGS}" = 1 ]
		then
			print_msg "" "Existing global config file found." "Generate [${lblue}n${n_c}]ew config or use [${lblue}e${n_c}]xisting config? (n|e)"
			pick_opt 'n|e'
		elif [ -n "${luci_use_old_config}" ]
		then
			REPLY=e
		fi
	fi

	if [ "${REPLY}" = n ]
	then
		# generate config
		gen_global_config || return 2
	fi

	FF_EXEC=add_found_cfg find_files _ "${ABL_CFG_DIR:?}/blockset-" "*" ".conf"
	[ ${?} = 1 ] && return 1

	REPLY=
	if [ -n "${bl_cfgs_found}" ]
	then
		if [ "${DO_DIALOGS}" = 1 ]
		then
			print_msg "" "Found existing blockset config files:${_NL_}${bl_cfgs_found}." \
				"${_NL_}[k]eep existing blockset config files or remove them and create a [n]ew one, or [a]bort? (k|n|a)"
			pick_opt 'k|n|a'
			[ "${REPLY}" = a ] && return 0
		else
			REPLY=k
		fi
	else
		REPLY=n
	fi

	if [ "${REPLY}" = n ]
	then
		FORCE_STOP_ALL=1 do_stop
		# Remove and forget old configs
		rm -f "${META_FILE}"
		local set_id
		for set_id in ${SET_IDS}
		do
			unset "BL_ENV_SET_${set_id}"
		done
		unset_param_vars "${SET_IDS}"
		unset SET_IDS SKIP_SET_ENV GLOBAL_ENV_SET CONFIG_LOADED
		for cfg_path in ${bl_cfgs_found}
		do
			rm -f "${cfg_path}"
		done

		# generate blockset config
		do_gen_blockset_config || return 2
	fi

	load_config &&
	set_all_env || return 3

	# enable the service, update the cron job
	if rc_enabled
	then
		upd_cron_job && luci_cron_job_creation_failed=
	elif enable
	then
		luci_cron_job_creation_failed=
	else
		local rv=${?}
		[ "${rv}" = 6 ] || return ${rv}
	fi

	detect_pkg_manager
	case "${PKG_MANAGER}" in
		apk|opkg)
			install_packages && luci_pkgs_install_failed=
			detect_main_utils -f || return 1 ;;
		*)
			reg_msg -yellow "" "Can not automatically check and install recommended packages (${RECOMMENDED_PKGS})." \
				"Consider to check for their presence and install if needed."
	esac

	# create addnmount entries - enables blockset compression and adblocking on multiple instances
	do_create_addnmounts || return 1

	if [ "${DO_DIALOGS}" = 1 ]
	then
		print_msg "" "${purple}Setup is complete.${n_c}" "" "${lblue}Start adblock-lean now?${n_c} (y|n)"
		pick_opt "y|n"
		[ "${REPLY}" != y ] && return 0
		echo > "${MSGS_DEST}"
		start
	fi
	:
}

# Env vars:
#  GP_PRINT_DESC: print description
#  GP_PRINT_VALS: print values
# Input:
#  1: preset name (mini|small|medium|large|huge)
# Output via vars:
#  2: entries count
#  3: lists count
#  4: limit coeff
#  5: mem
#  6: list identifiers
#  7: max part size
#  8: max blockset size
#  9: min line count
get_preset()
{
	local gp_mem gp_lists_cnt gp_entr_cnt gp_lim_coeff gp_lists gp_entr_cnt_human gp_max_part_size gp_max_set_size gp_min_entries

	eval "gp_mem=\"\${${1}_mem}\"
		gp_lists_cnt=\"\${${1}_lists_cnt}\"
		gp_entr_cnt=\"\${${1}_cnt}\"
		gp_lim_coeff=\"\${${1}_coeff}\"
		gp_lists=\"\${${1}_lists}\""

	: "${gp_lim_coeff:=1}"

	assert_set F_get_preset gp_mem gp_lists_cnt gp_entr_cnt gp_lim_coeff gp_lists || return 1

	unset_vars "${2}" "${3}" "${4}" "${5}" "${6}" "${7}" "${8}" "${9}"

	do_calculate_limits "${gp_entr_cnt}" "${gp_lists_cnt}" "${gp_lim_coeff}" gp_min_entries gp_max_set_size gp_max_part_size || return 1

	[ -n "${GP_PRINT_DESC}" ] && print_msg "" "${purple}${1}${n_c}: recommended for devices with ${gp_mem} MB of memory."

	[ -n "${GP_PRINT_VALS}" ] &&
	{
		int2human gp_entr_cnt_human "${gp_entr_cnt}" || return 1
		print_msg "${blue}Elements count:${n_c} ~${gp_entr_cnt_human}" \
			"${blue}raw_block_lists${n_c}=\"${gp_lists}\"" \
			"${blue}max_part_size_KB${n_c}=\"${gp_max_part_size}\"" \
			"${blue}max_blockset_size_KB${n_c}=\"${gp_max_set_size}\"" \
			"${blue}min_blockset_entries${n_c}=\"${gp_min_entries}\""
	}

	export -n \
		"${2:-_}=${gp_entr_cnt}" \
		"${3:-_}=${gp_lists_cnt}" \
		"${4:-_}=${gp_lim_coeff}" \
		"${5:-_}=${gp_mem}" \
		"${6:-_}=${gp_lists}" \
		"${7:-_}=${gp_max_part_size}" \
		"${8:-_}=${gp_max_set_size}" \
		"${9:-_}=${gp_min_entries}" || return 1
	:
}

# Env vars:
#  CL_PRINT: print results
#  CL_INTERACTIVE: use dialogs if needed
# Input:
#  1: target entries count
#  2: lists count
#  3: limit coeff
# Output vars:
#  4: min lines
#  5: max blockset size
#  6: max part size
do_calculate_limits()
{
	# keeps first two digits, replaces others with 0's
	# 1 - var for I/O
	reasonable_round()
	{
		local input factor neg me=reasonable_round
		set_int "input = ${1}"
		case "${input}" in -*) neg='-' input="${input#-}"; esac
		input="${input#"${input%%[!0]*}"}"
		: "${input:=0}"
		case "${input}" in
			*[!0-9]*) reg_fail "${me}: invalid input '${input}'."; return 1 ;;
			?|??) return 0 ;;
			????????????*) reg_fail "${me}: input '${input}' too large."; return 1 ;;
			*)
				factor=$(( 10**(${#input}-2) ))
				export -n "${1}=${neg}$(( (input/factor) * factor ))"
		esac
		:
	}

	local me=calculate_limits lists_cnt tgt_entries_cnt tgt_entries_cnt_human lim_coeff final_entry_size_B source_entry_size_B \
		cl_min_entries cl_max_set_size_kb cl_max_part_size_kb \
		tgt_entries_cnt="${1}" lists_cnt="${2}" lim_coeff="${3:-1}"

	unset_vars "${4}" "${5}" "${6}"

	[ -z "${tgt_entries_cnt}" ] && [ -n "${CL_INTERACTIVE}" ] &&
	while :
	do
		print_msg "Enter target entries count for the final blockset:"
		read -r tgt_entries_cnt
		[ "${tgt_entries_cnt}" -gt 0 ] || { print_msg "Invalid input '${tgt_entries_cnt}'. Please enter a number."; continue; }
		break
	done

	[ -z "${lists_cnt}" ] && [ -n "${CL_INTERACTIVE}" ] &&
	while :
	do
		print_msg "How many URLs are used?"
		read -r lists_cnt
		[ "${lists_cnt}" -gt 0 ] || { print_msg "Invalid input '${lists_cnt}'. Please enter a number."; continue; }
		break
	done

	[ "${tgt_entries_cnt}" -gt 0 ] || { reg_fail "${me}: Invalid entries count '${tgt_entries_cnt}'."; return 1; }
	[ "${lists_cnt}" -gt 0 ] || { reg_fail "${me}: Invalid URLs count '${lists_cnt}'."; return 1; }

	# Default values calculation:
	# Values are rounded down to reasonable degree

	final_entry_size_B=20 # assumption
	source_entry_size_B=20 # assumption for raw domains format - TODO: distinguish from hosts format

	# tgt_entries_cnt / 3.5
	cl_min_entries=$((tgt_entries_cnt*10/35))
	reasonable_round cl_min_entries || return 1

	# (tgt_entries_cnt * final_entry_size_B * lim_coeff * 1.25)/1024
	cl_max_set_size_kb=$(( (tgt_entries_cnt*final_entry_size_B*lim_coeff*125)/(1024*100) + 1 ))
	reasonable_round cl_max_set_size_kb || return 1

	if [ "${lists_cnt}" -eq 1 ]
	then
		cl_max_part_size_kb=${cl_max_set_size_kb}
	else
		# (tgt_entries_cnt * source_entry_size_B * lim_coeff * 1.03)/1024
		cl_max_part_size_kb=$(( (tgt_entries_cnt*source_entry_size_B*lim_coeff*103)/(1024*100) + 1 ))
		reasonable_round cl_max_part_size_kb || return 1
	fi

	[ -n "${CL_PRINT}" ] &&
	{
		int2human tgt_entries_cnt_human "${tgt_entries_cnt}" || return 1
		local lists_pr=lists
		[ "${lists_cnt}" = 1 ] && lists_pr=list
		print_msg "" "Recommended values for ${lists_cnt} ${lists_pr} with ${tgt_entries_cnt_human} total entries:" \
			"${blue}max_part_size_KB${n_c}=\"${cl_max_part_size_kb}\"" \
			"${blue}max_blockset_size_KB${n_c}=\"${cl_max_set_size_kb}\"" \
			"${blue}min_blockset_entries${n_c}=\"${cl_min_entries}\""
	}

	export -n "${4:-_}=${cl_min_entries}" "${5:-_}=${cl_max_set_size_kb}" "${6:-_}=${cl_max_part_size_kb}" || return 1
	:
}

print_def_cfg()
{
	# follow each default option with '@' and a pre-defined type: string, uint, uint_list
	# or custom optional values, examples: opt1, opt1|opt2, ''|opt1|opt2

	local cfg_type="${1}"
	shift
	case "${cfg_type}" in
		global) print_def_cfg_global "${@}" ;;
		bl) print_def_cfg_blockset "${@}" ;;
		*) bad_args print_def_cfg "${cfg_type}" "${@}" ;;
	esac
}

# -i <blockset_ID>
# (optional) -d to print with allowed value types (otherwise print without)
# (optional) -p to print with values from preset
# (optional) -n to print with dmsq_instances
# (optional) -c to print with dmsq_conf_dirs
print_def_cfg_blockset()
{
	local me=print_def_cfg_blockset \
		preset print_types dmsq_instances conf_dirs \
		pdc_lists pdc_max_part_size pdc_max_set_size pdc_min_entries \
		OPTIND opt set_id

	while getopts ":i:n:c:p:d" opt; do
		case "${opt}" in
			i) set_id=$OPTARG ;;
			n) dmsq_instances=$OPTARG ;;
			c) conf_dirs=$OPTARG ;;
			p) preset=$OPTARG ;;
			d) print_types=1 ;;
			*) bad_args "${me}" "${@}" ;;
		esac
	done

	[ -n "${set_id}" ] || bad_args "${me}" "${@}"

	: "${preset:=small}"
	is_included "${preset}" "${ALL_PRESETS:?}" || { reg_fail "${me}: invalid preset '${preset}'."; return 1; }

	get_preset "${preset}" _ _ _ _ pdc_lists pdc_max_part_size pdc_max_set_size pdc_min_entries &&
	assert_set "F_${me}" pdc_lists pdc_max_set_size pdc_min_entries || return 1

	cat <<-EOT | if [ -n "${print_types}" ]; then cat; else ${SED_CMD} 's/[ \t]*@.*//'; fi

	# Blockset-specific configuration options
	# config_format=${CONFIG_FORMAT:?}
	#
	# values must be enclosed in double-quotes
	# custom comments are not preserved after automatic config update

	# Whitelist mode: only domains (and their subdomains) included in the allowlist(s) are allowed, all other domains are blocked
	# In this mode, if blocklists are used in addition to allowlists, subdomains included in the blocklists will be blocked,
	# including subdomains of allowed domains
	whitelist_mode="0" @ 0|1

	# One or more *raw domain* format [blocklist]/[ipv4 blocklist]/[allowlist] URLs and/or short list identifiers separated by spaces
	# Short list identifiers have the form of [hagezi|oisd]:[list_name]. Examples: hagezi:tif.mini, oisd:big
	raw_block_lists="${pdc_lists}" @ string
	raw_allow_lists="" @ string
	raw_ipv4_block_lists="" @ string

	# One or more *hosts* format blocklist URLs and/or short list identifiers separated by spaces
	hosts_block_lists="" @ string

	# Path to optional local *raw domain* allowlist/blocklist files in the form:
	# site1.com
	# site2.com
	local_allowlist_path="${ABL_CFG_DIR}/local-allowlist-${set_id}" @ string
	local_blocklist_path="${ABL_CFG_DIR}/local-blocklist-${set_id}" @ string


	# Path to optional local *ipv4* blocklist files in the form:
	# <ipv4_address>
	# <ipv4_address>
	local_ipv4_blocklist_path="${ABL_CFG_DIR}/local-ipv4-blocklist-${set_id}" @ string

	# Governs whether and how persistent blockset is used
	# 'disable' (default): persistent blockset will not be used. The blockset file will be stored on the ramdisk.
	# 'manual': directory specified in option 'persist_blockset_dir' will be checked for file named '${BLOCKSET_BASE_FNAME:?}-${set_id}' (with or without extension '.gz' or '.zst') -
	#   if found, that blockset will be loaded at boot (rather than downloading, processing and loading a new blockset)
	#   but adblock-lean will not create or update that file (useful to prevent flash wear, e.g. when the persistent blockset is stored on the built-in flash of a router).
	#   If not found, adblock-lean will act as if mode is 'disable'.
	# 'managed': adblock-lean will use the directory specified in option 'persist_blockset_dir' to store and update the blockset file
	#   and no additional blockset will be stored on the ramdisk.
	#   If the directory is inaccessible, adblock-lean will fall back to using the ramdisk.
	persist_blockset_mode="disable" @ disable|manual|managed

	# Optional path to directory on non-volatile storage device where persistent blockset should be stored
	persist_blockset_dir="" @ string

	# Test domains are automatically querried after loading the blockset into dnsmasq,
	# in order to verify that the blockset didn't break DNS resolution
	# If query for any of the test domains fails, previous blockset is restored from backup
	# If backup doesn't exist, the blockset is removed and adblock-lean is stopped
	# Leaving this empty will disable verification
	test_domains="google.com microsoft.com amazon.com" @ string

	# Maximum size of any downloaded blockset part
	max_part_size_KB="${pdc_max_part_size}" @ uint

	# Maximum total size of combined, processed blockset
	max_blockset_size_KB="${pdc_max_set_size}" @ uint

	# Minimum number of entries in final postprocessed blockset
	min_blockset_entries="${pdc_min_entries}" @ uint

	# If a path to custom script is specified and that script defines functions
	# 'report_success()', 'report_failure()' or 'report_update()',
	# one of these functions will be executed when adblock-lean completes the execution of some commands,
	# with corresponding message passed in first argument
	# report_success() and report_update() are only executed upon completion of the 'start' command
	# Recommended path is '/usr/libexec/abl_custom-script.sh' which the luci app has permission to access
	custom_script="" @ string

	# dnsmasq instance names and config directories
	# normally this should be set automatically by the 'setup' command
	dnsmasq_instances="${dmsq_instances}" @ string
	dnsmasq_conf_dirs="${conf_dirs}" @ string

	EOT
}

# (optional) -d to print with allowed value types (otherwise print without)
print_def_cfg_global()
{
	local me=print_def_cfg_global print_types preset OPTIND
	while getopts ":i:n:c:p:d" opt; do
		case "${opt}" in
			i|n|c) : ;; # ignore these options
			p) preset=$OPTARG ;;
			d) print_types=1 ;;
			*) bad_args "${me}" "${@}" ;;
		esac
	done

	: "${preset:=small}"
	is_included "${preset}" "${ALL_PRESETS:?}" || { reg_fail "${me}: invalid preset '${preset}'."; return 1; }

	cat <<-EOT | if [ -n "${print_types}" ]; then cat; else ${SED_CMD} 's/[ \t]*@.*//'; fi

	# adblock-lean configuration options
	# config_format=${CONFIG_FORMAT}
	#
	# values must be enclosed in double-quotes
	# custom comments are not preserved after automatic config update

	# Whether to create a hotplug script when persistent blockset is used
	#   The hotplug script activates on storage device removal. If the removed device is the one where the blockset is stored,
	#   adblock-lean will be automatically restarted and will create a new blockset on the ramdisk.
	PERSIST_HOTPLUG_SCRIPT="0" @ 0|1

	# Blockset part failed action:
	# This option applies to blockset parts which failed to download or couldn't pass validation checks
	# SKIP - skip failed blockset file part and continue blockset generation
	# STOP - stop blockset generation (and fall back to previous blockset if available)
	blockset_part_failed_action="SKIP" @ SKIP|STOP

	# Mininum number of entries in any individual downloaded part
	min_block_part_entries="1" @ uint
	min_ipv4_block_part_entries="1" @ uint
	min_allow_part_entries="1" @ uint

	# Maximum number of download retries
	max_download_attempts="3" @ uint

	# Default download mirrors
	# Hagezi mirror: 'github' or 'gitlab'
	hagezi_default_mirror="github" @ github|gitlab
	# oisd mirror: 'oisd' or 'github'
	oisd_default_mirror="oisd" @ oisd|github
	# Steven Black mirror: 'github' or 'sbc_io' for sbc.io
	stevenblack_default_mirror="github" @ github|sbc_io

	# Whether to perform sorting and deduplication of entries (usually doesn't cause much slowdown, uses a bit more memory) - enable (1) or disable (0)
	deduplication="1" @ 0|1

	# Utility to compress final blockset, intermediate blockset parts and the backup blockset to save memory
	# Supported options: gzip, pigz, zstd or 'none' to disable compression
	compression_util="gzip" @ gzip|pigz|zstd|none

	# Unload previous blockset from memory and restart dnsmasq before generation of new blockset.
	# Helps to free up memory during blockset generation - 'auto' or enable (1) or disable (0)
	unload_blockset_before_update="auto" @ auto|0|1

	# Start delay in seconds when service is started from system boot
	boot_start_delay_s="30" @ uint

	# Crontab schedule expression for periodic list updates
	upd_schedule="${upd_schedule:-"0 5 * * *"}" @ string

	# Maximal count of download and processing jobs run in parallel. 'auto' sets this value to the count of CPU cores
	MAX_PARALLEL_JOBS="auto" @ auto|uint

	# Log verbosity (0-5). Higher values send more messages to the syslog. Default is 1.
	LOG_VERBOSITY="1" @ 0|1|2|3|4|5

	EOT
}

confirm_cfg_write()
{
	local cfg_file cfg_id="${1:?}"
	get_cfg_path cfg_file "${cfg_id}" || return 1
	[ "${DO_DIALOGS}" = 1 ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ -z "${APPROVE_CFG_WRITE}" ] && [ -f "${cfg_file}" ] || return 0
	print_msg -blue "This will overwrite existing config file '${cfg_file}'. Proceed? (y|n)"
	pick_opt "y|n" && [ "${REPLY}" != n ]
}

# 1: new blockset ID
do_gen_blockset_config()
{
	# sets ${1} to recommended preset, depending on system memory capacity; ${2} to detected totalmem
	get_def_preset()
	{
		unset_vars "${1}" "${2}"
		assert_set F_get_def_preset ALL_PRESETS "${ALL_PRESETS%% *}_mem" || return 1

		local _totalmem _mem _preset IFS="${DEFAULT_IFS}"

		read -r _ _totalmem _ < /proc/meminfo

		is_uint "${_totalmem}" ||
		{
			reg_fail "\$_totalmem has invalid value '${_totalmem}'. Failed to determine system memory capacity."
			log_msg "Unable to select best preset for this system."
			return 1
		}

		for _preset in $(printf %s "${ALL_PRESETS}" | tr ' ' '\n' | ${SED_CMD} 'x;1!H;$!d;x') # loop over presets in reverse order
		do
			set_int "_mem = ${_preset}_mem"
			# multiplying by 800 rather than 1024 to account for some memory not available to the kernel
			[ "${_totalmem}" -ge $((_mem * 800)) ] && break
		done

		export -n "${1}=${_preset}" "${2}=${_totalmem}"
		:
	}

	local cnt totalmem totalmem_human preset \
		dmsq_instances conf_dirs \
		new_cfg\
		set_id="${1:-"${luci_new_blockset_name}"}"

	while :
	do
		is_alphanum "${set_id}" && break

		[ -z "${set_id}" ] && [ "${DO_DIALOGS}" = 1 ] ||
			print_msg "Invalid blockset name '${set_id}'. Use English letters and/or numbers and/or underlines."

		[ -n "${luci_new_blockset_name}" ] && return 1

		[ "${DO_DIALOGS}" = 1 ] ||
		{
			set_id=01
			break
		}

		print_msg -blue "" "Name the new blockset:"
		read -r set_id
	done

	if [ "${DO_DIALOGS}" = 1 ] && [ -z "${luci_preset}" ]
	then
		get_def_preset preset totalmem || print_msg "Skipping automatic preset recommendation."
		if [ -n "${preset}" ]
		then
			bytes2human totalmem_human $((totalmem*1024)) || return 1
			print_msg "" "Based on the total usable memory of this device (${totalmem_human}), the recommended preset is '${purple}${preset}${n_c}':"
			GP_PRINT_DESC=1 GP_PRINT_VALS=1 get_preset "${preset}" || return 1
			print_msg "" "[${lblue}C${n_c}]onfirm this preset or [${lblue}p${n_c}]ick another preset?"
			pick_opt "c|p"
		else
			REPLY=p
		fi

		if [ "${REPLY}" = p ]
		then
			print_msg "" "${purple}All available presets:${n_c}"
			local presets_case_opts=
			for preset in ${ALL_PRESETS}
			do
				add2list presets_case_opts "${preset}" "|"
				GP_PRINT_DESC=1 GP_PRINT_VALS=1 get_preset "${preset}" || return 1
			done
			print_msg -blue "" "Pick preset:"
			pick_opt "${presets_case_opts}"
			preset="${REPLY}"
		fi
	else
		# determine preset for luci
		case "${luci_preset}" in
			''|auto) get_def_preset preset totalmem || { reg_msg "Falling back to preset 'small'."; preset=small; } ;;
			*) preset="${luci_preset}"
		esac
	fi

	is_included "${preset}" "${ALL_PRESETS}" || { reg_fail "Invalid preset '${preset}'."; return 1; }
	reg_msg -blue "Selected preset '${preset}'."

	add2list SET_IDS "${set_id}"
	do_select_dnsmasq_instances "${set_id}" || return 1

	get_params -f gen_blockset_config "${set_id}" dmsq_instances conf_dirs &&
	reg_action -purple "" "Generating new blockset config ${lblue}${set_id}${n_c} from preset '${preset}'." &&
	new_cfg="$(print_def_cfg bl -i "${set_id}" -p "${preset}" -n "${dmsq_instances}" -c "${conf_dirs}")" &&
	confirm_cfg_write "${set_id}" &&
	write_config bl "${set_id}" "${new_cfg}" || return 1

	:
}

get_cfg_path()
{
	local g_path
	unset_vars "${1}"
	case "${2}" in
		global) g_path=${GLOBAL_CFG_FILE:?} ;;
		*[a-zA-Z0-9_]*) g_path="${ABL_CFG_DIR:?}/blockset-${2}.conf" ;;
		*) reg_fail "Invalid config name '${2}'."; return 1 ;;
	esac
	export -n "${1}=${g_path}"
}

san_config()
{
	local cfg_san_exp='/^\s*#.*$/d; s/^\s+//; s/\s+=/=/; s/=\s+/=/; s/\s+$//; /^$/d'
	if [ -n "${1}" ]
	then
		${SED_CMD:?} "${cfg_san_exp}" "${1}"
	else
		${SED_CMD:?} "${cfg_san_exp}" # read from STDIN
	fi
}

# validate config and assign to variables
# Env vars (used by the install script): CFG_IGNORE_NONCRIT, CFG_MIGRATE_OPTS
#
# 1: type: <global|bl>
# 2: config ID: <global|[set_id]>
# Optional:
# 3: config file path
# 4: var to output conf fixes
# 5: var to output keys requiring replacement
#
# return codes:
# 0 - Success
# 1 - Config error with no automatic fix
# 2 - Unexpected, missing or legacy-formatted (no double quotes) entries found
# 3 - Internal parser error
#
# sets variables for luci:
# *_unexp_keys *_unexp_entries *_missing_keys *_missing_entries
#     *_bad_cfg_format *_cfg_fixes *_bad_value_keys
parse_config()
{
	add_cfg_fix() { p_cfg_fixes="${p_cfg_fixes}${1}"$'\n'; }

	local me=parse_config \
		IFS="${DEFAULT_IFS}" \
		cfg_pr \
		cur_config \
		i keys entries entries_type_pr entries_pr \
		depr_keys depr_entries \
		depr_opts="dnsmasq_block_lists${_DELIM_}dnsmasq_allow_lists${_DELIM_}dnsmasq_ipv4_block_lists" \
		dup_keys dup_entries \
		unexp_keys unexp_entries \
		missing_keys missing_entries \
		bad_val_keys bad_val_entries corrected_entries \
		def_cfg_format \
		force_upd_cfg_format \
		p_cfg_fixes \
			cfg_type="${1:?}" cfg_id="${2:?}" cfg_path="${3}" fixes_out_var="${4}" replace_keys_out_var="${5}"

	: "${missing_entries}" "${bad_val_entries}" "${corrected_entries}"
	: "${dup_keys}" "${dup_entries}" "${unexp_keys}" "${unexp_entries}" "${depr_keys}" "${depr_entries}"

	[ -n "${cfg_path}" ] || get_cfg_path cfg_path "${cfg_id}" || return 1

	cfg_pr="config file '${cfg_path}'"

	unset_vars "${fixes_out_var}" "${replace_keys_out_var}"

	unset luci_unexp_keys luci_unexp_entries luci_missing_keys luci_missing_entries \
		luci_bad_cfg_format luci_cfg_fixes

	[ -z "${cfg_path}" ] && bad_args "${me}" "${@}"

	[ ! -f "${cfg_path}" ] && { reg_fail "Config file '${cfg_path}' not found."; return 1; }

	# Config format versions
	[ -n "${CFG_IGNORE_NONCRIT}" ] ||
	{
		def_cfg_format="$(print_def_cfg global | get_config_format)" || return 1
		export -n "luci_def_cfg_format"="${def_cfg_format}"
		cur_cfg_format="$(get_config_format "${cfg_path}")" || return 1
		export -n "luci_cur_cfg_format_${cfg_id}"="${cur_cfg_format}"
		is_uint "${cur_cfg_format}" ||
		{
			log_msg -warn "" "Config format version '${cur_cfg_format}' is unknown or invalid."
			add_cfg_fix "Update config format version"
			force_upd_cfg_format=1
		}
	}

	try_mkdir -p "${ABL_CFG_STAGING_DIR}" || return 1

	# read and sanitize current config
	cur_config="$(san_config "${cfg_path}")" || { reg_fail "Failed to read the ${cfg_pr}."; return 1; }

	local bad_newline=
	case "${cur_config}" in
		*"${CR_LF}"*) bad_newline="Windows-style (CR_LF)" ;;
		*"${CR}"*) bad_newline="MacOS-style (CR)" ;;
	esac
	[ -n "${bad_newline}" ] &&
	{
		reg_fail "${bad_newline} newlines detected in ${cfg_pr}. Convert the config file to Unix-style (LF) newlines."
		return 1
	}

	# parse config
	local parse_line parse_lines entry_type \
		valid_lines \
		parser_err_file="${ABL_CFG_STAGING_DIR}/parser_err" \
		awk_err_file="${ABL_CFG_STAGING_DIR}/awk_err" \
		inval_entry_file="${ABL_CFG_STAGING_DIR}/inval_entry"
	rm -f "${parser_err_file}" "${awk_err_file}" "${inval_entry_file}"
	for entry_type in unexp bad_val missing dup depr
	do
		rm -f "${ABL_CFG_STAGING_DIR}/${entry_type}_entries"
	done

	# extract valid values from default config
	valid_lines="$(print_def_cfg "${cfg_type}" -i "${cfg_id}" -d | san_config | tr '\n' "${_DELIM_:?}")" || return 1

	parse_lines="$(
		printf '%s\n' "${cur_config}" |
		${AWK_CMD:?} -F"=" \
			-v q="'" \
			-v blue="${blue}" \
			-v n_c="${n_c}" \
			-v ID="${cfg_id}" \
			-v IGN="${CFG_IGNORE_NONCRIT}" \
			-v DELIM="${_DELIM_:?}" \
			-v V="${valid_lines}" \
			-v M="${CFG_MIGRATE_OPTS}" \
			-v D="${depr_opts}" \
			-v A="${ABL_CFG_STAGING_DIR:?}" '
		# return codes: 0=OK, 1=awk or default config error, 253=check double-quotes, 254=Invalid entry detected

		function check_value(key,val)
		{
			regex="^(" valid_values_regex_arr[key] ")$"
			if (val !~ regex) {
				return 1
			}
			return 0
		}

		function intern_err(msg)
		{
			rv=1
			print "Internal parser error: " msg > A"/parser_err"
		}

		function get_var_name(opt)
		{
			if (!opt) {intern_err("get_var_name: empty opt."); exit}
			if (ID == "global") return opt
			return opt "_" ID
		}

		BEGIN{
			rv=0
			line_comp[1]="key"
			line_comp[2]="value"
			line_comp[3]="allowed values"

			# Create validation arrays
			split(V,def_lines_arr,DELIM)
			for (ind in def_lines_arr) {
				# Remove whitespaces/tabs
				sub(/"[ \t]*@[ \t]*/,"\"@",def_lines_arr[ind])
				# Validate default config line
				n=split(def_lines_arr[ind],def_line_parts,"[=@]") # Split into key, value, allowed values
				if (n==0) continue
				if (n!=3) {intern_err("Invalid line in default config: " q def_lines_arr[ind] q "."); exit}
				for (i in def_line_parts) {
					if (! def_line_parts[i]) {
						intern_err("Invalid line in default config: " q def_lines_arr[ind] q " is missing the " line_comp[i] ".")
						exit
					}
				}

				key=def_line_parts[1]
				def_arr[key]=def_line_parts[2]
				valid_values=def_line_parts[3]

				# Create entry-specific validation regex array, printable valid values array
				if (valid_values_seen_regex_arr[valid_values] != "")
				{
					valid_values_regex_arr[key]=valid_values_seen_regex_arr[valid_values]
					valid_values_print_arr[key]=valid_values_seen_print_arr[valid_values]
				}
				else if (valid_values ~ /(^|\|)string($|\|)/)
				{
					valid_values_regex_arr[key]=".*"
					valid_values_seen_regex_arr[valid_values]=".*"
				}
				else
				{
					val_regex=valid_values
					if ( ! sub(/uint_list/,"[ 	]*[0-9]+([ 	]+[0-9]+)*[ 	]*",val_regex) )
						sub(/uint/,"[0-9]+",val_regex)
					valid_values_regex_arr[key]=val_regex
					valid_values_seen_regex_arr[valid_values]=val_regex

					val_print=blue valid_values n_c
					if ( ! sub(/uint_list/,"space-separated list of non-negative integers",val_print) )
						sub(/uint/,"non-negative integer",val_print)
					gsub(/\|/,n_c " or " blue, val_print)
					valid_values_print_arr[key]=val_print
					valid_values_seen_print_arr[valid_values]=val_print
				}
			}

			# Create migrate_keys_arr
			split(M,migrate_entries_arr,DELIM)
			for (ind in migrate_entries_arr)
			{
				entry=migrate_entries_arr[ind]
				n = index(entry, "=")
				if(n)
				{
					old_key = substr(entry, 1, n-1)
					new_key = substr(entry, n+1)
					migrate_keys_arr[old_key] = new_key
				}
			}

			# Create depr_keys_arr
			split(D,d_tmp,DELIM)
			for (ind in d_tmp)
				depr_keys_arr[d_tmp[ind]]
		}

		# Process user config
		{
			sub(/^[ 	]+/,"")
			sub(/[ 	]+$/,"")

			# Handle double or missing =
			if ( $0 !~ /^[^=]+=[^=]+([ \t]+(#.*){0,1})*$/ ) {
				print $0 > A"/inval_entry"
				rv=254
				exit
			}

			# Key must be non-empty and alphanumeric
			if ( $1 !~ /^[a-zA-Z0-9_]+$/ ) {
				print $0 > A"/inval_entry"
				rv=254
				exit
			}

			# Line must have exactly 2 double-quotes after = and no characters before #
			if ( $0 !~ /^[^"]+="[^"]*"([ \t]+(#[^"]*){0,1}){0,1}$/ ) {
				print $0 > A"/inval_entry"
				rv=253
				exit
			}

			# Get value
			split($2,tmp,"\"")
			val=tmp[2]

			# Deprecated keys
			if ($1 in depr_keys_arr) {
				if (! val) next
				depr_keys=depr_keys $1 " "
				print $0 >> A"/depr_entries"
				next
			}

			# Migrated keys
			if ($1 in migrate_keys_arr) {
				new_key=migrate_keys_arr[$1]
				if (check_value(new_key,val) == 0)
				{
					config_keys[new_key]
					print get_var_name(new_key) "=" val
					next
				}
			}

			# Duplicate keys
			if ($1 in config_keys) {
				if (IGN) next
				dup_keys=dup_keys $1 " "
				print $0 >> A"/dup_entries"
				next
			}

			# Unexpected keys
			if ($1 in def_arr) {} else {
				if (IGN) next
				unexp_keys=unexp_keys $1 " "
				print $0 >> A"/unexp_entries"
				next
			}

			# Register the key
			config_keys[$1]

			# Unexpected values
			if (check_value($1,val) != 0)
			{
				if (IGN) next
				bad_val_keys=bad_val_keys $1 " "
				print $1 "=" $2 " (should be " valid_values_print_arr[$1] ")" >> A"/bad_val_entries"
				print $1 "=" def_arr[$1] >> A"/corrected_entries"
				next
			}

			print get_var_name($1) "=" val
		}

		END{
			if (rv != 0) {exit rv}
			for (key in def_arr) {
				if (key in config_keys) {} else {
					print key "=" def_arr[key] >> A"/missing_entries"
					missing_keys=missing_keys key " "
				}
			}
			print "missing_keys=" missing_keys
			print "unexp_keys=" unexp_keys
			print "dup_keys=" dup_keys
			print "depr_keys=" depr_keys
			print "bad_val_keys=" bad_val_keys
			exit rv
		}'
	)" &&
	[ ! -s "${awk_err_file}" ] &&
	[ ! -s "${parser_err_file}" ] ||
	{
		local awk_rv=${?} inval_entry=''
		[ -s "${awk_err_file}" ] && reg_fail "awk errors encountered while parsing ${cfg_pr}:${_NL_}$(cat "${awk_err_file}")"
		[ -s "${parser_err_file}" ] && reg_fail "$(cat "${parser_err_file}")"
		[ -s "${inval_entry_file}" ] && inval_entry=": ${_NL_}'$(cat "${inval_entry_file}")'"

		rm -f "${awk_err_file}" "${parser_err_file}"
		case "${awk_rv}" in
			253) reg_fail "Invalid entry in ${cfg_pr} (check double-quotes)${inval_entry}" ;;
			254) reg_fail "Invalid entry in ${cfg_pr}${inval_entry}" ;;
			*) reg_fail "Failed to parse ${cfg_pr}."; return 3
		esac

		return 1
	}

	rm -f "${parser_err_file}"

	debug_msg "" "parse_lines:" "${parse_lines}" ""

	# Parse config lines into vars
	IFS="${_NL_}"
	for parse_line in ${parse_lines}
	do
		[ -n "${parse_line}" ] || continue
		IFS="${DEFAULT_IFS}"
		export -n "${parse_line?}" || { reg_fail "Failed to parse '${parse_line}'"; return 3; }
	done
	IFS="${DEFAULT_IFS}"

	# remove trailing '/' from dir path
	[ "${cfg_id}" = global ] ||
	{
		local persist_dir
		get_params "${cfg_id}" persist_dir
		set_params "${cfg_id}" persist_dir="${persist_dir%/}"
	}

	[ -n "${CFG_IGNORE_NONCRIT}" ] && return 0

	for i in \
		"bad_val||Replace unexpected values with defaults" \
		"depr|Deprecated|Remove deprecated entries from config" \
		"dup|Duplicate|Remove duplicate entries from config" \
		"unexp|Unexpected|Remove unexpected entries from config" \
		"missing|Missing|Add missing config entries with default values"
	do
		entry_type="${i%%|*}"
		eval "keys=\"\${${entry_type}_keys% }\""
		[ -n "${keys}" ] || continue

		i="${i#"${entry_type}|"}"

		entries="$(cat "${ABL_CFG_STAGING_DIR}/${entry_type}_entries")"
		entries="${entries%$'\n'}"
		entries_pr="${entries}"
		case "${entry_type}" in
			bad_val)
				log_msg -yellow "" "Detected entries with unexpected values in ${cfg_pr}:"
				cat "${ABL_CFG_STAGING_DIR}/bad_val_entries"
				entries_pr="$(cat "${ABL_CFG_STAGING_DIR}/corrected_entries")"
				entries_pr="${entries_pr%$'\n'}"
				export -n "luci_corrected_entries_${cfg_id}"="${entries_pr}"
				;;
			*) log_msg -yellow "" "${i%%|*} keys in ${cfg_pr}:${_NL_}${n_c}${lblue}${keys// /"${_NL_}"}${n_c}"
		esac

		entries_type_pr=
		case "${entry_type}" in
			missing|bad_val) entries_type_pr=" default"
		esac

		print_msg "Corresponding${entries_type_pr} config entries:${n_c}" "${lblue}${entries_pr}${n_c}"
		add_cfg_fix "${i##*|}"
		export -n "luci_${entry_type}_keys_${cfg_id}"="${keys}" "luci_${entry_type}_entries_${cfg_id}"="${entries}"
	done

	p_cfg_fixes="${p_cfg_fixes%$'\n'}"

	if [ -z "${p_cfg_fixes}" ] && [ -z "${force_upd_cfg_format}" ] && [ "${cur_cfg_format}" != "${def_cfg_format}" ]
	then
		log_msg -yellow "" "Current config format version '${cur_cfg_format}' differs from default config version '${def_cfg_format}'."
		add_cfg_fix "Update config format version"
	fi

	export -n "${fixes_out_var:-_}=${p_cfg_fixes}" "${replace_keys_out_var:-_}=${missing_keys}${bad_val_keys}"

	[ -n "${p_cfg_fixes}" ] && return 2
	:
}

load_config()
{
	local err_path err_cfg fix_cmd
	[ -n "${CONFIG_LOADED}" ] && return 0

	detect_main_utils || return 1 # for versions < 3 of abl-install.sh
	dbg_off
	try_load_config err_cfg ||
	{
		reg_fail "Failed to load config${err_cfg:+" '${err_cfg}'"}."
		case "${err_cfg}" in
			global) fix_cmd=gen_global_config ;;
			blockset-*) fix_cmd="gen_blockset_config ${err_cfg}"
		esac
		[ -n "${err_cfg}" ] && [ -n "${fix_cmd}" ] &&
		{
			get_cfg_path err_path "${err_cfg}"
			log_msg "Fix your config file '${err_path}' or generate default config using 'service adblock-lean ${fix_cmd}'."
		}
		dbg_on
		return 1
	}
	dbg_on
	export -n CONFIG_LOADED=1
	:
}

# shellcheck disable=SC2120
# 1: var name to output which file failed parsing
try_load_config()
{
	print_cfg_fixes()
	{
		local cfg_id cfg_path fix fixes cnt \
			IFS="${DEFAULT_IFS}"
		for cfg_id in global ${SET_IDS}
		do
			cnt=0
			eval "fixes=\"\${cfg_fixes_${cfg_id}}\" cfg_path=\"\${cfg_path_${cfg_id}}\""
			[ -n "${fixes}" ] || continue
			print_msg "" "In config file '${cfg_path}':"
			IFS="${_NL_}"
			for fix in ${fixes}
			do
				IFS="${DEFAULT_IFS}"
				[ -n "${fix}" ] || continue
				cnt=$((cnt+1))
				print_msg "${cnt}. ${fix}"
			done
			IFS="${DEFAULT_IFS}"
		done
	}

	local force_fix l_cfg_fixes l_replace_keys \
		all_cfg_fixes \
		cfg_path cfg_type cfg_id \
		err_cfg_out_var="${1}"

	[ -n "${ABL_LUCI_SOURCED}" ] || [ -n "${APPROVE_UPD_CHANGES}" ] && force_fix=1

	[ -z "${DO_DIALOGS}" ] && [ -z "${ABL_LUCI_SOURCED}" ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] &&
		DO_DIALOGS=1

	if [ ! -f "${GLOBAL_CFG_FILE:?}" ]
	then
		reg_fail "Global config file '${GLOBAL_CFG_FILE:?}' is missing."
		return 1
	fi

	for cfg_id in global ${SET_IDS}
	do
		case "${cfg_id}" in
			global) cfg_type=global ;;
			*) cfg_type=bl
		esac
		get_cfg_path cfg_path "${cfg_id}" || return 1

		export -n "${err_cfg_out_var}=${cfg_id}"
		local "cfg_path_${cfg_id}=${cfg_path}"

		# validate config and assign to variables
		local "cfg_fixes_${cfg_id}=" "replace_keys_${cfg_id}="
		dbg_off
		parse_config "${cfg_type}" "${cfg_id}" "" "cfg_fixes_${cfg_id}" "replace_keys_${cfg_id}"
		local parse_rv=${?}
		dbg_on
		case ${parse_rv} in
			0) ;;
			1) return 1 ;; # config error with no automatic fix
			2) ;; # config error(s) with automatic fix
			3) return 1 # internal parser error
		esac

		eval "all_cfg_fixes=\"${all_cfg_fixes}${all_cfg_fixes:+"${_NL_}"}\${cfg_fixes_${cfg_id}}\""
		export -n "luci_cfg_fixes_${cfg_id}"="${all_cfg_fixes}"

		# if not in interactive console and force-fix not set, return error
		[ -n "${all_cfg_fixes}" ] && [ "${DO_DIALOGS}" != 1 ] && [ -z "${force_fix}" ] && return 1
	done

	if [ -n "${all_cfg_fixes}" ]
	then
		export -n "${err_cfg_out_var}"=
		if [ "${DO_DIALOGS}" = 1 ] && [ -z "${force_fix}" ]
		then
			print_msg -blue "" "Perform following automatic changes? (y|n)"
			print_cfg_fixes
			pick_opt "y|n"
			[ "${REPLY}" = y ] || return 1
		else
			print_msg -blue "" "Performing following config changes:"
			print_cfg_fixes
		fi

		for cfg_id in global ${SET_IDS}
		do
			export -n "${err_cfg_out_var}=${cfg_id}"
			eval \
				"l_cfg_fixes=\"\${cfg_fixes_${cfg_id}}\"" \
				"l_replace_keys=\"\${replace_keys_${cfg_id}}\""
			[ -n "${l_cfg_fixes}" ] || continue
			fix_config "${cfg_id}" "${l_replace_keys}" || { reg_fail "Failed to fix the config."; return 1; }
		done
	fi

	:
}

get_cfg_type()
{
	local _cfg_type
	case "${2:?}" in
		global) _cfg_type=global ;;
		'') return 1 ;;
		*) _cfg_type=bl ;;
	esac
	export -n "${1}=${_cfg_type}"
}

# 1: config type
# 2: config ID
# 3: keys to replace (space-separated)
fix_config()
{
	local var_suffix \
		dmsq_instances conf_dirs \
		fixed_cfg \
		bk_prefix \
		cfg_type \
			cfg_id="${1:?}" replace_keys="${2}"

	get_cfg_type cfg_type "${cfg_id}" &&
	get_cfg_path cfg_path "${cfg_id}" || return 1

	[ "${cfg_type}" = global ] || var_suffix="_${cfg_id}"

	if is_included dnsmasq_instances "${replace_keys}" || is_included dnsmasq_conf_dirs "${replace_keys}"
	then
		do_select_dnsmasq_instances "${cfg_id}" || return 1
	fi

	[ "${cfg_type}" = bl ] &&
	{
		get_params "${cfg_id}" dmsq_instances conf_dirs
		bk_prefix="blockset-"
	}

	local old_cfg_f="/tmp/adblock-lean_config_${bk_prefix}${cfg_id}.bk"
	if ! cp "${cfg_path}" "${old_cfg_f}"
	then
		reg_fail "Failed to save old config file as ${old_cfg_f}."
		if [ -z "${APPROVE_UPD_CHANGES}" ]
		then
			[ "${DO_DIALOGS}" = 1 ] || return 1
			print_msg -blue "Proceed with suggested config changes? (y|n)"
			pick_opt "y|n"
			[ "${REPLY}" = n ] && return 1
		fi
	else
		reg_msg "" "Old config file was saved as ${old_cfg_f}."
	fi

	# recreate config from default while replacing values with values from the existing config
	fixed_cfg="$(
		print_def_cfg "${cfg_type}" -i "${cfg_id}" -n "${dmsq_instances}" -c "${conf_dirs}" |
		while IFS="${_NL_}" read -r def_line
		do
			cur_val=
			case "${def_line}" in
				\#*|'') printf '%s\n' "${def_line}"; continue ;;
				*=*)
					key=${def_line%%=*}
					if is_included "${key}" "${replace_keys}"
					then
						printf '%s\n' "${def_line}"
						continue
					fi

					eval "cur_val=\"\${${key}${var_suffix}}\""
					printf '%s\n' "${key}=\"${cur_val}\""
					continue
			esac
		done
	)" &&
	write_config "${cfg_type}" "${cfg_id}" "${fixed_cfg}" || return 1

	:
}

# Writes STDIN to to temp file, validates it, moves it to permanent storage
# 1: config type
# 2: config ID
# 3: new config contents
write_config()
{
	dbg_off
	local me=write_config \
		cfg_file tmp_cfg_file \
		cfg_type="${1:?}" cfg_id="${2:?}" cfg_cont="${3:?}"

	get_cfg_path cfg_file "${cfg_id}" &&

	try_mkdir -p "${ABL_CFG_STAGING_DIR}" || return 1
	tmp_cfg_file="${ABL_CFG_STAGING_DIR:?}/write-config_${cfg_id}.tmp"
	printf '%s\n' "${cfg_cont}" > "${tmp_cfg_file}" || { reg_fail "Failed to write to file '${tmp_cfg_file}'."; return 1; }

	parse_config "${cfg_type}" "${cfg_id}" "${tmp_cfg_file}" ||
		{ rm -f "${tmp_cfg_file}"; reg_fail "Failed to validate config file '${tmp_cfg_file}'."; dbg_on; return 1; }
	dbg_on

	reg_msg "" "Saving the new config to '${cfg_file}'."

	try_mkdir -p "${cfg_file%/*}" &&
	try_mv "${tmp_cfg_file}" "${cfg_file}" ||
		{
			rm -f "${tmp_cfg_file}"
			return 1
		}
	:
}


### HELPER FUNCTIONS

# shellcheck disable=SC2120
# get config format from config or main script file contents
# input via STDIN or ${1}
get_config_format()
{
	local cfg_form_sed_expr='/^[ \t]*(CONFIG_FORMAT|#[ \t]*config_format)=v/{s/.*=v//;p;:1 n;b1;}'
	if [ -n "${1}" ]
	then
		${SED_CMD} -En "${cfg_form_sed_expr}" "${1}"
	else
		${SED_CMD} -En "${cfg_form_sed_expr}"
	fi
}

# Get version and update channel of adblock-lean file
# Assigns vars $2 = version, $3 = update channel
# 1 - path to adblock-lean service file
# Return codes:
# 0 - supported version format
# 1 - error
# 2 - no version found
get_abl_version()
{
	get_ver_str()
	{
		[ -n "${3}" ] || return 1
		unset_vars "${1}" "${2}"
		local _par res_version res_upd_channel key_ptrn res
		for _par in version upd_channel
		do
			key_ptrn='' res=''
			case "${_par}" in
				version) key_ptrn="\\s*ABL_VERSION" ;;
				upd_channel) key_ptrn="\\s*ABL_UPD_CHANNEL" ;;
			esac

			res="$(${SED_CMD} -n "/^${key_ptrn}=/{s/^${key_ptrn}=//;s/#.*$//;s/\"//g;p;:1 n;b1;}" "${3}")" &&
				[ -n "${res}" ] || return 1
			export -n "res_${_par}=${res}"
		done
		export -n "${1}=${res_upd_channel}" "${2}=${res_version}"
	}

	local gv_ver gv_upd_ch gv_rv cfg_format
	unset_vars "${2}" "${3}"

	[ -s "${1}" ] || { reg_fail "Can not find '${1}'."; return 1; }

	# Requires adblock-lean v0.7.3 and later (config format 9 or higher)
	if \
		cfg_format="$(get_config_format "${1}")" &&
		is_gr_eq 9 "${cfg_format}" &&
		grep -q '^\s*ABL_UPD_CHANNEL=' "${1}" &&
		get_ver_str gv_upd_ch gv_ver "${1}"
	then
		gv_rv=0
	else
		gv_rv=2
	fi
	export -n "${2:-_}=${gv_ver}"
	export -n "${3:-_}=${gv_upd_ch}"
	return ${gv_rv:-1}
}

# return values:
# 0 - up-to-date
# 1 - not up-to-date
# 2 - update check failed
# 3 - automatic updates check is disabled for current update channel
check_for_updates()
{
	local tarball_url cur_ver upd_ver upd_channel no_upd
	unset UPD_AVAIL UPD_DIRECTIONS
	get_abl_version "${ABL_SERVICE_PATH}" cur_ver upd_channel
	case "${upd_channel}" in
		release|latest|snapshot|branch=*) ;;
		commit) no_upd="was installed from a specific Git commit" ;;
		'') no_upd="update channel is unknown" ;;
		*) no_upd="update channel is '${upd_channel}'" ;;
	esac
	[ -n "${no_upd}" ] && { print_msg "" "adblock-lean ${no_upd}. Automatic updates check is disabled."; return 3; }
	reg_action -purple "" "Checking for adblock-lean updates."
	rm -rf "${ABL_UPD_DIR}"
	try_mkdir -p "${ABL_UPD_DIR}" &&
	get_gh_ref "${upd_channel}" "" upd_ver tarball_url _
	local gh_ref_rv=${?}
	luci_tarball_url="${tarball_url}"

	rm -rf "${ABL_UPD_DIR}"

	[ "${gh_ref_rv}" != 0 ] &&
	{
		reg_fail "" "Failed to check for adblock-lean updates."
		return 2
	}

	if [ "${upd_ver}" = "${cur_ver}" ]
	then
		reg_msg "The locally installed adblock-lean is the latest version."
		return 0
	else
		local upd_details="(update channel: ${upd_channel}, installed: '${cur_ver}', latest: '${upd_ver}')"
		UPD_DIRECTIONS="Consider running: 'service adblock-lean update' to update it to the latest version."
		export -n UPD_AVAIL_MSG="adblock-lean update is available ${upd_details}"
		reg_msg -2 -yellow "The locally installed adblock-lean seems to be outdated ${upd_details}."
		print_msg "${UPD_DIRECTIONS}"
		return 1
	fi
}

# returns 0 if crontab is readable and the crond process is running, 1 otherwise
check_cron_service()
{
	local IFS="${DEFAULT_IFS}"
	# check if service is enabled
	${ABL_CRON_SVC_PATH} enabled || return 1
	# check reading crontab
	crontab -u root -l &>/dev/null || return 1
	# check for crond in running processes
	${PIDOF_CMD} crond 1>/dev/null || return 1
	:
}

# checks if the cron service is enabled and running
# if not enabled or not running or if crontab doesn't exist, implements automatic correction
# return codes: 0 - success, 1 - failure
enable_cron_service()
{
	local enable_failed="Failed to enable and start the cron service"

	hash crontab || { reg_fail "${enable_failed}: 'crontab' utility is inaccessible."; return 1; }
	[ -f "${ABL_CRON_SVC_PATH}" ] || { reg_fail "${enable_failed}: the cron service was not found at path '${ABL_CRON_SVC_PATH}'."; return 1; }

	check_cron_service && return 0
	log_msg -warn "The cron service is not enabled or not running."

	printf '\n%s' "${purple}Attempting to enable and start the cron service...${n_c} " > "${MSGS_DEST}"

	# if crontab doesn't exist yet, try to create an empty crontab
	crontab -u root -l &>/dev/null || printf '' | crontab -u root -

	# try to enable and start the cron service
	${ABL_CRON_SVC_PATH} enabled 1>/dev/null || ${ABL_CRON_SVC_PATH} enable && { ${ABL_CRON_SVC_PATH} start; sleep 2; }

	check_cron_service || { printf '%s\n' "${red}Failed${n_c}"; reg_fail "${enable_failed}."; return 1; }
	printf '%s\n' "${green}OK${n_c}" > "${MSGS_DEST}"
	:
}

:
