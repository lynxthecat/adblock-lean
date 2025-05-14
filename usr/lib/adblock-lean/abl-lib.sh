#!/bin/sh
# shellcheck disable=SC3043,SC3003,SC3001,SC3020,SC3044,SC2016,SC3057,SC3019
# ABL_VERSION=dev

# silence shellcheck warnings
: "${blue:=}" "${purple:=}" "${green:=}" "${red:=}" "${yellow:=}" "${n_c:=}"
: "${blocklist_urls:=}" "${test_domains:=}" "${whitelist_mode:=}"
: "${luci_cron_job_creation_failed}" "${luci_pkgs_install_failed}" "${luci_tarball_url}"

### GLOBAL VARIABLES
RECOMMENDED_PKGS="gawk sed coreutils-sort"
RECOMMENDED_UTILS="awk sed sort"
ABL_CRON_SVC_PATH=/etc/init.d/cron
ALL_PRESETS="mini small medium large large_relaxed"


### UTILITY FUNCTIONS

try_mv()
{
	[ -z "${1}" ] || [ -z "${2}" ] && { reg_failure "try_mv(): bad arguments."; return 1; }
	mv -f "${1}" "${2}" || { reg_failure "Failed to move '${1}' to '${2}'."; return 1; }
	:
}

# 1 - var for output
# 2 - input lines
cnt_lines()
{
	local line cnt IFS="${_NL_}"
	for line in ${2}; do
		case "${line}" in
			'') ;;
			*) cnt=$((cnt+1))
		esac
	done
	eval "${1}=${cnt}"
}

get_file_size_human()
{
	bytes2human "$(du -b "$1" | ${AWK_CMD} '{print $1}')"
}

# converts unsigned integer to [xB|xKiB|xMiB|xGiB|xTiB]
# if result is not an integer, outputs up to 2 digits after decimal point
# 1 - int
bytes2human()
{
	local i="${1:-0}" s=0 d=0 m=1024 fp='' S=''
	case "$i" in *[!0-9]*) reg_failure "bytes2human: Invalid unsigned integer '$i'."; return 1; esac
	for S in B KiB MiB GiB TiB
	do
		[ $((i > m && s < 4)) = 0 ] && break
		d=$i i=$((i/m)) s=$((s+1))
	done
	d=$((d % m * 100 / m))
	case $d in
		0) printf "%s %s\n" "$i" "$S"; return ;;
		[1-9]) fp="02" ;;
		*0) d=${d%0}; fp="01"
	esac
	printf "%s.%${fp}d %s\n" "$i" "$d" "$S"
}

# 1 - var name for output
# 2 - uint
int2human() {
	case "${2}" in ''|*[!0-9]*)
		reg_failure "int2human: Invalid unsigned integer '${2}'."
		eval "${1}="
		return 1
	esac
	local in_num="${2#"${2%%[!0]*}"}" out_num=
	while :
	do
		case "$in_num" in 
			????*)
				out_num=",${in_num: -3}$out_num"
				in_num="${in_num%???}" ;;
			*) break
		esac
	done
	eval "${1}"='${in_num:-0}${out_num}'
}


### SETUP AND CONFIG MANAGEMENT

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
		local recomm_pkgs_regex
		recomm_pkgs_regex="$(printf %s "$RECOMMENDED_PKGS" | tr ' ' '|')"
		local pkgs2install='' missing_packages='' missing_utils='' missing_utils_print='' util \
			installed_pkgs='' util_size_B utils_size_B=0 awk_size_B sort_size_B sed_size_B \
			free_space_B='' free_space_KB mount_point

		: "${awk_size_B:=1048576}" "${sort_size_B:=122880}" "${sed_size_B:=153600}"

		installed_pkgs="$(get_installed_pkgs "${recomm_pkgs_regex}")" || return 1

		echo > "${MSGS_DEST}"
		for util in ${RECOMMENDED_UTILS}
		do
			case "${installed_pkgs}" in
				*"${util}"*) log_msg -green "GNU ${util} is already installed." ;;
				*)
					add2list missing_utils "${util}" " "
					add2list missing_utils_print "${blue}GNU ${util}${n_c}" ", "
					add2list missing_packages "${blue}$(get_pkg_name "${util}")${n_c}" ", "
			esac
		done

		# make a list of GNU utils to install
		if [ -n "${missing_utils}" ]
		then
			free_space_KB="$(df -k /usr/ | tail -n1 | $SED_CMD -E 's/^[ \t]*([^ \t]+[ \t]+){3}//;s/[ \t]+.*//')"
			mount_point="$(df -k /usr/ | tail -n1 | $SED_CMD -E 's/.*[ \t]+//')"
			case "${free_space_KB}" in
				''|*[!0-9]*) reg_failure "Failed to check available free space."; return 1 ;;
				*) free_space_B=$((free_space_KB*1024))
			esac

			if [ -n "${DO_DIALOGS}" ]
			then
				print_msg "" "For improved performance while processing the lists, it is recommended to install ${missing_utils_print}." \
					"Corresponding packages are: ${missing_packages}."
				[ -n "${free_space_B}" ] &&
					print_msg "" "Available free space at mount point '${mount_point}': ${yellow}$(bytes2human "${free_space_B}")${n_c}." ""
			fi

			for util in ${missing_utils}
			do
				REPLY=n
				if [ -n "${DO_DIALOGS}" ]
				then
					eval "util_size_B=\"\${${util}_size_B}\""
					print_msg "Would you like to install ${blue}GNU ${util}${n_c} automatically? Installed size: ${yellow}$(bytes2human "${util_size_B}")${n_c}. (y|n)"
					pick_opt "y|n" || return 1
				elif [ -n "${luci_install_packages}" ]
				then
					REPLY=y
				fi

				if [ "${REPLY}" = y ]
				then
					pkgs2install="${pkgs2install}$(get_pkg_name "${util}") "
					utils_size_B=$((utils_size_B+util_size_B))
				fi
			done
		fi

		# install GNU utils
		if [ -n "${pkgs2install}" ]
		then
			REPLY=n
			if [ -n "${DO_DIALOGS}" ]
			then
				print_msg "" "Selected packages: ${blue}${pkgs2install% }${n_c}" \
					"Total installed size: ${yellow}$(bytes2human ${utils_size_B})${n_c}." \
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

	[ -n "${ABL_SERVICE_PATH}" ] || { reg_failure "\${ABL_SERVICE_PATH} variable is unset."; return 1; }
	[ -f "${ABL_SERVICE_PATH}" ] || { reg_failure "adblock-lean service file doesn't exist at ${ABL_SERVICE_PATH}."; return 1; }

	# make the script executable
	if [ ! -x "${ABL_SERVICE_PATH}" ]
	then
		log_msg -purple "" "Making ${ABL_SERVICE_PATH} executable."
		chmod +x "${ABL_SERVICE_PATH}" || { reg_failure "Failed to make '${ABL_SERVICE_PATH}' executable."; return 1; }
	else
		log_msg -green "" "${ABL_SERVICE_PATH} is already executable."
	fi

	REPLY=n

	if [ -s "${ABL_CONFIG_FILE}" ]
	then
		if [ -n "${DO_DIALOGS}" ]
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
		load_config || return 3
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

	# make addnmount entry - enables blocklist compression to reduce RAM usage
	check_addnmount
	case ${?} in
		0) log_msg -green "" "Found existing dnsmasq addnmount UCI entry." ;;
		2) return 5 ;;
		1)
			log_msg -purple "" "Creating dnsmasq addnmount UCI entry."
			uci add_list dhcp.@dnsmasq["${DNSMASQ_INDEX}"].addnmount='/bin/busybox' && uci commit ||
			{
				reg_failure "Failed to create addnmount entry."
				return 5
			}
	esac

	detect_pkg_manager
	case "${PKG_MANAGER}" in
		apk|opkg)
			install_packages && luci_pkgs_install_failed=
			detect_utils ;;
		*)
			log_msg -yellow "" "Can not automatically check and install recommended packages (${RECOMMENDED_PKGS})." \
				"Consider to check for their presence and install if needed."
	esac

	if [ -n "${DO_DIALOGS}" ]
	then
		print_msg "" "${purple}Setup is complete.${n_c}" "" "Start adblock-lean now? (y|n)"
		pick_opt "y|n" || return 1
		[ "${REPLY}" != y ] && return 0
		echo > "${MSGS_DEST}"
		start
	fi
	:
}

