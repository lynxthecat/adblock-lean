#!/bin/sh
# shellcheck disable=SC3043,SC3003,SC3001,SC3020,SC3044,SC2016,SC3057,SC3019,SC2018,SC2019,SC3060,SC3045
# shellcheck source=/dev/null

# silence shellcheck warnings
: "${blue:=}" "${purple:=}" "${green:=}" "${red:=}" "${yellow:=}" "${n_c:=}"
: "${raw_block_lists:=}" "${test_domains:=}" "${whitelist_mode:=}" "${compression_util:=}"
: "${max_blocklist_file_size_KB:=}" "${min_good_line_count:=}"
: "${luci_cron_job_creation_failed}" "${luci_pkgs_install_failed}" "${luci_tarball_url}"

### GLOBAL VARIABLES
RECOMMENDED_PKGS="gawk sed coreutils-sort"
RECOMMENDED_UTILS="awk sed sort"
ABL_CRON_SVC_PATH=/etc/init.d/cron
ALL_PRESETS="mini small medium large large_relaxed"

# PRESETS
# lists_cnt - urls count, cnt - target elements count, mem - intended device memory in MB
# shellcheck disable=SC2034
{
	mini_lists="hagezi:pro.mini" mini_lists_cnt=1 mini_cnt=85000 mini_mem=64
	small_lists="hagezi:pro" small_lists_cnt=1 small_cnt=250000 small_mem=128
	medium_lists="hagezi:pro hagezi:tif.mini" medium_lists_cnt=2 medium_cnt=350000 medium_mem=256
	large_lists="hagezi:pro hagezi:tif" large_lists_cnt=2 large_cnt=1200000 large_mem=512
	large_relaxed_lists="hagezi:pro hagezi:tif" large_relaxed_lists_cnt=2 large_relaxed_cnt=1200000 large_relaxed_mem=1024 large_relaxed_coeff=2
}

### UTILITY FUNCTIONS

tolower()
{
	local tl_str
	case "${2}" in
		*[A-Z]*) tl_str="$(printf '%s' "${2}" | tr 'A-Z' 'a-z' )" ;;
		*) tl_str="${2}"
	esac
	eval "${1}"='${tl_str}'
	: "${tl_str}"
}

trim_spaces()
{
	local tr_in tr_out
	eval "tr_in=\"\${$1}\""
	tr_out="${tr_in%"${tr_in##*[! 	]}"}"
	tr_out="${tr_out#"${tr_out%%[! 	]*}"}"
	eval "${1}=\"\${tr_out}\""
}

try_mv()
{
	[ -n "${1}" ] && [ -n "${2}" ] || { bad_args "try_mv" "${@}"; return 1; }
	mv -f "${1}" "${2}" || { reg_failure "Failed to move '${1}' to '${2}'."; return 1; }
	:
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
	eval "${1}"='${cnt}'
}

get_file_size() { du -b "$1" | ${AWK_CMD} '{print $1}'; }

get_pad()
{
	local spaces='                                      ' \
		pad_len=$(( ${3} - ${#2} ))
	[ "$pad_len" -lt 0 ] && pad_len=0
	eval "${1}=\"${spaces:1:${pad_len}}\""
}

# converts unsigned integer to [xB|xKiB|xMiB|xGiB|xTiB]
# if result is not an integer, outputs up to 2 digits after decimal point
# 1 - output var name
# 2 - int
# 3 - (optional) '-p' to add padding
bytes2human()
{
	unset_vars "${1}" || return 1
	local i="${2:-0}" s=0 d=0 m=1024 fp='' S='' bh_res='' pad='' align=''
	[ "${3}" = '-p' ] && align=1
	is_uint "${i}" || { reg_failure "bytes2human: invalid uint '${i}'."; return 1; }
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
	: "${pad}"
	[ -n "${align}" ] && get_pad pad "${bh_res}" 10
	eval "${1}"='${pad}${bh_res}'
}

# 1 - var name for output
# 2 - uint
int2human()
{
	unset_vars "${1}" || return 1
	is_uint "${2}" || { reg_failure "int2human: invalid uint '${2}'."; return 1; }

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
	eval "${1}"='${in_num:-0}${out_num}'
}


### SETUP AND CONFIG MANAGEMENT

create_addnmounts()
{
	create_addnmount() { uci add_list "dhcp.@dnsmasq[${1}].addnmount=${2}"; }

	local me=create_addnmounts IFS="${DEFAULT_IFS}" REPLY \
		missing_addnm all_missing_addnm='' all_req_addnmounts='' addnm_ignore_paths='' \
		ca_paths ca_compr_util_path ca_compr_ext \
		bl_full_fname bl_path_ram

	assert_set "F_${me}" DNSMASQ_INDEXES compression_util || return 1

	## Check addmounts

	# Compression
	get_compr_util_spec ca_compr_util_path ca_compr_ext "${compression_util}" || return 1

	if [ -n "${ca_compr_ext}" ]
	then
		bl_full_fname=${BLOCKLIST_BASE_FNAME:?}${ca_compr_ext}
		bl_path_ram=${ABL_RUN_DIR:?}/${bl_full_fname}
		ca_paths="${BUSYBOX_PATH:?}${_NL_}${ca_compr_util_path%% *}${_NL_}${bl_path_ram}"
		check_addnmounts missing_addnm "${ca_paths}" || return 1

		add2list all_req_addnmounts "${ca_paths}" "${_NL_}" &&
		add2list all_missing_addnm "${missing_addnm}" ", " || return 1
    fi

	: "${bl_full_fname:="${BLOCKLIST_BASE_FNAME:?}"}"

	# Multiple dnsmasq instances
	case "${DNSMASQ_INDEXES}" in
		*[0-9]*" "*[0-9]*)
				bl_path_ram=${ABL_RUN_DIR:?}/${bl_full_fname}
				ca_paths="${BUSYBOX_PATH:?}${_NL_}${bl_path_ram}"
				check_addnmounts missing_addnm "${ca_paths}" &&
				add2list all_req_addnmounts "${ca_paths}" "${_NL_}" &&
				add2list all_missing_addnm "${missing_addnm}" ", " || return 1 ;;
		*)
			first_conf_dir="${DNSMASQ_CONF_DIRS%% *}"
			is_valid_dir "${first_conf_dir}" || return 1
			addnm_ignore_paths="${first_conf_dir}/${bl_full_fname}"

			: "${bl_path_ram:="${first_conf_dir}/${bl_full_fname}"}" ;;
    esac

	assert_set "F_${me}" bl_path_ram || return 1

	# Persistent blocklist
	case "${PERSIST_BLOCKLIST_MODE}" in manual|managed)
			ca_paths="${BUSYBOX_PATH:?}${_NL_}${PERSIST_BLOCKLIST_DIR}"
			is_included "${bl_path_ram}" "${addnm_ignore_paths}" "${_NL_}" ||
				add2list ca_paths "${bl_path_ram}" "${_NL_}"
			check_addnmounts missing_addnm "${ca_paths}" &&
			add2list all_req_addnmounts "${ca_paths}" "${_NL_}" &&
			add2list all_missing_addnm "${missing_addnm}" ", " || return 1
	esac

	[ -n "${all_missing_addnm}" ] ||
	{
		reg_msg -green "All required dnsmasq addnmount entries already exist."
		return 0
	}

	## Dialog
	log_msg -yellow "" "Detected missing addnmount entries in /etc/config/dhcp for paths: ${all_missing_addnm}"
	if [ "${DO_DIALOGS}" = 1 ] && [ -z "${APPROVE_UPD_CHANGES}" ]
	then
		print_msg -blue "Create missing addnmount entries automatically? (y|n)"
		pick_opt "y|n" || return 1
	else
		log_msg -blue "Automatically creating missing addnmount entries."
		REPLY=y
	fi
	[ "${REPLY}" = y ] || return 0

	## Create addnmounts
	local index path paths_pr add_list_failed=''

	IFS="${_NL_}"
	for path in ${all_req_addnmounts}
	do
		IFS="${DEFAULT_IFS}"
		add2list paths_pr "'${path}'" ", "
	done
	IFS="${DEFAULT_IFS}"

	for index in ${DNSMASQ_INDEXES}
	do
		del_addnmounts "${index}"
		case ${?} in 0|3) ;; *) { add_list_failed=1; break; }; esac
		log_msg -purple "Creating dnsmasq addnmount entries for dnsmasq instance ${index}: ${paths_pr}."
		IFS="${_NL_}"
		for path in ${all_req_addnmounts}
		do
			IFS="${DEFAULT_IFS}"
			create_addnmount "${index}" "${path}" || { add_list_failed=1; break 2; }
		done
		IFS="${DEFAULT_IFS}"
	done

	[ -z "${add_list_failed}" ] && uci commit dhcp ||
	{
		uci revert dhcp
		reg_failure "Failed to create or change addnmount entries."
		return 1
	}

	unset ADDNMOUNTS_SET DHCP_LOADED

	:
}