# shellcheck disable=2034
mk_preset_arrays()
{
	local hagezi_dl_url="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard"

	# quasi-arrays for presets
	# cnt - target elements count/1000, mem - memory in MB
	mini_urls="${hagezi_dl_url}/pro.mini-onlydomains.txt" \
		mini_cnt=85 mini_mem=64
	small_urls="${hagezi_dl_url}/pro-onlydomains.txt ${hagezi_dl_url}/tif.mini-onlydomains.txt" \
		small_cnt=250 small_mem=128
	medium_urls="${hagezi_dl_url}/pro-onlydomains.txt ${hagezi_dl_url}/tif.medium-onlydomains.txt" \
		medium_cnt=450 medium_mem=256
	large_urls="${hagezi_dl_url}/pro-onlydomains.txt ${hagezi_dl_url}/tif-onlydomains.txt" \
		large_cnt=1200 large_mem=512
	large_relaxed_urls="${hagezi_dl_url}/pro-onlydomains.txt ${hagezi_dl_url}/tif-onlydomains.txt" \
		large_relaxed_cnt=1200 large_relaxed_mem=1024 large_relaxed_coeff=2
}

# 1 - mini|small|medium|large|large_relaxed
# 2 - (optional) '-d' to print the description
# 2 - (optional) '-n' to print nothing (only assign values to vars)
gen_preset()
{
	# rounds down to reasonable number of digits, based on the input number of digits
	# 1 - var for I/O
	reasonable_round()
	{
		local input res shift_digits
		eval "input=\"\${${1}}\""
		shift_digits=$(( ${#input}-2 ))
		case "${shift_digits}" in
			-*|'')
				shift_digits=0
				shifted="${input}" ;; # shell doesn't handle ${var:0:-0} correctly
			*)	shifted=${input:0:-${shift_digits}}
		esac
		res="$(( shifted * 10**shift_digits ))"
		eval "${1}"='${res}'
		: "${res}"
	}

	local val field mem tgt_lines_cnt_k lim_coeff final_entry_size_B source_entry_size_B

	eval "mem=\"\${${1}_mem}\" tgt_lines_cnt_k=\"\${${1}_cnt}\" lim_coeff=\"\${${1}_coeff:-1}\" blocklist_urls=\"\${${1}_urls}\""

	# Default values calculation:
	# Values are rounded down to reasonable degree

	final_entry_size_B=20 # assumption
	source_entry_size_B=20 # assumption for raw domains format. dnsmasq source format not used by default

	# target_lines_cnt / 3.5
	min_good_line_count=$((tgt_lines_cnt_k*10000/35))
	reasonable_round min_good_line_count

	# target_lines_cnt * final_entry_size_B * lim_coeff * 1.25
	max_blocklist_file_size_KB=$(( (tgt_lines_cnt_k*1250*final_entry_size_B*lim_coeff)/1024 ))
	reasonable_round max_blocklist_file_size_KB

	case "${1}" in
		mini) max_file_part_size_KB=${max_blocklist_file_size_KB} ;;
		*)
			# target_lines_cnt * source_entry_size_B * lim_coeff * 1.03
			max_file_part_size_KB=$(( (tgt_lines_cnt_k*1030*source_entry_size_B*lim_coeff)/1024 ))
			reasonable_round max_file_part_size_KB
	esac

	[ "${2}" = '-d' ] && print_msg "" "${purple}${1}${n_c}: recommended for devices with ${mem} MB of memory."

	if [ "${2}" != '-n' ]
	then
		print_msg "${blue}Elements count:${n_c} ~${tgt_lines_cnt_k}k"
		for field in blocklist_urls max_file_part_size_KB max_blocklist_file_size_KB min_good_line_count
		do
			eval "val=\"\${${field}}\""
			print_msg "${blue}${field}${n_c}=\"${val}\""
		done
	fi
}