get_pkg_name()
{
	unset_vars "${1}" || return 1
	local _name
	case "${2}" in
		awk) _name="gawk" ;;
		sed) _name="sed" ;;
		sort) _name="coreutils-sort"
	esac
	: "${_name}"
	eval "${1}"='${_name}'
}


# Error codes:
# 1 - general error
# 2 - gen_config failed
# 3 - load_config failed
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
				reg_failure "Unexpected package manager '${PKG_MANAGER}'."
				return 1
		esac

		all_installed_pkgs="$(${pkgs_list_cmd})" && [ -n "${all_installed_pkgs}" ] || {
			reg_failure "Failed to check installed packages with package manager '$PKG_MANAGER'."
			return 1
		}
		printf '%s\n' "$all_installed_pkgs" | eval "${filter_cmd}"

		:
	}

	install_packages()
	{
		# determine if there are missing GNU utils
		local recomm_pkgs_regex="${RECOMMENDED_PKGS//" "/|}"
		local pkgs2install='' missing_packages='' missing_utils='' all_req_addnmounts='' missing_utils_print='' util pkg_name \
			installed_pkgs='' util_size_B='' util_size_human='' utils_size_B=0 utils_size_human='' awk_size_B sort_size_B sed_size_B \
			free_space_human='' free_space_B='' free_space_KB mount_point

		: "${awk_size_B:=1048576}" "${sort_size_B:=122880}" "${sed_size_B:=153600}"

		installed_pkgs="$(get_installed_pkgs "${recomm_pkgs_regex}")" || return 1

		echo > "${MSGS_DEST}"
		for util in ${RECOMMENDED_UTILS}
		do
			case "${installed_pkgs}" in
				*"${util}"*) reg_msg -green "GNU ${util} is already installed." ;;
				*)
					get_pkg_name pkg_name "${util}" || return 1
					add2list missing_utils "${util}" " "
					add2list missing_packages "${blue}${pkg_name}${n_c}" ", "
					missing_utils_print="${missing_utils_print}${missing_utils_print:+, }${blue}GNU ${util}${n_c}"
			esac
		done

		# make a list of GNU utils to install
		if [ -n "${missing_utils}" ]
		then
			free_space_KB="$(df -k /usr/ | tail -n1 | $SED_CMD -E 's/^[ \t]*([^ \t]+[ \t]+){3}//;s/[ \t]+.*//')"
			mount_point="$(df -k /usr/ | tail -n1 | $SED_CMD -E 's/.*[ \t]+//')"

			is_uint "${free_space_KB}" || { reg_failure "Failed to check available free space."; return 1; }

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
					eval "util_size_B=\"\${${util}_size_B}\""
					bytes2human util_size_human "${util_size_B}" || return 1
					print_msg "Would you like to install ${blue}GNU ${util}${n_c} automatically? Installed size: ${yellow}${util_size_human}${n_c}. (y|n)"
					pick_opt "y|n" || return 1
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
				print_msg "" "Selected packages: ${blue}${pkgs2install% }${n_c}" \
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
					reg_failure "Failed to automatically install packages. You can install them manually later."
					return 1
				else
					reg_failure "Not enough free space at mount point '${mount_point}'."
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

	[ -f "${ABL_SERVICE_PATH}" ] || { reg_failure "adblock-lean service file doesn't exist at ${ABL_SERVICE_PATH}."; return 1; }

	# make the script executable
	if [ ! -x "${ABL_SERVICE_PATH}" ]
	then
		reg_msg -purple "" "Making ${ABL_SERVICE_PATH} executable."
		chmod +x "${ABL_SERVICE_PATH}" || { reg_failure "Failed to make '${ABL_SERVICE_PATH}' executable."; return 1; }
	else
		reg_msg -green "" "${ABL_SERVICE_PATH} is already executable."
	fi

	REPLY=n

	if [ -s "${ABL_CONFIG_FILE}" ]
	then
		if [ "${DO_DIALOGS}" = 1 ]
		then
			print_msg "" "Existing config file found." "Generate [n]ew config or use [e]xisting config? (n|e)"
			pick_opt 'n|e' || return 1
		elif [ -n "${luci_use_old_config}" ]
		then
			REPLY=e
		fi
	fi

	if [ "${REPLY}" = n ]
	then
		# generate config
		gen_config || return 2
	else
		load_config -force || return 3

		get_dnsmasq_instances &&
		check_dnsmasq_instances || return 1
	fi

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

	# create addnmount entries - enables blocklist compression and adblocking on multiple instances
	create_addnmounts || return 1

	if [ "${DO_DIALOGS}" = 1 ]
	then
		print_msg "" "${purple}Setup is complete.${n_c}" "" "Start adblock-lean now? (y|n)"
		pick_opt "y|n" || return 1
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
#  1: preset name (mini|small|medium|large|large_relaxed)
# Output via vars:
#  2: entries count
#  3: lists count
#  4: limit coeff
#  5: mem
#  6: list identifiers
#  7: max part size
#  8: max blocklist size
#  9: min line count
get_preset()
{
	local gp_mem gp_lists_cnt gp_entr_cnt gp_lim_coeff gp_lists gp_entr_cnt_human gp_max_part_size gp_max_bl_size gp_min_lines

	eval "gp_mem=\"\${${1}_mem}\"
		gp_lists_cnt=\"\${${1}_lists_cnt}\"
		gp_entr_cnt=\"\${${1}_cnt}\"
		gp_lim_coeff=\"\${${1}_coeff}\"
		gp_lists=\"\${${1}_lists}\""

	: "${gp_lim_coeff:=1}"

	assert_set F_get_preset gp_mem gp_lists_cnt gp_entr_cnt gp_lim_coeff gp_lists || return 1

	unset_vars "${2}" "${3}" "${4}" "${5}" "${6}" "${7}" "${8}" "${9}" || return 1

	do_calculate_limits "${gp_entr_cnt}" "${gp_lists_cnt}" "${gp_lim_coeff}" gp_min_lines gp_max_bl_size gp_max_part_size || return 1

	[ -n "${GP_PRINT_DESC}" ] && print_msg "" "${purple}${1}${n_c}: recommended for devices with ${gp_mem} MB of memory."

	[ -n "${GP_PRINT_VALS}" ] &&
	{
		int2human gp_entr_cnt_human "${gp_entr_cnt}" || return 1
		print_msg "${blue}Elements count:${n_c} ~${gp_entr_cnt_human}" \
			"${blue}raw_block_lists${n_c}=\"${gp_lists}\"" \
			"${blue}max_file_part_size_KB${n_c}=\"${gp_max_part_size}\"" \
			"${blue}max_blocklist_file_size_KB${n_c}=\"${gp_max_bl_size}\"" \
			"${blue}min_good_line_count${n_c}=\"${gp_min_lines}\""
	}

	eval "${2:-_}"='${gp_entr_cnt}' \
		"${3:-_}"='${gp_lists_cnt}' \
		"${4:-_}"='${gp_lim_coeff}' \
		"${5:-_}"='${gp_mem}' \
		"${6:-_}"='${gp_lists}' \
		"${7:-_}"='${gp_max_part_size}' \
		"${8:-_}"='${gp_max_bl_size}' \
		"${9:-_}"='${gp_min_lines}' || return 1
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
#  5: max blocklist size
#  6: max part size
do_calculate_limits()
{
	# keeps first two digits, replaces others with 0's
	# 1 - var for I/O
	reasonable_round()
	{
		local input factor neg='' me=reasonable_round
		eval "input=\"\${${1}}\""
		case "${input}" in -*) neg='-' input="${input#-}"; esac
		input="${input#"${input%%[!0]*}"}"
		: "${input:=0}"
		case "${input}" in
			*[!0-9]*) reg_failure "${me}: invalid input '${input}'."; return 1 ;;
			?|??) return 0 ;;
			????????????*) reg_failure "${me}: input '${input}' too large."; return 1 ;;
			*)
				factor=$(( 10**(${#input}-2) ))
				eval "${1}=${neg}$(( (input/factor) * factor ))"
		esac
		:
	}

	local me=calculate_limits lists_cnt tgt_entries_cnt='' tgt_entries_cnt_human lim_coeff final_entry_size_B source_entry_size_B \
		cl_min_lines cl_max_bl_size_kb cl_max_part_size_kb \
		tgt_entries_cnt="${1}" lists_cnt="${2}" lim_coeff="${3:-1}"

	unset_vars "${4}" "${5}" "${6}" || return 1

	[ -z "${tgt_entries_cnt}" ] && [ -n "${CL_INTERACTIVE}" ] &&
	while :
	do
		print_msg "Enter target entries count for the final blocklist:"
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

	[ "${tgt_entries_cnt}" -gt 0 ] || { reg_failure "${me}: Invalid entries count '${tgt_entries_cnt}'."; return 1; }
	[ "${lists_cnt}" -gt 0 ] || { reg_failure "${me}: Invalid URLs count '${lists_cnt}'."; return 1; }

	# Default values calculation:
	# Values are rounded down to reasonable degree

	final_entry_size_B=20 # assumption
	source_entry_size_B=20 # assumption for raw domains format. dnsmasq source format not used by default

	# tgt_entries_cnt / 3.5
	cl_min_lines=$((tgt_entries_cnt*10/35))
	reasonable_round cl_min_lines || return 1

	# (tgt_entries_cnt * final_entry_size_B * lim_coeff * 1.25)/1024
	cl_max_bl_size_kb=$(( (tgt_entries_cnt*final_entry_size_B*lim_coeff*125)/(1024*100) + 1 ))
	reasonable_round cl_max_bl_size_kb || return 1

	if [ "${lists_cnt}" -eq 1 ]
	then
		cl_max_part_size_kb=${cl_max_bl_size_kb}
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
			"${blue}max_file_part_size_KB${n_c}=\"${cl_max_part_size_kb}\"" \
			"${blue}max_blocklist_file_size_KB${n_c}=\"${cl_max_bl_size_kb}\"" \
			"${blue}min_good_line_count${n_c}=\"${cl_min_lines}\""
	}

	eval "${4:-_}"='${cl_min_lines}' "${5:-_}"='${cl_max_bl_size_kb}' "${6:-_}"='${cl_max_part_size_kb}' || return 1
	:
}

# (optional) -d to print with allowed value types (otherwise print without)
# (optional) -p to print with values from preset
# (optional) -n to print with DNSMASQ_INDEXES
# (optional) -c to print with DNSMASQ_CONF_DIRS
print_def_config()
{
	# follow each default option with '@' and a pre-defined type: string, integer (implies unsigned integer), integer_list
	# or custom optional values, examples: opt1, opt1|opt2, ''|opt1|opt2

	# process args
	local me=print_def_config preset='' print_types='' dnsmasq_indexes='' dnsmasq_conf_dirs='' \
		pdc_lists pdc_max_part_size pdc_max_bl_size pdc_min_lines
	while getopts ":n:c:p:d" opt; do
		case $opt in
			n) dnsmasq_indexes=$OPTARG ;;
			c) dnsmasq_conf_dirs=$OPTARG ;;
			p) preset=$OPTARG ;;
			d) print_types=1 ;;
			*) ;;
		esac
	done

	: "${preset:=small}"
	is_included "${preset}" "${ALL_PRESETS}" " " || { reg_failure "${me}: \$preset has invalid value '${preset}'."; return 1; }

	get_preset "${preset}" _ _ _ _ pdc_lists pdc_max_part_size pdc_max_bl_size pdc_min_lines &&
	assert_set "F_${me}" pdc_lists pdc_max_part_size pdc_max_bl_size pdc_min_lines || return 1

	cat <<-EOT | if [ -n "${print_types}" ]; then cat; else $SED_CMD 's/[ \t]*@.*//'; fi

	# adblock-lean configuration options
	# config_format=${CONFIG_FORMAT}
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

	# One or more *dnsmasq* format [blocklist]/[ipv4 blocklist]/[allowlist] URLs and/or short list identifiers separated by spaces
	dnsmasq_block_lists="" @ string
	dnsmasq_allow_lists="" @ string
	dnsmasq_ipv4_block_lists="" @ string

	# One or more *hosts* format blocklist URLs and/or short list identifiers separated by spaces
	hosts_block_lists="" @ string

	# Path to optional local *raw domain* allowlist/blocklist files in the form:
	# site1.com
	# site2.com
	local_allowlist_path="${ABL_CONFIG_DIR}/allowlist" @ string
	local_blocklist_path="${ABL_CONFIG_DIR}/blocklist" @ string

	# Governs whether and how persistent blocklist is used
	# 'disable' (default): persistent blocklist will not be used. The blocklist file will be stored on the ramdisk.
	# 'manual': directory specified in PERSIST_BLOCKLIST_DIR will be checked for file named '${BLOCKLIST_BASE_FNAME:?}' (with or without extension '.gz' or '.zst') -
	#   if found, that blocklist will be loaded at boot (rather than downloading, processing and loading a new blocklist)
	#   but adblock-lean will not create or update that file (useful to prevent flash wear, e.g. when the persistent blocklist is stored on the built-in flash of a router).
	#   If not found, adblock-lean will act as if mode is 'disable'.
	# 'managed': adblock-lean will use the directory specified in PERSIST_BLOCKLIST_DIR to store and update the blocklist file
	#   and no additional blocklist will be stored on the ramdisk.
	#   If the directory is inaccessible, adblock-lean will fall back to using the ramdisk.
	PERSIST_BLOCKLIST_MODE="disable" @ disable|manual|managed

	# Optional path to directory on non-volatile storage device where persistent blocklist should be stored
	PERSIST_BLOCKLIST_DIR="" @ string

	# Test domains are automatically querried after loading the blocklist into dnsmasq,
	# in order to verify that the blocklist didn't break DNS resolution
	# If query for any of the test domains fails, previous blocklist is restored from backup
	# If backup doesn't exist, the blocklist is removed and adblock-lean is stopped
	# Leaving this empty will disable verification
	test_domains="google.com microsoft.com amazon.com" @ string

	# List part failed action:
	# This option applies to blocklist/allowlist parts which failed to download or couldn't pass validation checks
	# SKIP - skip failed blocklist file part and continue blocklist generation
	# STOP - stop blocklist generation (and fall back to previous blocklist if available)
	list_part_failed_action="SKIP" @ SKIP|STOP

	# Maximum number of download retries
	max_download_retries="3" @ integer

	# Default download mirrors.
	# Hagezi mirror: 'github' or 'gitlab'
	hagezi_default_mirror="github" @ github|gitlab
	# oisd mirror: 'oisd' or 'github'
	oisd_default_mirror="oisd" @ oisd|github
	# Steven Black mirror: 'github' or 'sbc_io' for sbc.io
	stevenblack_default_mirror="github" @ github|sbc_io

	# Minimum number of good lines in final postprocessed blocklist
	min_good_line_count="${pdc_min_lines}" @ integer

	# Mininum number of lines of any individual downloaded part
	min_blocklist_part_line_count="1" @ integer
	min_ipv4_blocklist_part_line_count="1" @ integer
	min_allowlist_part_line_count="1" @ integer

	# Maximum size of any individual downloaded blocklist part
	max_file_part_size_KB="${pdc_max_part_size}" @ integer

	# Maximum total size of combined, processed blocklist
	max_blocklist_file_size_KB="${pdc_max_bl_size}" @ integer

	# Whether to perform sorting and deduplication of entries (usually doesn't cause much slowdown, uses a bit more memory) - enable (1) or disable (0)
	deduplication="1" @ 0|1

	# Utility to compress final blocklist, intermediate blocklist parts and the backup blocklist to save memory
	# Supported options: gzip, pigz, zstd or 'none' to disable compression
	compression_util="gzip" @ gzip|pigz|zstd|none

	# Compression options: passed as-is to the compression utility
	# Available options depend on the compression utility. '-[n]' universally specifies compression level.
	# Busybox gzip ignores any options.
	#   Intermediate compression. Default: '-3'.
	intermediate_compression_options="-3" @ string
	#   Final blocklist compression. Default: '-6'
	final_compression_options="-6" @ string

	# unload previous blocklist form memory and restart dnsmasq before generation of
	# new blocklist in order to free up memory during generation of new blocklist - 'auto' or enable (1) or disable (0)
	unload_blocklist_before_update="auto" @ auto|0|1

	# Start delay in seconds when service is started from system boot
	boot_start_delay_s="30" @ integer

	# Maximal count of download and processing jobs run in parallel. 'auto' sets this value to the count of CPU cores
	MAX_PARALLEL_JOBS="auto" @ auto|integer

	# If a path to custom script is specified and that script defines functions
	# 'report_success()', 'report_failure()' or 'report_update()',
	# one of these functions will be executed when adblock-lean completes the execution of some commands,
	# with corresponding message passed in first argument
	# report_success() and report_update() are only executed upon completion of the 'start' command
	# Recommended path is '/usr/libexec/abl_custom-script.sh' which the luci app has permission to access
	custom_script="" @ string

	# Crontab schedule expression for periodic list updates
	cron_schedule="${cron_schedule:-"0 5 * * *"}" @ string

	# dnsmasq instance indexes and config directories
	# normally this should be set automatically by the 'setup' command
	DNSMASQ_INDEXES="${dnsmasq_indexes}" @ integer_list
	DNSMASQ_CONF_DIRS="${dnsmasq_conf_dirs}" @ string

	# Log verbosity (0-5). Higher values send more messages to the syslog. Default is 1.
	LOG_VERBOSITY="1" @ 0|1|2|3|4|5

	EOT
}