# (optional) -d to print with allowed value types (otherwise print without)
# (optional) -p to print with values from preset
# (optional) -i to print with DNSMASQ_INSTANCE
# (optional) -n to print with DNSMASQ_INDEX
# (optional) -c to print with DNSMASQ_CONF_D
print_def_config()
{
	# follow each default option with '@' and a pre-defined type: string, integer (implies unsigned integer)
	# or custom optional values, examples: opt1, opt1|opt2, ''|opt1|opt2

	# process args
	local preset='' print_types='' dnsmasq_instance='' dnsmasq_index='' dnsmasq_conf_d=''
	while getopts ":i:n:c:p:d" opt; do
		case $opt in
			i) dnsmasq_instance=$OPTARG ;;
			n) dnsmasq_index=$OPTARG ;;
			c) dnsmasq_conf_d=$OPTARG ;;
			p) preset=$OPTARG ;;
			d) print_types=1 ;;
			*) ;;
		esac
	done

	# @temp_workaround for updating: exploiting the fact that print_def_config()
	# is called from updated script - remove a few months from now
	# removes files with old filenames from dnsmasq dir
	if [ "${ABL_CMD}" = update ] && [ -z "${dnsmasq_instance}" ] &&
		[ -z "${dnsmasq_index}" ] && [ -z "${dnsmasq_conf_d}" ] && [ -z "${preset}" ] && [ -z "${print_types}" ]
	then
		local dnsmasq_tmp_d file dnsmasq_restart_req
		for dnsmasq_tmp_d in "/tmp/dnsmasq.d" "$(uci get dhcp.@dnsmasq[0].confdir 2>/dev/null)"
		do
			for file in "${dnsmasq_tmp_d}"/.blocklist.gz "${dnsmasq_tmp_d}"/blocklist \
				"${dnsmasq_tmp_d}"/conf-script "${dnsmasq_tmp_d}"/.extract_blocklist
			do
				[ -f "${file}" ] && { rm -f "${file}"; dnsmasq_restart_req=1; }
			done
		done
		[ -n "${dnsmasq_restart_req}" ] && restart_dnsmasq -nostop
	fi

	mk_preset_arrays
	: "${preset:=small}"
	is_included "${preset}" "${ALL_PRESETS}" " " || { reg_failure "print_def_config: \$preset var has invalid value."; exit 1; }
	gen_preset "${preset}" -n

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

	# One or more *raw domain* format blocklist/ipv4 blocklist/allowlist urls separated by spaces
	blocklist_urls="${blocklist_urls}" @ string
	blocklist_ipv4_urls="" @ string
	allowlist_urls="" @ string

	# One or more *dnsmasq format* domain blocklist/ipv4 blocklist/allowlist urls separated by spaces
	dnsmasq_blocklist_urls="" @ string
	dnsmasq_blocklist_ipv4_urls="" @ string
	dnsmasq_allowlist_urls="" @ string

	# Path to optional local *raw domain* allowlist/blocklist files in the form:
	# site1.com
	# site2.com
	local_allowlist_path="${ABL_CONFIG_DIR}/allowlist" @ string
	local_blocklist_path="${ABL_CONFIG_DIR}/blocklist" @ string

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

	# Minimum number of good lines in final postprocessed blocklist
	min_good_line_count="${min_good_line_count}" @ integer

	# Mininum number of lines of any individual downloaded part
	min_blocklist_part_line_count="1" @ integer
	min_blocklist_ipv4_part_line_count="1" @ integer
	min_allowlist_part_line_count="1" @ integer

	# Maximum size of any individual downloaded blocklist part
	max_file_part_size_KB="${max_file_part_size_KB}" @ integer

	# Maximum total size of combined, processed blocklist
	max_blocklist_file_size_KB="${max_blocklist_file_size_KB}" @ integer

	# Whether to perform sorting and deduplication of entries (usually doesn't cause much slowdown, uses a bit more memory) - enable (1) or disable (0)
	deduplication="1" @ 0|1

	# compress final blocklist, intermediate blocklist parts and the backup blocklist to save memory - enable (1) or disable (0)
	use_compression="1" @ 0|1

	# unload previous blocklist form memory and restart dnsmasq before generation of
	# new blocklist in order to free up memory during generation of new blocklist - 'auto' or enable (1) or disable (0)
	unload_blocklist_before_update="auto" @ auto|0|1

	# Start delay in seconds when service is started from system boot
	boot_start_delay_s="120" @ integer

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

	# dnsmasq instance and config directory
	# normally this should be set automatically by the 'setup' command
	DNSMASQ_INSTANCE="${dnsmasq_instance}" @ string
	DNSMASQ_INDEX="${dnsmasq_index}" @ integer
	DNSMASQ_CONF_D="${dnsmasq_conf_d}" @ string

	EOT
}

# generates config
do_gen_config()
{
	local cnt

	if [ -n "${DO_DIALOGS}" ] && [ -z "${luci_preset}" ]
	then
		mk_preset_arrays
		mk_def_preset || print_msg "Skipping automatic preset recommendation."
		if [ -n "${preset}" ]
		then
			print_msg "" "Based on the total usable memory of this device ($(bytes2human $((totalmem*1024)) )), the recommended preset is '${purple}${preset}${n_c}':"
			gen_preset "${preset}"
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
				gen_preset "${preset}" -d
			done
			print_msg "" "Pick preset:"
			pick_opt "${presets_case_opts}"
			preset="${REPLY}"
		fi
	else
		# determine preset for luci
		case "${luci_preset}" in
			''|auto) mk_def_preset || { log_msg "Falling back to preset 'small'."; preset=small; } ;;
			*) preset="${luci_preset}"
		esac
	fi

	is_included "${preset}" "${ALL_PRESETS}" " " || { reg_failure "Invalid preset '${preset}'."; return 1; }
	log_msg -blue "Selected preset '${preset}'."

	select_dnsmasq_instance -n || { reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."; return 1; }

	# create cron job
	cron_schedule=
	local def_schedule="0 5 * * *" def_schedule_desc="daily at 5am (5 o'clock at night)"

	REPLY=n
	if [ -n "${DO_DIALOGS}" ]
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

	reg_action -purple "Generating new default config for adblock-lean from preset '${preset}'." || return 1
	write_config "$(print_def_config -p "${preset}" -c "${DNSMASQ_CONF_D}" -i "${DNSMASQ_INSTANCE}" -n "${DNSMASQ_INDEX}")" || return 1

	[ "${ABL_CMD}" = gen_config ] && check_blocklist_compression_support
	:
}