# generates config
do_gen_config()
{
	# sets ${1} to recommended preset, depending on system memory capacity; ${2} to detected totalmem
	get_def_preset()
	{
		unset_vars "${1}" "${2}" &&
		assert_set F_get_def_preset ALL_PRESETS "${ALL_PRESETS%% *}_mem" || return 1

		local _totalmem _mem _preset IFS="${DEFAULT_IFS}"

		read -r _ _totalmem _ < /proc/meminfo

		is_uint "${_totalmem}" ||
		{
			reg_failure "\$_totalmem has invalid value '${_totalmem}'. Failed to determine system memory capacity."
			log_msg "Unable to select best preset for this system."
			return 1
		}

		for _preset in $(printf %s "${ALL_PRESETS}" | tr ' ' '\n' | ${SED_CMD} 'x;1!H;$!d;x') # loop over presets in reverse order
		do
			eval "_mem=\"\${${_preset}_mem}\""
			# multiplying by 800 rather than 1024 to account for some memory not available to the kernel
			[ "${_totalmem}" -ge $((_mem * 800)) ] && break
		done

		eval "${1}"='${_preset}' "${2}"='${_totalmem}'
		:
	}

	local cnt totalmem totalmem_human preset

	if [ "${DO_DIALOGS}" = 1 ] && [ -z "${luci_preset}" ]
	then
		get_def_preset preset totalmem || print_msg "Skipping automatic preset recommendation."
		if [ -n "${preset}" ]
		then
			bytes2human totalmem_human $((totalmem*1024)) || return 1
			print_msg "" "Based on the total usable memory of this device (${totalmem_human}), the recommended preset is '${purple}${preset}${n_c}':"
			GP_PRINT_DESC=1 GP_PRINT_VALS=1 get_preset "${preset}" || return 1
			print_msg "" "[C]onfirm this preset or [p]ick another preset?"
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
			print_msg "" "Pick preset:"
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

	is_included "${preset}" "${ALL_PRESETS}" " " || { reg_failure "Invalid preset '${preset}'."; return 1; }
	reg_msg -blue "Selected preset '${preset}'."

	do_select_dnsmasq_instances -n || { reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."; return 1; }

	# create cron job
	cron_schedule=
	local def_schedule="0 5 * * *" def_schedule_desc="daily at 5am (5 o'clock at night)"

	REPLY=n
	if [ "${DO_DIALOGS}" = 1 ]
	then
		print_msg "" "${purple}Cron job configuration:${n_c}" \
			"A cron job can be created to enable automatic list updates." \
			"The default schedule is '${blue}${def_schedule}${n_c}': ${def_schedule_desc}" \
			"The cron job will run with an added random number of minutes." \
			"" "Create cron job with default schedule for automatic list updates? (y|n)" \
			"'n' will set the 'cron_schedule' setting to 'disable'. You can later create a cron job with a custom schedule as described in:" \
			"https://github.com/lynxthecat/adblock-lean/blob/master/README.md"
		pick_opt "y|n" || return 1
		cron_schedule="${def_schedule}"
	elif [ -n "${luci_upd_cron_job}" ] && [ -n "${luci_cron_schedule}" ]
	then
		REPLY=y
		cron_schedule="${luci_cron_schedule}"
	elif  [ -n "${luci_upd_cron_job}" ]
	then
		reg_failure "Can not create cron job for luci because the \${luci_cron_schedule} var is empty."
	fi
	[ "${REPLY}" = n ] && cron_schedule=disable

	reg_action -purple "" "Generating new default config for adblock-lean from preset '${preset}'." || return 1
	write_config "$(print_def_config -p "${preset}" -n "${DNSMASQ_INDEXES}" -c "${DNSMASQ_CONF_DIRS}")" || return 1

	:
}

# validate config and assign to variables
#
# 1 - path to file
# Optional:
#   2 - var to output conf fixes
#   3 - var to output keys requiring replacement
#   4 - var to output keys requiring migration
#
# return codes:
# 0 - Success
# 1 - Config error with no automatic fix
# 2 - Unexpected, missing or legacy-formatted (no double quotes) entries found
# 3 - Internal parser error
#
# sets variables for luci:
# *_curr_config_format *_def_config_format *_unexp_keys *_unexp_entries *_missing_keys *_missing_entries
#     *_bad_conf_format *_conf_fixes *_bad_value_keys
parse_config()
{
	add_conf_fix() { p_conf_fixes="${p_conf_fixes}${1}"$'\n'; }

	local def_config='' curr_config='' \
		i keys entries entry_type_print_lc \
		p_migrated_keys='' migrate_keys='' migrate_entries='' \
		bad_val_entries='' corrected_entries='' \
		p_conf_fixes='' missing_keys='' bad_val_keys='' \
		sed_conf_san_exp='/^\s*#.*$/d; s/^\s+//; s/\s+=/=/; s/=\s+/=/; s/\s+$//; /^$/d'

	unset_vars "${2}" "${3}" "${4}" || return 1

	unset curr_config_format def_config_format \
		luci_curr_config_format luci_def_config_format luci_unexp_keys luci_unexp_entries luci_missing_keys luci_missing_entries \
		luci_bad_conf_format luci_conf_fixes preset

	# newline-separated list of options to migrate in the format <old_key=new_key>
	MIGRATE_OPTS='
		DNSMASQ_INDEX=DNSMASQ_INDEXES
		DNSMASQ_CONF_D=DNSMASQ_CONF_DIRS
		blocklist_urls=raw_block_lists
		allowlist_urls=raw_allow_lists
		blocklist_ipv4_urls=raw_ipv4_block_lists
		dnsmasq_blocklist_urls=dnsmasq_block_lists
		dnsmasq_blocklist_ipv4_urls=dnsmasq_ipv4_block_lists
		dnsmasq_allowlist_urls=dnsmasq_allow_lists
		min_blocklist_ipv4_part_line_count=min_ipv4_blocklist_part_line_count
	'
	local IFS="${_NL_}" migrate_opts_tmp='' opt
	# remove leading and trailing spaces/tabs
	for opt in ${MIGRATE_OPTS}
	do
		[ -n "${opt}" ] || continue
		opt="${opt#"${opt%%[! 	]*}"}"
		opt="${opt%"${opt##*[! 	]}"}"
		migrate_opts_tmp="${migrate_opts_tmp}${opt}${_NL_}"
	done
	IFS="${DEFAULT_IFS}"
	MIGRATE_OPTS="${migrate_opts_tmp}"

	[ -z "${1}" ] && { reg_failure "parse_config(): no file specified."; return 3; }

	[ ! -f "${1}" ] && { reg_failure "Config file '${1}' not found."; return 1; }

	try_mkdir -p "${ABL_CONF_STAGING_DIR}" || return 1

	# extract entries from default config
	def_config="$(print_def_config)" || return 3

	# read and sanitize current config
	curr_config="$($SED_CMD "${sed_conf_san_exp}" "${1}")" || { reg_failure "Failed to read the config file '${1}'."; return 1; }

	local bad_newline=
	case "${curr_config}" in
		*"${CR_LF}"*) bad_newline="Windows-format (CR_LF)" ;;
		*"${CR}"*) bad_newline="MacOS-format (CR)" ;;
	esac
	[ -n "${bad_newline}" ] &&
	{
		reg_failure "Config file contains ${bad_newline} newlines. Convert the config file to Unix-format (LF) newlines."
		return 1
	}

	# get config versions
	curr_config_format="$(get_config_format "${1}")"
	export luci_curr_config_format="${curr_config_format}"
	def_config_format="$(printf %s "${def_config}" | get_config_format)"
	export luci_def_config_format="${def_config_format}"

	local parse_vars valid_lines entry_type
	# extract valid values from default config
	valid_lines="$(print_def_config -d | ${SED_CMD} "${sed_conf_san_exp}")"
	# parse config
	local parser_err_file="${ABL_CONF_STAGING_DIR}/parser_err" \
		awk_err_file="${ABL_CONF_STAGING_DIR}/awk_err" \
		inval_entry_file="${ABL_CONF_STAGING_DIR}/inval_entry"
	rm -f "${parser_err_file}" "${awk_err_file}" "${inval_entry_file}"
	for entry_type in unexp bad_val missing dup migrate
	do
		rm -f "${ABL_CONF_STAGING_DIR}/${entry_type}_entries"
	done

	parse_vars="$(
		printf '%s\n' "${curr_config}" |
		${AWK_CMD} -F"=" -v q="'" -v V="${valid_lines}" -v M="${MIGRATE_OPTS}" -v A="${ABL_CONF_STAGING_DIR}" '
		# return codes: 0=OK, 1=awk or default config error, 253=check double-quotes, 254=Invalid entry detected

		function check_value(key,val)
		{
			regex="^(" valid_values_regex_arr[key] ")$"
			if (val !~ regex) {
				return 1
			}
			return 0
		}

		BEGIN{
			rv=0
			line_comp[1]="key"
			line_comp[2]="value"
			line_comp[3]="allowed values"

			# create validation arrays
			split(V,def_lines_arr,"\n")
			for (ind in def_lines_arr) {
				# remove whitespaces/tabs
				sub(/"[ \t]*@[ \t]*/,"\"@",def_lines_arr[ind])
				def_lines_arr[ind]=def_lines_arr[ind]
				# validate default config line
				n=split(def_lines_arr[ind],def_line_parts,"[=@]") # split into key, value, allowed values
				if (n!=3) {print "Invalid line in default config: " q def_lines_arr[ind] q "." > A"/parser_err"; rv=1; exit}
				for (i in def_line_parts) {
					if (! def_line_parts[i]) {
						print "Invalid line in default config: " q def_lines_arr[ind] q " is missing the " line_comp[i] "." > A"/parser_err"
						rv=1
						exit
					}
				}

				key=def_line_parts[1]
				def_arr[key]=def_line_parts[2]
				valid_values=def_line_parts[3]

				# create entry-specific validation regex array, printable valid values array
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
					if ( ! sub(/integer_list/,"[ 	]*[0-9]+([ 	]+[0-9]+)*[ 	]*",val_regex) )
						sub(/integer/,"[0-9]+",val_regex)
					valid_values_regex_arr[key]=val_regex
					valid_values_seen_regex_arr[valid_values]=val_regex

					val_print=valid_values
					if ( ! sub(/integer_list/,"space-separated list of non-negative integers",val_print) )
						sub(/integer/,"non-negative integer",val_print)
					gsub(/\|/," or ", val_print)
					valid_values_print_arr[key]=val_print
					valid_values_seen_print_arr[valid_values]=val_print
				}
			}

			# create migrate_keys_arr
			split(M,migrate_lines_arr,"\n")
			for (ind in migrate_lines_arr)
			{
				line=migrate_lines_arr[ind]
				n = index(line, "=")
				if(n)
				{
					old_key = substr(line, 1, n-1)
					new_key = substr(line, n+1)
					migrate_keys_arr[old_key] = new_key
				}
			}

		}

		# process user config
		{
			# handle double or missing =
			if ( $0 !~ /^[^=]+=[^=]+([ \t]+(#.*){0,1})*$/ ) {
				print $0 > A"/inval_entry"
				rv=254
				exit
			}

			# key must be non-empty and alphanumeric
			if ( $1 !~ /^[a-zA-Z0-9_]+$/ ) {
				print $0 > A"/inval_entry"
				rv=254
				exit
			}

			# line must have exactly 2 double-quotes after = and no characters before #
			if ( $0 !~ /^[^"]+="[^"]*"([ \t]+(#[^"]*){0,1}){0,1}$/ ) {
				print $0 > A"/inval_entry"
				rv=253
				exit
			}

			# get value
			split($2,tmp,"\"")
			val=tmp[2]

			# handle migrated keys
			if ($1 in migrate_keys_arr) {
				new_key=migrate_keys_arr[$1]
				if (check_value(new_key,val) == 0)
				{
					migrated_keys_arr[new_key]
					migrate_keys=migrate_keys $1 " "
					migrated_keys=migrated_keys new_key " "
					migrate_opts=migrate_opts "MIGRATE_" new_key "=\"" val "\"\n"
					print $0 >> A"/migrate_entries"
					next
				}
			}

			# handle duplicate keys
			if ($1 in config_keys) {
				dup_keys=dup_keys $1 " "
				print $0 >> A"/dup_entries"
				next
			}

			# handle unexpected keys
			if ($1 in def_arr) {} else {
				unexp_keys=unexp_keys $1 " "
				print $0 >> A"/unexp_entries"
				next
			}

			# register the key
			config_keys[$1]

			# handle unexpected values
			if (check_value($1,val) != 0)
			{
				bad_val_keys=bad_val_keys $1 " "
				print $1 "=" $2 " (should be " valid_values_print_arr[$1] ")" >> A"/bad_val_entries"
				print $1 "=" def_arr[$1] >> A"/corrected_entries"
				next
			}

			print $1 "=\"" val "\""
		}

		END{
			if (rv != 0) {exit rv}
			for (key in def_arr) {
				if (key in config_keys || key in migrated_keys_arr) {} else {
					print key "=" def_arr[key] >> A"/missing_entries"
					missing_keys=missing_keys key " "
				}
			}
			print "missing_keys=\"" missing_keys "\" " \
				"migrate_keys=\"" migrate_keys "\" " \
				"p_migrated_keys=\"" migrated_keys "\" " \
				"unexp_keys=\"" unexp_keys "\" " \
				"dup_keys=\"" dup_keys "\" " \
				"bad_val_keys=\"" bad_val_keys "\" " \
				"\n" migrate_opts
			exit rv
		}' 2>"${awk_err_file}"
	)" && [ ! -s "${awk_err_file}" ] && [ ! -s "${parser_err_file}" ] ||
	{
		local awk_rv=${?} inval_entry=''
		[ -s "${awk_err_file}" ] && reg_failure "awk errors encountered while parsing config:${_NL_}$(cat "${awk_err_file}")"
		[ -s "${parser_err_file}" ] && reg_failure "$(cat "${parser_err_file}")"
		[ -s "${inval_entry_file}" ] && inval_entry=": '$(cat "${inval_entry_file}")'"

		case "${awk_rv}" in
			253) reg_failure "Invalid entry in config (check double-quotes)${inval_entry}" ;;
			254) reg_failure "Invalid entry in config${inval_entry}" ;;
			*) reg_failure "Failed to parse config."; return 3
		esac

		return 1
	}

	local err_print=''
	rm -f "${parser_err_file}"

	eval "${parse_vars}" 2> "${parser_err_file}" && [ ! -s "${parser_err_file}" ] ||
	{
		[ -s "${parser_err_file}" ] && err_print=" Errors: ${_NL_}$(cat "${parser_err_file}")"
		reg_failure "Failed to parse config.${err_print}"
		return 3
	}

	if [ -n "${migrate_keys}" ]
	then
		log_msg -yellow "" "Following config options need to be migrated (option name has changed): '${migrate_keys% }'."
		migrate_entries="$(cat "${ABL_CONF_STAGING_DIR}/migrate_entries")"
		print_msg "Corresponding config entries:" "${migrate_entries%$'\n'}"
		add_conf_fix "Migrate config entries"
		export luci_migrate_keys="${migrate_keys% }" luci_migrate_entries="${migrate_entries%$'\n'}"
	fi

	for i in \
		"dup|duplicate|Duplicate|Remove duplicate entries from the config" \
		"unexp|unexpected|Unexpected|Remove unexpected entries from the config" \
		"missing|missing|Missing|Re-add missing config entries with default values"
	do
		entry_type="${i%%|*}"
		eval "keys=\"\${${entry_type}_keys% }\""
		[ -n "${keys}" ] || continue

		i="${i#"${entry_type}|"}"
		entry_type_print_lc="${i%%|*}"
		i="${i#"${entry_type_print_lc}|"}"

		log_msg -yellow "" "${i%%|*} keys in config: '${keys}'."
		entries="$(cat "${ABL_CONF_STAGING_DIR}/${entry_type}_entries")"
		print_msg "Corresponding config entries:" "${entries%$'\n'}"
		add_conf_fix "${i##*|}"
		export "luci_${entry_type}_keys"="${keys}" "luci_${entry_type}_entries"="${entries%$'\n'}"
	done

	if [ -n "${bad_val_keys}" ]
	then
		log_msg -yellow "" "Detected config entries with unexpected values."
		bad_val_entries="$(cat "${ABL_CONF_STAGING_DIR}/bad_val_entries")"
		corrected_entries="$(cat "${ABL_CONF_STAGING_DIR}/corrected_entries")"
		print_msg "Following config entries have unexpected values:" "${bad_val_entries%$'\n'}" "" \
			"Corresponding default config entries:" "${corrected_entries%$'\n'}"
		add_conf_fix "Replace unexpected values with defaults"
		export luci_bad_val_entries="${bad_val_entries%$'\n'}" luci_corrected_entries="${corrected_entries%$'\n'}"
	fi

	if [ -z "${p_conf_fixes}" ]
	then
		if is_uint "${curr_config_format}"
		then
			if [ "${curr_config_format}" != "${def_config_format}" ]
			then
				log_msg -yellow "" "Current config format version '${curr_config_format}' differs from default config version '${def_config_format}'."
				add_conf_fix "Update config format version"
			fi
		else
			log_msg -warn "" "Config format version is unknown or invalid."
			add_conf_fix "Update config format version"
		fi
	fi

	p_conf_fixes="${p_conf_fixes%$'\n'}"
	export luci_conf_fixes="${p_conf_fixes}"

	eval "${2:-_}=\"${p_conf_fixes}\" ${3:-_}=\"${missing_keys}${bad_val_keys}\" ${4:-_}=\"${p_migrated_keys}\""

	[ -n "${p_conf_fixes}" ] && return 2
	:
}

load_config()
{
	detect_main_utils || return 1 # for versions < 3 of abl-install.sh
	local in_install="${ABL_IN_INSTALL:-"${upd_channel}"}"
	[ -n "${CONFIG_LOADED}" ] && [ "${1}" != '-force' ] && [ -z "${in_install}" ] && return 0
	try_load_config || { reg_failure "Failed to load config." "Fix your config file '${ABL_CONFIG_FILE}' or generate default config using 'service adblock-lean gen_config'."; return 1; }
	export CONFIG_LOADED=1

	# check for missing addnmounts during version update
	if [ -n "${in_install}" ]
	then
		get_dnsmasq_instances &&
		create_addnmounts
	fi
	:
}

# shellcheck disable=SC2120
# 1 - (optional) '-f' to force fixing the config if it has issues
try_load_config()
{
	print_conf_fixes()
	{
		local fix cnt=0 IFS="${_NL_}"
		for fix in ${l_conf_fixes}
		do
			IFS="${DEFAULT_IFS}"
			[ -z "${fix}" ] && continue
			cnt=$((cnt+1))
			print_msg "${cnt}. ${fix}"
		done
		IFS="${DEFAULT_IFS}"
	}

	local force_fix='' l_replace_keys='' l_migrated_keys='' l_conf_fixes=''
	[ -n "${ABL_LUCI_SOURCED}" ] || [ -n "${APPROVE_UPD_CHANGES}" ] && force_fix=1

	[ -z "${DO_DIALOGS}" ] && [ -z "${ABL_LUCI_SOURCED}" ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] &&
		DO_DIALOGS=1

	if [ ! -f "${ABL_CONFIG_FILE}" ]
	then
		reg_failure "Config file is missing."
		return 1
	fi

	# validate config and assign to variables
	local parse_ok=
	parse_config "${ABL_CONFIG_FILE}" l_conf_fixes l_replace_keys l_migrated_keys
	case ${?} in
		0) parse_ok=1 ;;
		1) return 1 ;; # config error with no automatic fix
		2) ;; # config error(s) with automatic fix
		3) return 1 # internal parser error
	esac

	# remove trailing '/' from dir paths
	PERSIST_BLOCKLIST_DIR="${PERSIST_BLOCKLIST_DIR%/}"

	if [ -z "${parse_ok}" ]
	then
		# if not in interactive console and force-fix not set, return error
		[ "${DO_DIALOGS}" != 1 ] && [ -z "${force_fix}" ] && return 1

		# sanity check
		[ -z "${l_conf_fixes}" ] && { reg_failure "Failed to parse config."; return 1; }

		if [ "${DO_DIALOGS}" = 1 ] && [ -z "${force_fix}" ]
		then
			if [ -n "${l_conf_fixes}" ]
			then
				print_msg -blue "" "Perform following automatic changes? (y|n)"
				print_conf_fixes
				pick_opt "y|n" || return 1
			fi
		else
			print_msg -blue "" "Performing following config changes:"
			print_conf_fixes
			REPLY=y
		fi

		[ "${REPLY}" = n ] && return 1

		fix_config "${l_replace_keys}" "${l_migrated_keys}" || { reg_failure "Failed to fix the config."; return 1; }
	fi

	:
}