# sets ${preset} to recommended preset, depending on system memory capacity
mk_def_preset()
{
	unset preset totalmem
	local mem cnt
	local IFS="${DEFAULT_IFS}"
	read -r _ totalmem _ < /proc/meminfo
	case "${totalmem}" in
		''|*[!0-9]*) reg_failure "\$totalmem has invalid value '${totalmem}'. Failed to determine system memory capacity."; return 1 ;;
		*)
			for preset in $(printf %s "${ALL_PRESETS}" | tr ' ' '\n' | ${SED_CMD} 'x;1!H;$!d;x') # loop over presets in reverse order
			do
				eval "mem=\"\${${preset}_mem}\""
				# multiplying by 800 rather than 1024 to account for some memory not available to the kernel
				[ "${totalmem}" -ge $((mem * 800)) ] && break
			done
	esac
	:
}

# validate config and assign to variables
#
# 1 - path to file
#
# return codes:
# 0 - Success
# 1 - Config error with no automatic fix
# 2 - Unexpected, missing or legacy-formatted (no double quotes) entries found
# 3 - Internal parser error
#
# sets ${missing_keys}, ${conf_fixes}, ${bad_value_keys}
# and variables for luci:
# *_curr_config_format *_def_config_format *_unexp_keys *_unexp_entries *_missing_keys *_missing_entries
# *_bad_conf_format *_conf_fixes *_bad_value_keys
# shellcheck disable=SC2317,SC2034
parse_config()
{
	add_conf_fix() { conf_fixes="${conf_fixes}${1}"$'\n'; }

	local def_config='' curr_config='' missing_entries='' unexp_keys='' unexp_entries='' \
		entry key val bad_val_entries='' corrected_entries='' valid_values all_valid_values \
		sed_conf_san_exp='/^\s*#.*$/d; s/^\s+//; s/\s+=/=/; s/=\s+/=/; s/\s+$//; /^$/d'

	unset curr_config_format def_config_format bad_value_keys \
		luci_curr_config_format luci_def_config_format luci_unexp_keys luci_unexp_entries luci_missing_keys luci_missing_entries \
		luci_bad_conf_format luci_conf_fixes preset

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
	luci_curr_config_format=${curr_config_format}
	def_config_format="$(printf %s "${def_config}" | get_config_format)"
	luci_def_config_format=${def_config_format}

	local parse_vars valid_lines def_lines_arr
	# extract valid values from default config
	valid_lines="$(print_def_config -d | ${SED_CMD} "${sed_conf_san_exp}")"
	# parse config
	local parser_error_file="${ABL_CONF_STAGING_DIR}/parser_error"
	rm -f "${parser_error_file}" "${ABL_CONF_STAGING_DIR}/unexp_entries" \
		"${ABL_CONF_STAGING_DIR}/bad_val_entries" "${ABL_CONF_STAGING_DIR}/missing_entries"
	parse_vars="$(
		printf '%s\n' "${curr_config}" |
		${AWK_CMD} -F"=" -v q="'" -v V="${valid_lines}" -v A="${ABL_CONF_STAGING_DIR}" '
		# return codes: 0=OK, 1=awk or default config error, 253=check double-quotes, 254=Invalid entry detected

		# make default config arrays: def_arr, valid_values_regex_arr, valid_values_print_arr
		BEGIN{
			rv=0
			missing[1]="key"
			missing[2]="value"
			missing[3]="allowed values"

			# create def_lines_arr
			split(V,def_lines_arr,"\n")
			for (ind in def_lines_arr) {
				# validate default config line
				sub(/[ \t]+@/,"@",def_lines_arr[ind])
				sub(/@[ \t]+/,"@",def_lines_arr[ind])
				n=split(def_lines_arr[ind],def_line_parts,"[=@]")
				if (n!=3) {print "Internal error in default config: invalid line " q def_lines_arr[ind] q "." > "/dev/stderr"; rv=1; exit}
				for (i in def_line_parts) {
					if (! def_line_parts[i]) {
						print "Internal error in default config: line " q def_lines_arr[ind] q " is missing the " missing[i] "." > "/dev/stderr"
						rv=1
						exit
					}
				}

				key=def_line_parts[1]
				def_val=def_line_parts[2]
				valid_values=def_line_parts[3]

				# create cleaned up def_arr
				def_arr[key]=def_val

				# make entry-specific validation regex array
				val_regex=valid_values
				sub(/integer/,"[0-9]+",val_regex)
				sub(/string/,".*",val_regex)
				valid_values_regex_arr[key]=val_regex

				# make printable entry-specific valid values array
				val_print=valid_values
				sub(/integer/,"non-negative integer",val_print)
				gsub(/\|/," or ", val_print)
				valid_values_print_arr[key]=val_print
			}
		}

		# process user config
		{
			# handle double or missing =
			if ( $0 !~ /^[^=]+=[^=]+([ \t]+(#.*){0,1})*$/ ) {
				print $0 > "/dev/stderr"
				rv=254
				exit
			}

			# key must be non-empty and alphanumeric
			if ( $1 !~ /^[a-zA-Z0-9_]+$/ ) {
				print $0 > "/dev/stderr"
				rv=254
				exit
			}

			# line must have exactly 2 double-quotes after = and no characters before #
			if ( $0 !~ /^[^"]+="[^"]*"([ \t]+(#[^"]*){0,1}){0,1}$/ ) {
				print $0 > "/dev/stderr"
				rv=253
				exit
			}

			# handle unexpected keys
			if ($1 in def_arr) {} else {
				unexp_keys=unexp_keys $1 " "
				print $0 >> A"/unexp_entries"
				next
			}

			# register key
			config_keys[$1]

			# remove in-line comments and preceding spaces
			sub(/[ \t]*#.*/,"",$2)

			# handle unexpected values
			val=$2
			gsub(/"/,"",val)
			regex="^(" valid_values_regex_arr[$1] ")$"
			if (val !~ regex) {
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
				if (key in config_keys) {} else {
					print key "=" def_arr[key] >> A"/missing_entries"
					missing_keys=missing_keys key " "
				}
			}
			print "missing_keys=\"" missing_keys "\" " \
				"unexp_keys=\"" unexp_keys "\" " \
				"bad_value_keys=\"" bad_val_keys "\" "
			exit rv
		}'
	)" 2> "${parser_error_file}" ||
	{
		local awk_rv=${?} err_print=''
		[ -s "${parser_error_file}" ] && err_print="$(cat "${parser_error_file}")"

		[ -n "${err_print}" ] &&
			case "${awk_rv}" in
				253|254) err_print=": '${err_print}'" ;;
				*) err_print=" ${err_print}"
			esac

		case "${awk_rv}" in
			253) reg_failure "Invalid entry in config (check double-quotes)${err_print}." ;;
			254) reg_failure "Invalid entry in config${err_print}." ;;
			*) reg_failure "Failed to parse config.${err_print}"; return 3
		esac

		return 1
	}

	rm -f "${parser_error_file}"
	eval "${parse_vars}" 2> "${parser_error_file}" && [ ! -s "${parser_error_file}" ] ||
	{
		[ -s "${parser_error_file}" ] && err_print=" Errors: $(cat "${parser_error_file}")"
		reg_failure "Failed to parse config.${err_print}"
		return 3
	}

	if [ -n "${unexp_keys}" ]
	then
		reg_failure "Unexpected keys in config: '${unexp_keys% }'."
		unexp_entries="$(cat "${ABL_CONF_STAGING_DIR}/unexp_entries")"
		print_msg "Corresponding config entries:" "${unexp_entries%$'\n'}"
		add_conf_fix "Remove unexpected entries from the config"
		luci_unexp_keys=${unexp_keys% }
		luci_unexp_entries=${unexp_entries%$'\n'}
	fi

	if [ -n "${missing_keys}" ]
	then
		reg_failure "Missing keys in config: '${missing_keys% }'."
		missing_entries="$(cat "${ABL_CONF_STAGING_DIR}/missing_entries")"
		print_msg "Corresponding default config entries:" "${missing_entries%$'\n'}"
		add_conf_fix "Re-add missing config entries with default values"
		luci_missing_keys=${missing_keys% }
		luci_missing_entries=${missing_entries%$'\n'}
	fi

	if [ -n "${bad_value_keys}" ]
	then
		reg_failure "Detected config entries with unexpected values."
		bad_val_entries="$(cat "${ABL_CONF_STAGING_DIR}/bad_val_entries")"
		corrected_entries="$(cat "${ABL_CONF_STAGING_DIR}/corrected_entries")"
		print_msg "The following config entries have unexpected values:" "${bad_val_entries%$'\n'}" "" \
			"Corresponding default config entries:" "${corrected_entries%$'\n'}"
		add_conf_fix "Replace unexpected values with defaults"
		luci_bad_val_entries=${bad_val_entries%$'\n'}
		luci_corrected_entries=${corrected_entries%$'\n'}
	fi

	if [ -z "${conf_fixes}" ]
	then
		case "${curr_config_format}" in
			*[!0-9]*|'')
				log_msg -warn "" "Config format version is unknown or invalid."
				add_conf_fix "Update config format version" ;;
			*)
				if [ "${curr_config_format}" != "${def_config_format}" ]
				then
					log_msg -yellow "" "Current config format version '${curr_config_format}' differs from default config version '${def_config_format}'."
					add_conf_fix "Update config format version"
				fi
		esac
	fi

	conf_fixes="${conf_fixes%$'\n'}"
	luci_conf_fixes="${conf_fixes}"

	[ -n "${conf_fixes}" ] && return 2
	:
}

# shellcheck disable=SC2120
# 1 - (optional) '-f' to force fixing the config if it has issues
load_config()
{
	local conf_fixes='' fixed_config='' missing_keys='' bad_value_keys='' key val line fix cnt

	# Need to set DO_DIALOGS here for compatibility when updating from earlier versions
	local DO_DIALOGS=
	[ -z "${ABL_LUCI_SOURCED}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] && DO_DIALOGS=1

	if [ ! -f "${ABL_CONFIG_FILE}" ]
	then
		reg_failure "Config file is missing."
		log_msg "Generate default config using 'service adblock-lean gen_config'."
		return 1
	fi

	local tip_msg="Fix your config file '${ABL_CONFIG_FILE}' or generate default config using 'service adblock-lean gen_config'."

	# validate config and assign to variables
	parse_config "${ABL_CONFIG_FILE}"
	case ${?} in
		0) return 0 ;;
		1) log_msg "${tip_msg}"; return 1 ;; # config error with no automatic fix
		2) ;; # config error(s) with automatic fix
		3) return 1 # internal parser error
	esac

	# if not in interactive console and force-fix not set, return error
	[ -z "${DO_DIALOGS}" ] && [ "${1}" != '-f' ] && { log_msg "${tip_msg}"; return 1; }

	# sanity check
	[ -z "${conf_fixes}" ] && { reg_failure "Failed to parse config."; return 1; }

	if [ -n "${DO_DIALOGS}" ] && [ "${1}" != '-f' ]
	then
		if [ -n "${conf_fixes}" ]
		then
			print_msg -blue "" "Perform following automatic changes? (y|n)"
			cnt=0
			local IFS="${_NL_}"
			for fix in ${conf_fixes}
			do
				IFS="${DEFAULT_IFS}"
				[ -z "${fix}" ] && continue
				cnt=$((cnt+1))
				print_msg "${cnt}. ${fix}"
			done
			IFS="${DEFAULT_IFS}"
			pick_opt "y|n" || return 1
		fi
	else
		REPLY=y
	fi

	[ "${REPLY}" = n ] && { log_msg "${tip_msg}"; return 1; }

	fix_config "${missing_keys} ${bad_value_keys}" || { reg_failure "Failed to fix the config."; log_msg "${tip_msg}"; return 1; }
	:
}

# 1 - missing keys (whitespace-separated)
fix_config()
{
	local missing_keys="${1}"

	case "${missing_keys}" in
		*DNSMASQ_CONF_D*|*DNSMASQ_INSTANCE*|*DNSMASQ_INDEX*)
			select_dnsmasq_instance -n || return 1 ;;
	esac

	# recreate config from default while replacing values with values from the existing config
	fixed_config="$(
		print_def_config -c "${DNSMASQ_CONF_D}" -i "${DNSMASQ_INSTANCE}" -n "${DNSMASQ_INDEX}" | while IFS="${_NL_}" read -r line
		do
			case ${line} in
				\#*|'') printf '%s\n' "${line}"; continue ;;
				*=*)
					key=${line%%=*}
					case " ${missing_keys} " in
						*" ${key} "*) printf '%s\n' "${line}"; continue ;;
						*)
							eval "val=\"\${${key}}\""
							printf '%s\n' "${key}=\"${val}\""
							continue
					esac
			esac
		done
	)"

	local old_config_f="/tmp/adblock-lean_config.old"
	if ! cp "${ABL_CONFIG_FILE}" "${old_config_f}"
	then
		reg_failure "Failed to save old config file as ${old_config_f}."
		[ -z "${DO_DIALOGS}" ] && return 1
		log_msg "Proceed with suggested config changes? (y|n)"
		pick_opt "y|n" || return 1
		[ "${REPLY}" = n ] && return 1
	else
		log_msg "" "Old config file was saved as ${old_config_f}."
	fi

	write_config "${fixed_config}" || return 1

	:
}