# 1 - keys to replace (whitespace-separated)
# 2 - keys to migrate
fix_config()
{
	rebuild_config()
	{
		local def_line key curr_val replace_keys="${1}" migrated_keys="${2}"
		print_def_config -n "${DNSMASQ_INDEXES}" -c "${DNSMASQ_CONF_DIRS}" |
		while IFS="${_NL_}" read -r def_line
		do
			case "${def_line}" in
				\#*|'') printf '%s\n' "${def_line}"; continue ;;
				*=*)
					key=${def_line%%=*}
					if is_included "${key}" "${replace_keys}" " "
					then
						printf '%s\n' "${def_line}"
						continue
					fi

					if is_included "${key}" "${migrated_keys}" " "
					then
						eval "[ -n \"\${MIGRATE_${key}+set}\" ]" ||
							{ reg_failure "fix_config: '\$MIGRATE_${key}' not set."; return 1; }
						eval "curr_val=\"\${MIGRATE_${key}}\""
					else
						eval "curr_val=\"\${${key}}\""
					fi
					printf '%s\n' "${key}=\"${curr_val}\""
					continue
			esac
		done
		:
	}

	local replace_keys="${1}" migrated_keys="${2}" fixed_config

	if is_included DNSMASQ_INDEXES "${replace_keys}" " " || is_included DNSMASQ_CONF_DIRS "${replace_keys}" " "
	then
		do_select_dnsmasq_instances -n || return 1
		# shellcheck disable=SC2034
		MIGRATE_DNSMASQ_INDEXES="${DNSMASQ_INDEXES}" MIGRATE_DNSMASQ_CONF_DIRS="${DNSMASQ_CONF_DIRS}"
	fi

	# recreate config from default while replacing values with values from the existing config
	fixed_config="$(rebuild_config "${replace_keys}" "${migrated_keys}")" || return 1

	local old_config_f="/tmp/adblock-lean_config.old"
	if ! cp "${ABL_CONFIG_FILE}" "${old_config_f}"
	then
		reg_failure "Failed to save old config file as ${old_config_f}."
		if [ -z "${APPROVE_UPD_CHANGES}" ]
		then
			[ "${DO_DIALOGS}" = 1 ] || return 1
			print_msg "Proceed with suggested config changes? (y|n)"
			pick_opt "y|n" || return 1
			[ "${REPLY}" = n ] && return 1
		fi
	else
		reg_msg "" "Old config file was saved as ${old_config_f}."
	fi

	write_config "${fixed_config}" || return 1

	:
}