# Writes config to temp file, validates it, moves it to permanent storage
# 1 - new config file contents
write_config()
{
	local tmp_config="${ABL_CONF_STAGING_DIR}/write-config.tmp" missing_keys conf_fixes

	[ -z "${1}" ] && { reg_failure "write_config(): no config passed."; return 1; }

	if [ -n "${DO_DIALOGS}" ] && [ -f "${ABL_CONFIG_FILE}" ]
	then
		print_msg "This will overwrite existing config. Proceed? (y|n)"
		pick_opt "y|n" && [ "${REPLY}" != n ] || return 1
	fi

	try_mkdir -p "${ABL_CONF_STAGING_DIR}" || return 1
	printf '%s\n' "${1}" > "${tmp_config}" || { reg_failure "Failed to write to file '${tmp_config}'."; return 1; }
	parse_config "${tmp_config}" ||
		{ rm -f "${tmp_config}"; reg_failure "Failed to validate the new config."; return 1; }

	log_msg "" "Saving new config file to '${ABL_CONFIG_FILE}'."
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

get_pkg_name()
{
	case "${1}" in
		awk) printf gawk ;;
		sed) printf sed ;;
		sort) printf coreutils-sort
	esac
}

report_utils()
{
	local util awk_inst_tip='' sed_inst_tip='' sort_inst_tip=''

	printf '\n' > "${MSGS_DEST}"

	for util in ${RECOMMENDED_UTILS}
	do
		case "${PKG_MANAGER}" in
			opkg|apk)
				eval "${util}_inst_tip=\" (${PKG_INSTALL_CMD} $(get_pkg_name "${util}"))\"" ;;
			*)
				unset "${util}_inst_tip" ;;
		esac
	done

	case "${AWK_CMD}" in
		*gawk*) log_msg -green "gawk detected so using gawk for fast (sub)domain match removal and entries packing." ;;
		*)
			log_msg -yellow "gawk not detected so allowlist (sub)domains removal from blocklist will be slow and list processing will not be as efficient."
			log_msg "Consider installing the gawk package${awk_inst_tip} for faster processing and (sub)domain match removal."
	esac

	case "${SED_CMD}" in
		*gnu*) log_msg -green "GNU sed detected so list processing will be fast." ;;
		*)
			log_msg -yellow "GNU sed not detected so list processing will be a little slower."
			log_msg "Consider installing the GNU sed package${sed_inst_tip} for faster processing." ;;
	esac

	case "${SORT_CMD}" in
		*coreutils*) log_msg -green "coreutils-sort detected so sort will be fast." ;;
		*)
			log_msg -yellow "coreutils-sort not detected so sort will be a little slower."
			log_msg "Consider installing the coreutils-sort package${sort_inst_tip} for faster sort." ;;
	esac
}

# return codes:
# 0 - addnmount entry exists
# 1 - addnmount entry doesn't exist
# 2 - error
check_addnmount()
{
	hash uci 1>/dev/null || { reg_failure "uci command was not found."; return 2; }
	case "${DNSMASQ_INDEX}" in
		''|*[!0-9]*)
			reg_failure "Invalid index '${DNSMASQ_INDEX}' registered for dnsmasq instance '${DNSMASQ_INSTANCE}'."
			return 2
	esac

	uci -q get dhcp.@dnsmasq["${DNSMASQ_INDEX}"].addnmount | grep -qE "('|^|[ \t])/bin(/\*|/busybox)*([ \t]|'|$)" && return 0
	return 1
}

# return codes:
# 0 - addnmount entry exists
# 1 - addnmount entry doesn't exist
# 2 - error
check_blocklist_compression_support()
{
	if ! dnsmasq --help | grep -qe "--conf-script"
	then
		log_msg "" "Note: The version of dnsmasq installed on this system does not support blocklist compression." \
			"Blocklist compression support in dnsmasq can be verified by checking the output of: dnsmasq --help | grep -e \"--conf-script\"" \
			"To use dnsmasq compression (which saves memory), upgrade OpenWrt and/or dnsmasq to a newer version that supports blocklist compression."
		return 1
	fi

	check_addnmount && return 0
	[ ${?} = 2 ] && { reg_failure "Failed to check addnmount entry for dnsmasq instance '${DNSMASQ_INSTANCE}'"; return 2; }
	log_msg -warn "" "No appropriate 'addnmount' entry in /etc/config/dhcp was identified." \
		"Final blocklist compression will be disabled."
	log_msg "addnmount entry is required to give dnsmasq access to busybox gunzip in order to extract compressed blocklist." \
		"Run 'service adblock-lean setup' to have the entry created automatically, or follow the steps in the README." \
		"Alternatively, change the 'use_compression' option in adblock-lean config to '0'."
	return 1
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
		release|latest|snapshot) ;;
		tag|commit) no_upd="was installed from a specific Git ${upd_channel}" ;;
		'') no_upd="update channel is unknown" ;;
		*) no_upd="update channel is '${upd_channel}'" ;;
	esac
	[ -n "${no_upd}" ] && { log_msg "" "adblock-lean ${no_upd}. Automatic updates check is disabled."; return 3; }
	reg_action -blue "Checking for adblock-lean updates."
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
		log_msg "The locally installed adblock-lean is the latest version."
		return 0
	else
		local upd_details="(update channel: ${upd_channel}, installed: '${curr_ver}', latest: '${upd_ver}'.)"
		UPD_DIRECTIONS="Consider running: 'service adblock-lean update' to update it to the latest version."
		UPD_AVAIL_MSG="adblock-lean update is available ${upd_details}"
		: "${UPD_AVAIL_MSG}" # silence shellcheck warning
		log_msg -yellow "The locally installed adblock-lean seems to be outdated ${upd_details}."
		log_msg "${UPD_DIRECTIONS}"
		return 1
	fi
}

# returns 0 if crontab is readable and the crond process is running, 1 otherwise
check_cron_service()
{
	# check if service is enabled
	${ABL_CRON_SVC_PATH} enabled || return 1
	# check reading crontab
	crontab -u root -l &>/dev/null || return 1
	# check for crond in running processes
	pidof crond 1>/dev/null || return 1
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

	check_cron_service || { printf '%s\n' "${red}Failed.${n_c}"; reg_failure "${enable_failed}."; return 1; }
	printf '%s\n' "${green}OK${n_c}" > "${MSGS_DEST}"
	:
}

### dnsmasq support implementation

# analyze dnsmasq instances and set $DNSMASQ_CONF_D
# 1 - (optional) '-n' to only set vars (no config write)
do_select_dnsmasq_instance() {
	get_dnsmasq_instances && [ "${DNSMASQ_INSTANCES_CNT}" != 0 ] ||
	{
		reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."
		stop -noexit
		get_dnsmasq_instances && [ "${DNSMASQ_INSTANCES_CNT}" != 0 ] || return 1
	}

	if [ "${DNSMASQ_INSTANCES_CNT}" = 1 ]
	then
		DNSMASQ_INSTANCE="${DNSMASQ_INSTANCES}"
		log_msg -blue "Detected only 1 dnsmasq instance - skipping manual instance selection."
	else
		# check if all instances share same conf-dirs
		local instance conf_dirs conf_dirs_instance index indexes ifaces REPLY='' first=1 diff=
		for instance in ${DNSMASQ_INSTANCES}
		do
			eval "conf_dirs_instance=\"\${${instance}_CONF_DIRS}\""
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
			DNSMASQ_INSTANCE="${DNSMASQ_INSTANCES%%"${_NL_}"*}"
			log_msg -blue "Detected multiple dnsmasq instances which are using the same conf-dir. Skipping manual instance selection."
		else
			# if conf-dirs are not shared, ask the user
			log_msg -blue "Multiple dnsmasq instances detected."
			REPLY=a
			if [ -n "${DO_DIALOGS}" ]
			then
				log_msg "" "Existing dnsmasq instances and assigned network interfaces:"
				for instance in ${DNSMASQ_INSTANCES}
				do
					eval "index=\"\${${instance}_INDEX}\""
					eval "ifaces=\"\${${instance}_IFACES}\""
					log_msg "${index}. Instance '${instance}': interfaces '${ifaces}'"
					eval "local instance_${index}=\"${instance}\""
					indexes="${indexes}${index}|"
				done
				print_msg "" "Please select which dnsmasq instance should have active adblocking, or 'a' to abort:"
				pick_opt "${indexes}a" || exit 1
			elif [ -n "${LUCI_DNSMASQ_INSTANCE_INDEX}" ]
			then
				REPLY="${LUCI_DNSMASQ_INSTANCE_INDEX}"
				is_included "${REPLY}" "${indexes}" "|" ||
					{ reg_failure "dnsmasq instance with index '${REPLY}' does not exist."; return 1; }
			else
				return 1
			fi

			[ "${REPLY}" = a ] && { log_msg "Aborted config generation."; exit 0; }
			eval "DNSMASQ_INSTANCE=\"\${instance_${REPLY}}\""
		fi
	fi
	eval "DNSMASQ_INDEX=\"\${${DNSMASQ_INSTANCE}_INDEX}\""
	log_msg "Selected dnsmasq instance ${DNSMASQ_INDEX}: '${DNSMASQ_INSTANCE}'."

	local conf_dirs conf_dirs_cnt
	eval "conf_dirs=\"\${${DNSMASQ_INSTANCE}_CONF_DIRS}\""
	eval "conf_dirs_cnt=\"\${${DNSMASQ_INSTANCE}_CONF_DIRS_CNT}\""

	if [ "${conf_dirs_cnt}" = 1 ]
	then
		DNSMASQ_CONF_D="${conf_dirs}"
	else
		if is_included "/tmp/dnsmasq.d" "${conf_dirs}"
		then
			DNSMASQ_CONF_D=/tmp/dnsmasq.d
		elif is_included "/tmp/dnsmasq.cfg01411c.d" "${conf_dirs}"
		then
			DNSMASQ_CONF_D=/tmp/dnsmasq.cfg01411c.d
		else
			# fall back to first conf-dir
			DNSMASQ_CONF_D="${conf_dirs%%"${_NL_}"*}"
		fi
	fi
	log_msg "Selected dnsmasq conf-dir '${DNSMASQ_CONF_D}'."
	if [ "${1}" != '-n' ]
	then
		write_config "$(
			$SED_CMD -E '/^\s*(DNSMASQ_CONF_D|DNSMASQ_INSTANCE|DNSMASQ_INDEX)=/d' "${ABL_CONFIG_FILE}"
			printf '%s\n%s\n%s\n' \
				"DNSMASQ_INSTANCE=\"${DNSMASQ_INSTANCE}\"" \
				"DNSMASQ_CONF_D=\"${DNSMASQ_CONF_D}\"" \
				"DNSMASQ_INDEX=\"${DNSMASQ_INDEX}\""
		)" || return 1
	fi
	:
}

clean_dnsmasq_dir()
{
	# shellcheck disable=SC2317
	add_conf_dir()
	{
		local confdir
		config_get confdir "${1}" confdir
		add2list ALL_CONF_DIRS "${confdir}"
	}

	# gather conf dirs of running instances
	get_dnsmasq_instances
	# gather conf dirs of configured instances

	# this is needed when running via 'sh /etc/init.d/adblock-lean'
	if [ -z "${ABL_LIB_FUNCTIONS_SOURCED}" ]
	then
		# shellcheck source=/dev/null
		check_func config_load 1>/dev/null || . /lib/functions.sh || { reg_failure "Failed to source /lib/functions.sh"; exit 1; }
		ABL_LIB_FUNCTIONS_SOURCED=1
	fi

	config_load dhcp
	config_foreach add_conf_dir dnsmasq
	# gather conf dirs from /tmp/
	local dir tmp_conf_dirs IFS="${_NL_}"
	tmp_conf_dirs="$(find /tmp/ -type d \( -name "dnsmasq.cfg*" -o -name dnsmasq.d \))"
	for dir in ${tmp_conf_dirs}
	do
		add2list ALL_CONF_DIRS "${dir}"
	done

	for dir in ${ALL_CONF_DIRS}
	do
		IFS="${DEFAULT_IFS}"
		rm -f "${dir}"/.abl-blocklist.gz "${dir}"/abl-blocklist \
			"${dir}"/abl-conf-script "${dir}"/.abl-extract_blocklist
	done
	:
}