# Writes config to temp file, validates it, moves it to permanent storage
# 1 - new config file contents
write_config()
{
	local tmp_config="${ABL_CONF_STAGING_DIR}/write-config.tmp"

	[ -z "${1}" ] && { reg_failure "write_config(): no config passed."; return 1; }

	if [ "${DO_DIALOGS}" = 1 ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ -f "${ABL_CONFIG_FILE}" ]
	then
		print_msg "This will overwrite existing config. Proceed? (y|n)"
		pick_opt "y|n" && [ "${REPLY}" != n ] || return 1
	fi

	try_mkdir -p "${ABL_CONF_STAGING_DIR}" || return 1
	printf '%s\n' "${1}" > "${tmp_config}" || { reg_failure "Failed to write to file '${tmp_config}'."; return 1; }
	parse_config "${tmp_config}" ||
		{ rm -f "${tmp_config}"; reg_failure "Failed to validate the new config."; return 1; }

	reg_msg "" "Saving new config file to '${ABL_CONFIG_FILE}'."
	try_mkdir -p "${ABL_CONFIG_DIR}" ||
		{
			rm -f "${tmp_config}"
			return 1
		}
	try_mv "${tmp_config}" "${ABL_CONFIG_FILE}" ||
		{
			rm -f "${tmp_config}"
			reg_failure "Failed to move file '${tmp_config}' to '${ABL_CONFIG_FILE}'."
			return 1
		}
	:
}


### HELPER FUNCTIONS

# Detect package manager (opkg or apk)
# Sets global vars: $PKG_MANAGER $PKG_INSTALL_CMD
detect_pkg_manager() {
	local apk_present='' opkg_present=''
	check_util apk && apk_present=1
	check_util opkg && opkg_present=1
	if [ -n "$apk_present" ] && [ -n "$opkg_present" ]
	then
		reg_failure "Both apk and opkg package managers present in the system."
		return 1
	fi

	if [ -n "$apk_present" ]
	then
		PKG_MANAGER=apk
		PKG_INSTALL_CMD="apk add"
	elif [ -n "$opkg_present" ]
	then
		PKG_MANAGER=opkg
		PKG_INSTALL_CMD="opkg install"
	else
		reg_failure "Failed to detect package manager."
		return 1
	fi
	:
}

report_utils()
{
	local util pkg_name awk_inst_tip='' sed_inst_tip='' sort_inst_tip=''

	printf '\n' > "${MSGS_DEST}"

	for util in ${RECOMMENDED_UTILS}
	do
		case "${PKG_MANAGER}" in
			opkg|apk)
				get_pkg_name pkg_name "${util}" || return 1
				eval "${util}_inst_tip=\" (${PKG_INSTALL_CMD} ${pkg_name})\"" ;;
			*)
				unset "${util}_inst_tip" ;;
		esac
	done

	case "${AWK_CMD}" in
		*gawk*) reg_msg -green "gawk detected so using gawk for fast (sub)domain match removal and entries packing." ;;
		*)
			reg_msg -yellow "gawk not detected so allowlist (sub)domains removal from blocklist will be slow and list processing will not be as efficient."
			reg_msg "Consider installing the gawk package${awk_inst_tip} for faster processing and (sub)domain match removal."
	esac

	case "${SED_CMD}" in
		*gnu*) reg_msg -green "GNU sed detected so list processing will be fast." ;;
		*)
			reg_msg -yellow "GNU sed not detected so list processing will be a little slower."
			reg_msg "Consider installing the GNU sed package${sed_inst_tip} for faster processing." ;;
	esac

	case "${SORT_CMD}" in
		*coreutils*) reg_msg -green "coreutils-sort detected so sort will be fast." ;;
		*)
			reg_msg -yellow "coreutils-sort not detected so sort will be a little slower."
			reg_msg "Consider installing the coreutils-sort package${sort_inst_tip} for faster sort." ;;
	esac
}