# Get nameservers for dnsmasq instance
# Output via global vars: ${instance}_NS_4, ${instance}_NS_6
# 1 - instance id
get_dnsmasq_instance_ns()
{
	local family ip_regex ip_regex_4 ip_regex_6 iface line instance_ns instance_ifaces ip ip_tmp
	local instance="${1}"
	ip_regex_4='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])'
	ip_regex_6='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}'
	: "${ip_regex_4}" "${ip_regex_6}"

	for family in 4 6
	do
		eval "ip_regex=\"\${ip_regex_${family}}\""
		eval "instance_ifaces=\"\${${instance}_IFACES}\""
		instance_ns="$(
			ip -o -${family} addr show | $SED_CMD -nE '/^\s*[0-9]+:\s*/{s/^\s*[0-9]+\s*:\s+//;s/scope .*//;s/\s+/ /g;p;}' |
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
		eval "${instance}_NS_${family}=\"${instance_ns}\""
	done
	:
}

# populates global vars:
# DNSMASQ_INSTANCES, DNSMASQ_INSTANCES_CNT, ${instance}_IFACES,
# ALL_CONF_DIRS, ${instance}_CONF_DIRS, ${instance}_CONF_DIRS_CNT,
# ${instance}_INDEX, ${instance}_RUNNING
get_dnsmasq_instances() {
	local nonempty='' instance instances instance_index l1_conf_file l1_conf_files conf_dirs conf_dirs_cnt i s f dir
	DNSMASQ_INSTANCES=
	DNSMASQ_INSTANCES_CNT=0
	reg_action -blue "Checking dnsmasq instances."
	# shellcheck source=/dev/null
	. /usr/share/libubox/jshn.sh &&
	json_load "$(/etc/init.d/dnsmasq info)" &&
	json_get_keys nonempty &&
	[ -n "${nonempty}" ] &&
	json_select dnsmasq &&
	json_select instances &&
	json_get_keys instances || return 1

	instance_index=0
	for instance in ${instances}
	do
		case "${instance}" in
			*[!a-zA-Z0-9_]*) log_msg -warn "" "Detected dnsmasq instance with invalid name '${instance}'. Ignoring."; continue
		esac
		json_is_a "${instance}" object || continue # skip if $instance is not object
		json_select "${instance}" &&
		json_get_var "${instance}_RUNNING" running &&
		json_is_a command array &&
		json_select command || return 1

		add2list DNSMASQ_INSTANCES "${instance}" || return 1
		eval "${instance}_INDEX=${instance_index}"
		instance_index=$((instance_index+1))
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
		ifaces="$(${AWK_CMD} -F= '/^\s*interface=/ {if (!seen[$2]++) {ifaces = ifaces $2 ", "} } END {print ifaces}' "$@")"
		eval "${instance}_IFACES=\"${ifaces%, }\""

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
		eval "${instance}_CONF_DIRS=\"${conf_dirs}\""

		cnt_lines conf_dirs_cnt "${conf_dirs}"
		eval "${instance}_CONF_DIRS_CNT=\"${conf_dirs_cnt}\""
	done
	json_cleanup
	cnt_lines DNSMASQ_INSTANCES_CNT "${DNSMASQ_INSTANCES}"

	:
}

# Checks that dnsmasq instance with given ID is running and verifies that its index and conf-dir are same as in config
# 1 - instance id
# return codes:
# 0 - dnsmasq running
# 1 - dnsmasq instance is not running or other error
check_dnsmasq_instance()
{
	local instance_running dnsmasq_conf_dirs please_run="Please run 'service adblock-lean select_dnsmasq_instance'."
	[ -n "${1}" ] ||
	{
		reg_failure "dnsmasq instance is not set. ${please_run}"
		return 1
	}

	[ -n "${DNSMASQ_CONF_D}" ] ||
	{
		reg_failure "dnsmasq config directory is not set. ${please_run}"
		return 1
	}

	get_dnsmasq_instances ||
	{
		reg_failure "No running dnsmasq instances found."
		stop -noexit
		get_dnsmasq_instances ||
		{
			reg_failure "dnsmasq service appears to be broken."
			return 1
		}
	}

	eval "instance_running=\"\${${1}_RUNNING}\"" &&
	[ "${instance_running}" = 1 ] ||
	{
		reg_failure "dnsmasq instance '${1}' is not running."
		stop -noexit
		get_dnsmasq_instances &&
		eval "instance_running=\"\${${1}_RUNNING}\"" &&
		[ "${instance_running}" = 1 ] ||
		{
			reg_failure "dnsmasq instance '${1}' is misconfigured or not running. ${please_run}"
			return 1
		}
	}

	# check if config section exists in /etc/config/dhcp
	uci show "dhcp.${1}" &>/dev/null ||
	{
		reg_failure "dnsmasq instance '${1}' is running but not registered in /etc/config/dhcp. Use the command 'service dnsmasq restart' and then re-try."
		return 1
	}

	eval "dnsmasq_conf_dirs=\"\${${1}_CONF_DIRS}\""
	is_included "${DNSMASQ_CONF_D}" "${dnsmasq_conf_dirs}" ||
	{
		reg_failure "Conf-dir for dnsmasq instance '${1}' changed (was: '${DNSMASQ_CONF_D}'). ${please_run}"
		return 1
	}

	eval "instance_index=\"\${${1}_INDEX}\""
	[ "${instance_index}" = "${DNSMASQ_INDEX}" ] ||
	{
		reg_failure "dnsmasq instances changed: actual instance index '${instance_index}' doesn't match configured index '${DNSMASQ_INDEX}'. ${please_run}"
		return 1
	}

	[ -d "${DNSMASQ_CONF_D}" ] ||
	{
		reg_failure "Conf-dir '${DNSMASQ_CONF_D}' does not exist. dnsmasq instance '${1}' is misconfigured. ${please_run}"
		return 1
	}
	:
}