# 1: list of newline-separated paths
# Optional:
# 2: var name for printable missing paths output
# shellcheck disable=SC2120
check_addnmounts()
{
	try_check_addnmounts "${@}" || { reg_failure "Failed to check addnmount entries."; return 1; }
	:
}

try_check_addnmounts()
{
	# return codes:
	# 0 - addnmount present
	# 1 - error
	# 2 - addnmount not present
	check_addnmount()
	{
		local path="${1}" addnmounts="${2}"
		case "${path}" in
			/*) ;;
			*) reg_failure "check_addnmount: invalid path '${path}'."; return 1
		esac

		while [ -n "${path}" ]
		do
			is_included "${path}" "${addnmounts}" ' ' && return 0
			path="${path%/*}"
		done

		return 2
	}

	local me=check_addnmounts \
		ca_addnmounts index path \
		IFS="${DEFAULT_IFS}" \
		ca_missing_var="${1}" ca_req_addnm="${2}"

	unset_vars "${ca_missing_var}" &&
	assert_set "F_${me}" DNSMASQ_INDEXES ADDNMOUNTS_SET ca_req_addnm || return 1

	for index in ${DNSMASQ_INDEXES}
	do
		is_uint "${index}" || { reg_failure "${me}: Invalid dnsmasq index '${index}'."; return 1; }
		eval "ca_addnmounts=\"\${ADDNMOUNTS_${index}}\""
		IFS="${_NL_}"
		for path in ${ca_req_addnm}
		do
			[ -n "${path}" ] || continue
			IFS="${DEFAULT_IFS}"

			check_addnmount "${path}" "${ca_addnmounts}"
			case ${?} in
				0) ;;
				1) return 1 ;;
				*) [ -n "${ca_missing_var}" ] && add2list "${ca_missing_var}" "'${path}'" ", "
			esac
		done
		IFS="${DEFAULT_IFS}"
	done

	:
}

# return values:
# 0 - up-to-date
# 1 - not up-to-date
# 2 - update check failed
# 3 - automatic updates check is disabled for current update channel
check_for_updates()
{
	local tarball_url='' curr_ver='' upd_ver='' upd_channel='' no_upd=''
	unset UPD_AVAIL UPD_DIRECTIONS
	get_abl_version "${ABL_SERVICE_PATH}" curr_ver upd_channel
	case "${upd_channel}" in
		release|latest|snapshot|branch=*) ;;
		commit) no_upd="was installed from a specific Git commit" ;;
		'') no_upd="update channel is unknown" ;;
		*) no_upd="update channel is '${upd_channel}'" ;;
	esac
	[ -n "${no_upd}" ] && { print_msg "" "adblock-lean ${no_upd}. Automatic updates check is disabled."; return 3; }
	reg_action -blue "" "Checking for adblock-lean updates."
	rm -rf "${ABL_UPD_DIR}"
	try_mkdir -p "${ABL_UPD_DIR}" &&
	get_gh_ref "${upd_channel}" "" upd_ver tarball_url _
	local gh_ref_rv=${?}
	luci_tarball_url="${tarball_url}"

	rm -rf "${ABL_UPD_DIR}"

	[ "${gh_ref_rv}" != 0 ] &&
	{
		reg_failure "Failed to check for adblock-lean updates."
		return 2
	}

	if [ "${upd_ver}" = "${curr_ver}" ]
	then
		reg_msg "The locally installed adblock-lean is the latest version."
		return 0
	else
		local upd_details="(update channel: ${upd_channel}, installed: '${curr_ver}', latest: '${upd_ver}')"
		UPD_DIRECTIONS="Consider running: 'service adblock-lean update' to update it to the latest version."
		UPD_AVAIL_MSG="adblock-lean update is available ${upd_details}"
		: "${UPD_AVAIL_MSG}" # silence shellcheck warning
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

	hash crontab || { reg_failure "${enable_failed}: 'crontab' utility is inaccessible."; return 1; }
	[ -f "${ABL_CRON_SVC_PATH}" ] || { reg_failure "${enable_failed}: the cron service was not found at path '${ABL_CRON_SVC_PATH}'."; return 1; }

	check_cron_service && return 0
	log_msg -warn "The cron service is not enabled or not running."

	printf '\n%s' "${purple}Attempting to enable and start the cron service...${n_c} " > "${MSGS_DEST}"

	# if crontab doesn't exist yet, try to create an empty crontab
	crontab -u root -l &>/dev/null || printf '' | crontab -u root -

	# try to enable and start the cron service
	${ABL_CRON_SVC_PATH} enabled 1>/dev/null || ${ABL_CRON_SVC_PATH} enable && { ${ABL_CRON_SVC_PATH} start; sleep 2; }

	check_cron_service || { printf '%s\n' "${red}Failed${n_c}"; reg_failure "${enable_failed}."; return 1; }
	printf '%s\n' "${green}OK${n_c}" > "${MSGS_DEST}"
	:
}

### dnsmasq support implementation

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
		stop -noexit
		get_dnsmasq_instances && is_uint "${DNSMASQ_INSTANCES_CNT}" && [ "${DNSMASQ_INSTANCES_CNT}" -gt 0 ] || return 1
	}

	local conf_dirs='' conf_dirs_instance index indexes='' ifaces='' REPLY first diff conf_dirs_cnt conf_dirs_print='' add_dir

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
					eval "instance=\"\${INST_NAME_${index}}\"" \
						"ifaces=\"\${IFACES_${index}}\""
					ifaces="${ifaces// /, }"
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
		add2list select_ifaces "${ifaces}" " "
	done

	log_msg "Selected dnsmasq indexes: '${DNSMASQ_INDEXES}' (network intefaces: ${select_ifaces// /, })."

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
			if is_included "/tmp/dnsmasq.d" "${conf_dirs}"
			then
				add_dir="/tmp/dnsmasq.d"
			elif is_included "/tmp/dnsmasq.cfg01411c.d" "${conf_dirs}"
			then
				add_dir="/tmp/dnsmasq.cfg01411c.d"
			else
				# fall back to first conf-dir
				add_dir="${conf_dirs%%"${_NL_}"*}"
			fi
		fi
		[ -n "${add_dir}" ] && { add2list DNSMASQ_CONF_DIRS "${add_dir}" " "; add2list conf_dirs_print "${add_dir}" ", "; }
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

# Env vars:
#   GDI_NOFORCE: skip re-processing instances if DNSMASQ_INST_SET is non-empty
# populates global vars:
#   ALL_CONF_DIRS, DNSMASQ_RUNNING_INDEXES, DNSMASQ_INSTANCES_CNT
#   INST_NAME_${index}, IFACES_${index}, CONF_DIRS_${index}, CONF_DIRS_CNT_${index}, RUNNING_${index}, ADDNMOUNTS_${index}, MAC_${index}
#   BL_MAC_NEW, ADDNMOUNTS_SET, DNSMASQ_INST_SET
get_dnsmasq_instances() {
	# shellcheck disable=SC2317,SC2329
	add_conf_dir_and_addnmounts()
	{
		local confdir
		config_get confdir "${1}" confdir
		[ -n "${confdir}" ] && add2list ALL_CONF_DIRS "${confdir}"
		config_get "ADDNMOUNTS_${index}" "${1}" addnmount
		index=$((index+1))
	}

	[ -n "${GDI_NOFORCE}" ] && [ -n "${DNSMASQ_INST_SET}" ] && [ -n "${ADDNMOUNTS_SET}" ] &&
		is_uint "${DNSMASQ_INSTANCES_CNT}" && [ "${DNSMASQ_INSTANCES_CNT}" -gt 0 ] && return 0

	local me=get_dnsmasq_instances \
		nonempty='' instance instances running_instances index l1_conf_file l1_conf_files conf_dirs i s f dir first_iface mac_addr mac_shared=''

	unset DNSMASQ_RUNNING_INDEXES ALL_CONF_DIRS ADDNMOUNTS_SET DNSMASQ_INST_SET BL_MAC_NEW
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
		add2list ALL_CONF_DIRS "${dir}"
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
		unset "INST_NAME_${index}" "RUNNING_${index}" "IFACES_${index}" "CONF_DIRS_${index}" "CONF_DIRS_CNT_${index}" "MAC_${index}"

		case "${instance}" in
			*[!a-zA-Z0-9_]*) log_msg -warn "" "Detected dnsmasq instance with invalid name '${instance}'. Ignoring."; continue
		esac
		json_is_a "${instance}" object || continue # skip if $instance is not object
		json_select "${instance}" &&
		json_get_var "RUNNING_${index}" running &&
		json_is_a command array &&
		json_select command || { reg_failure "Failed to process info for dnsmasq instance '${instance}'."; return 1; }

		add2list running_instances "${instance}" &&
		add2list DNSMASQ_RUNNING_INDEXES "${index}" " " || return 1
		l1_conf_files=

		# look for '-C' in values, get next value which is instance's conf file
		i=0
		while json_is_a $((i+1)) string
		do
			i=$((i+1))
			json_get_var s ${i}
			[ "${s}" = '-C' ] || continue
			json_get_var l1_conf_file $((i+1)) || return 1
			add2list l1_conf_files "${l1_conf_file}" || return 1
		done
		json_select ..
		json_select ..

		IFS="${_NL_}"
		set -- ${l1_conf_files}
		IFS="${DEFAULT_IFS}"

		# get ifaces for instance
		ifaces="$(${AWK_CMD} -F= '/^\s*interface=/ {if ($2 != "" && !seen[$2]++) {ifaces = ifaces $2 " "} } END {print ifaces}' "${@}")"
		[ -n "${ifaces}" ] ||
		{
			ifaces="$(fw4 zone lan)"
			ifaces="${ifaces//"${_NL_}"/ }"
		}

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
			add2list ALL_CONF_DIRS "${dir}"
		done

		# get mac address for instance
		mac_addr=
		first_iface="${ifaces%% *}"
		[ -n "${first_iface}" ] &&
		{
			read -rn17 mac_addr _ < "/sys/class/net/${first_iface}/address"
			mac_addr="${mac_addr//:/}" &&
			case "${mac_addr}" in
				''|*[!0-9a-fA-F]*) mac_addr='' ;;
				*) add2list mac_shared "${mac_addr}" " "
			esac
		}

		eval "INST_NAME_${index}=\"${instance}\"
			CONF_DIRS_${index}=\"${conf_dirs}\"
			IFACES_${index}=\"${ifaces% }\"
			MAC_${index}=\"${mac_addr}\""
		cnt_lines "CONF_DIRS_CNT_${index}" "${conf_dirs}"
		index=$((index+1))
	done
	json_cleanup
	cnt_lines DNSMASQ_INSTANCES_CNT "${running_instances}"

	mac_shared="${mac_shared// /}"
	tolower mac_shared "${mac_shared}"
	export BL_MAC_NEW="${mac_shared:0:24}" # trim to 24 chars (2 first addresses)

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
			stop -noexit
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
			is_included "${dir}" "${DNSMASQ_CONF_DIRS}" " " && conf_dir_reg=1
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

:
