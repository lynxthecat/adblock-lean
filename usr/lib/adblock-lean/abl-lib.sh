#!/bin/sh
# shellcheck disable=SC3043,SC3003,SC3001,SC3020,SC3044,SC2016,SC3057,SC3019

# silence shellcheck warnings
: "${blue:=}" "${purple:=}" "${green:=}" "${red:=}" "${yellow:=}" "${n_c:=}"
: "${blocklist_urls:=}" "${test_domains:=}" "${whitelist_mode:=}" "${compression_util:=}"
: "${luci_cron_job_creation_failed}" "${luci_pkgs_install_failed}" "${luci_tarball_url}"
: "${DNSMASQ_CONF_DIRS}"

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

suggest_addnmounts()
{
	local use_compression='' missing_addnmounts='' REPLY
	case "${compression_util}" in none|'') ;; *)
		use_compression=1
	esac

	if { [ -n "${use_compression}" ] || multi_inst_needed; } && check_confscript_support
	then
		check_addnmounts missing_addnmounts
		if [ -n "${missing_addnmounts}" ]
		then
			log_msg -yellow "" "Detected missing addnmount entries in /etc/config/dhcp for paths: ${missing_addnmounts}"
			if [ -n "${DO_DIALOGS}" ] && [ -z "${force_fix}" ]
			then
				print_msg -blue "" "Create missing addnmount entries automatically? (y|n)"
				pick_opt "y|n" || return 1
			else
				log_msg -blue "" "Automatically creating missing addnmount entries."
				REPLY=y
			fi
			[ "${REPLY}" = y ] && create_addnmounts
		fi
	fi
}

create_addnmounts()
{
	create_addnmount() {
		uci add_list "dhcp.@dnsmasq[${1}].addnmount=${2}"
	}

	local IFS="${DEFAULT_IFS}" index path paths add_list_failed=
	for index in ${DNSMASQ_INDEXES}
	do
		paths=
		[ -n "${EXTR_CMD_STDOUT%% *}" ] && add2list paths "${EXTR_CMD_STDOUT%% *}"
		add2list paths "/bin/busybox"
		if [ "${compression_util}" = none ]
		then
			if multi_inst_needed
			then
				path="${SHARED_BLOCKLIST_PATH}"
			else
				path="${DNSMASQ_CONF_DIRS%% *}/abl-blocklist"
			fi
		else
			path="${SHARED_BLOCKLIST_PATH}${COMPR_EXT}"
		fi

		if [ "${compression_util}" != none ] || multi_inst_needed
		then
			add2list paths "${path}"
		fi

		if [ -n "${paths}" ]
		then
			del_addnmounts "${index}"
			case ${?} in 0|3) ;; *) { add_list_failed=1; break; }; esac
			log_msg -purple "Creating dnsmasq addnmount entries for dnsmasq instance ${index}."
			IFS="${_NL_}"
			for path in ${paths}
			do
				IFS="${DEFAULT_IFS}"
				create_addnmount "${index}" "${path}" || { add_list_failed=1; break 2; }
			done
			IFS="${DEFAULT_IFS}"
		fi
	done

	[ -z "${add_list_failed}" ] && uci commit dhcp ||
	{
		uci revert dhcp
		reg_failure "Failed to create or change addnmount entries."
		return 1
	}
	:
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

	# create addnmount entries - enables blocklist compression and adblocking on multiple instances
	detect_processing_utils || return 1
	check_addnmounts
	case ${?} in
		0) log_msg -green "" "Found existing dnsmasq addnmount entries." ;;
		1) return 5 ;;
		2|3) create_addnmounts || return 5
	esac

	detect_pkg_manager
	case "${PKG_MANAGER}" in
		apk|opkg)
			install_packages && luci_pkgs_install_failed=
			detect_main_utils -f ;;
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
	# quasi-arrays for presets
	# cnt - target elements count/1000, mem - memory in MB
	mini_urls="hagezi:pro.mini" \
		mini_cnt=85 mini_mem=64
	small_urls="hagezi:pro" \
		small_cnt=250 small_mem=128
	medium_urls="hagezi:pro hagezi:tif.mini" \
		medium_cnt=350 medium_mem=256
	large_urls="hagezi:pro hagezi:tif" \
		large_cnt=1200 large_mem=512
	large_relaxed_urls="hagezi:pro hagezi:tif" \
		large_relaxed_cnt=1200 large_relaxed_mem=1024 large_relaxed_coeff=2
}

# sets $blocklist_urls, $min_good_line_count, $max_blocklist_file_size_KB, $max_file_part_size_KB
# requires preset vars to be set
# 1 - mini|small|medium|large|large_relaxed
# 2 - (optional) '-d' to print the description
# 2 - (optional) '-n' to print nothing (only assign values to vars)
set_preset_vars()
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

	local val field mem tgt_lines_cnt_k lim_coeff final_entry_size_B source_entry_size_B

	eval "mem=\"\${${1}_mem}\" tgt_lines_cnt_k=\"\${${1}_cnt}\" lim_coeff=\"\${${1}_coeff:-1}\" blocklist_urls=\"\${${1}_urls}\""

	# Default values calculation:
	# Values are rounded down to reasonable degree

	final_entry_size_B=20 # assumption
	source_entry_size_B=20 # assumption for raw domains format. dnsmasq source format not used by default

	# target_lines_cnt / 3.5
	min_good_line_count=$((tgt_lines_cnt_k*10000/35))
	reasonable_round min_good_line_count || return 1

	# target_lines_cnt * final_entry_size_B * lim_coeff * 1.25
	max_blocklist_file_size_KB=$(( (tgt_lines_cnt_k*1250*final_entry_size_B*lim_coeff)/1024 ))
	reasonable_round max_blocklist_file_size_KB || return 1

	case "${1}" in
		mini|small) max_file_part_size_KB=${max_blocklist_file_size_KB} ;;
		*)
			# target_lines_cnt * source_entry_size_B * lim_coeff * 1.03
			max_file_part_size_KB=$(( (tgt_lines_cnt_k*1030*source_entry_size_B*lim_coeff)/1024 ))
			reasonable_round max_file_part_size_KB || return 1
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
# (optional) -n to print with DNSMASQ_INDEXES
# (optional) -c to print with DNSMASQ_CONF_DIRS
print_def_config()
{
	# follow each default option with '@' and a pre-defined type: string, integer (implies unsigned integer), integer_list
	# or custom optional values, examples: opt1, opt1|opt2, ''|opt1|opt2

	# process args
	local preset='' print_types='' dnsmasq_indexes='' dnsmasq_conf_dirs=''
	while getopts ":n:c:p:d" opt; do
		case $opt in
			n) dnsmasq_indexes=$OPTARG ;;
			c) dnsmasq_conf_dirs=$OPTARG ;;
			p) preset=$OPTARG ;;
			d) print_types=1 ;;
			*) ;;
		esac
	done

	mk_preset_arrays
	: "${preset:=small}"
	is_included "${preset}" "${ALL_PRESETS}" " " || { reg_failure "print_def_config: \$preset var has invalid value."; return 1; }
	set_preset_vars "${preset}" -n || return 1

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

	# One or more *raw domain* format blocklist/ipv4 blocklist/allowlist URLs and/or short list identifiers separated by spaces
	# Short list identifiers have the form of [hagezi|oisd]:[list_name]. Examples: hagezi:tif.mini, oisd:big
	blocklist_urls="${blocklist_urls}" @ string
	blocklist_ipv4_urls="" @ string
	allowlist_urls="" @ string

	# One or more *dnsmasq format* domain blocklist/ipv4 blocklist/allowlist URLs separated by spaces
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

	# dnsmasq instance indexes and config directories
	# normally this should be set automatically by the 'setup' command
	DNSMASQ_INDEXES="${dnsmasq_indexes}" @ integer_list
	DNSMASQ_CONF_DIRS="${dnsmasq_conf_dirs}" @ string

	EOT
}

# generates config
do_gen_config()
{
	local cnt totalmem preset

	if [ -n "${DO_DIALOGS}" ] && [ -z "${luci_preset}" ]
	then
		mk_preset_arrays
		get_def_preset preset totalmem || print_msg "Skipping automatic preset recommendation."
		if [ -n "${preset}" ]
		then
			print_msg "" "Based on the total usable memory of this device ($(bytes2human $((totalmem*1024)) )), the recommended preset is '${purple}${preset}${n_c}':"
			set_preset_vars "${preset}" || return 1
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
				set_preset_vars "${preset}" -d || return 1
			done
			print_msg "" "Pick preset:"
			pick_opt "${presets_case_opts}"
			preset="${REPLY}"
		fi
	else
		# determine preset for luci
		case "${luci_preset}" in
			''|auto) get_def_preset preset totalmem || { log_msg "Falling back to preset 'small'."; preset=small; } ;;
			*) preset="${luci_preset}"
		esac
	fi

	is_included "${preset}" "${ALL_PRESETS}" " " || { reg_failure "Invalid preset '${preset}'."; return 1; }
	log_msg -blue "Selected preset '${preset}'."

	select_dnsmasq_instances -n || { reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."; return 1; }

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
	write_config "$(print_def_config -p "${preset}" -n "${DNSMASQ_INDEXES}" -c "${DNSMASQ_CONF_DIRS}")" || return 1

	:
}

# sets ${1} to recommended preset, depending on system memory capacity; ${2} to detected totalmem
# expects preset vars to be set
get_def_preset()
{
	are_var_names_safe "${1}" "${2}" || return 1
	unset "${1}" "${2}"
	local _totalmem _mem _preset IFS="${DEFAULT_IFS}"
	[ -n "${ALL_PRESETS}" ] && eval "[ -n \"\${${ALL_PRESETS%% *}_mem}\" ]" ||
		{ reg_failure "get_def_preset: essential vars are unset."; return 1; }

	read -r _ _totalmem _ < /proc/meminfo
	case "${_totalmem}" in
		''|*[!0-9]*)
			reg_failure "\$_totalmem has invalid value '${_totalmem}'. Failed to determine system memory capacity."
			log_msg "Unable to select best preset for this system."
			return 1 ;;
		*)
			for _preset in $(printf %s "${ALL_PRESETS}" | tr ' ' '\n' | ${SED_CMD} 'x;1!H;$!d;x') # loop over presets in reverse order
			do
				eval "_mem=\"\${${_preset}_mem}\""
				# multiplying by 800 rather than 1024 to account for some memory not available to the kernel
				[ "${_totalmem}" -ge $((_mem * 800)) ] && break
			done
	esac
	eval "${1}"='${_preset}' "${2}"='${_totalmem}'
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

	local def_config='' curr_config='' missing_entries='' unexp_keys='' unexp_entries='' \
		p_migrated_keys='' migrate_keys='' migrate_entries='' \
		key val bad_val_entries='' corrected_entries='' \
		p_conf_fixes='' missing_keys='' bad_val_keys='' \
		sed_conf_san_exp='/^\s*#.*$/d; s/^\s+//; s/\s+=/=/; s/=\s+/=/; s/\s+$//; /^$/d'

	are_var_names_safe "${2}" "${3}" "${4}" || return 1
	eval "${2:-_}='' ${3:-_}='' ${4:-_}=''"

	unset curr_config_format def_config_format \
		luci_curr_config_format luci_def_config_format luci_unexp_keys luci_unexp_entries luci_missing_keys luci_missing_entries \
		luci_bad_conf_format luci_conf_fixes preset

	# newline-separated list of options to migrate in the format <old_key=new_key>
	MIGRATE_OPTS='
		DNSMASQ_INDEX=DNSMASQ_INDEXES
		DNSMASQ_CONF_D=DNSMASQ_CONF_DIRS
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

	local parse_vars valid_lines
	# extract valid values from default config
	valid_lines="$(print_def_config -d | ${SED_CMD} "${sed_conf_san_exp}")"
	# parse config
	local parser_error_file="${ABL_CONF_STAGING_DIR}/parser_error" inval_entry_file="${ABL_CONF_STAGING_DIR}/inval_entry"
	rm -f "${parser_error_file}" "${inval_entry_file}" "${ABL_CONF_STAGING_DIR}/unexp_entries" \
		"${ABL_CONF_STAGING_DIR}/bad_val_entries" "${ABL_CONF_STAGING_DIR}/missing_entries"

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

		# create arrays: def_arr, valid_values_regex_arr, valid_values_print_arr
		BEGIN{
			rv=0
			line_comp[1]="key"
			line_comp[2]="value"
			line_comp[3]="allowed values"

			# create def_lines_arr
			split(V,def_lines_arr,"\n")
			for (ind in def_lines_arr) {
				# remove whitespaces/tabs
				sub(/"[ \t]*@[ \t]*/,"\"@",def_lines_arr[ind])
				def_lines_arr[ind]=def_lines_arr[ind]
				# validate default config line
				n=split(def_lines_arr[ind],def_line_parts,"[=@]") # split into key, value, allowed values
				if (n!=3) {print "Invalid line in default config: " q def_lines_arr[ind] q "." > "/dev/stderr"; rv=1; exit}
				for (i in def_line_parts) {
					if (! def_line_parts[i]) {
						print "Invalid line in default config: " q def_lines_arr[ind] q " is missing the " line_comp[i] "." > "/dev/stderr"
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
					migrate_opts=migrate_opts "MIGRATE_" new_key "=" val "\n"
					print $0 >> A"/migrate_entries"
					next
				}
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
				"bad_val_keys=\"" bad_val_keys "\" " \
				migrate_opts
			exit rv
		}'
	)" 2> "${parser_error_file}" && [ ! -s "${parser_error_file}" ] ||
	{
		local awk_rv=${?} inval_entry=''
		[ -s "${parser_error_file}" ] && reg_failure "awk errors encountered while parsing config:${_NL_}$(cat "${parser_error_file}")"
		[ -s "${inval_entry_file}" ] && inval_entry=": $(cat "${inval_entry_file}")"

		case "${awk_rv}" in
			253) reg_failure "Invalid entry in config (check double-quotes)${inval_entry}." ;;
			254) reg_failure "Invalid entry in config${inval_entry}." ;;
			*) reg_failure "Failed to parse config."; return 3
		esac

		return 1
	}

	local err_print=''
	rm -f "${parser_error_file}"

	eval "${parse_vars}" 2> "${parser_error_file}" && [ ! -s "${parser_error_file}" ] ||
	{
		[ -s "${parser_error_file}" ] && err_print=" Errors: ${_NL_}$(cat "${parser_error_file}")"
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

	if [ -n "${unexp_keys}" ]
	then
		log_msg -yellow "" "Unexpected keys in config: '${unexp_keys% }'."
		unexp_entries="$(cat "${ABL_CONF_STAGING_DIR}/unexp_entries")"
		print_msg "Corresponding config entries:" "${unexp_entries%$'\n'}"
		add_conf_fix "Remove unexpected entries from the config"
		export luci_unexp_keys="${unexp_keys% }" luci_unexp_entries="${unexp_entries%$'\n'}"
	fi

	if [ -n "${missing_keys}" ]
	then
		log_msg -yellow "" "Missing keys in config: '${missing_keys% }'."
		missing_entries="$(cat "${ABL_CONF_STAGING_DIR}/missing_entries")"
		print_msg "Corresponding default config entries:" "${missing_entries%$'\n'}"
		add_conf_fix "Re-add missing config entries with default values"
		export luci_missing_keys="${missing_keys% }" luci_missing_entries="${missing_entries%$'\n'}"
	fi

	if [ -n "${bad_val_keys}" ]
	then
		log_msg -yellow "" "Detected config entries with unexpected values."
		bad_val_entries="$(cat "${ABL_CONF_STAGING_DIR}/bad_val_entries")"
		corrected_entries="$(cat "${ABL_CONF_STAGING_DIR}/corrected_entries")"
		print_msg "The following config entries have unexpected values:" "${bad_val_entries%$'\n'}" "" \
			"Corresponding default config entries:" "${corrected_entries%$'\n'}"
		add_conf_fix "Replace unexpected values with defaults"
		export luci_bad_val_entries="${bad_val_entries%$'\n'}" luci_corrected_entries="${corrected_entries%$'\n'}"
	fi

	if [ -z "${p_conf_fixes}" ]
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

	p_conf_fixes="${p_conf_fixes%$'\n'}"
	export luci_conf_fixes="${p_conf_fixes}"

	eval "${2:-_}=\"${p_conf_fixes}\" ${3:-_}=\"${missing_keys}${bad_val_keys}\" ${4:-_}=\"${p_migrated_keys}\""

	[ -n "${p_conf_fixes}" ] && return 2
	:
}

# shellcheck disable=SC2120
# 1 - (optional) '-f' to force fixing the config if it has issues
load_config()
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

	local key val line force_fix='' l_replace_keys='' l_migrated_keys='' l_conf_fixes=''
	[ "${1}" = '-f' ] || [ -n "${APPROVE_UPD_CHANGES}" ] && force_fix=1

	# Need to set DO_DIALOGS here for compatibility when updating from earlier versions
	local DO_DIALOGS=
	[ -z "${ABL_LUCI_SOURCED}" ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] && DO_DIALOGS=1

	if [ ! -f "${ABL_CONFIG_FILE}" ]
	then
		reg_failure "Config file is missing."
		log_msg "Generate default config using 'service adblock-lean gen_config'."
		return 1
	fi

	local tip_msg="Fix your config file '${ABL_CONFIG_FILE}' or generate default config using 'service adblock-lean gen_config'."

	# validate config and assign to variables
	parse_config "${ABL_CONFIG_FILE}" l_conf_fixes l_replace_keys l_migrated_keys
	case ${?} in
		0) return 0 ;;
		1) log_msg "${tip_msg}"; return 1 ;; # config error with no automatic fix
		2) ;; # config error(s) with automatic fix
		3) return 1 # internal parser error
	esac

	# if not in interactive console and force-fix not set, return error
	[ -z "${DO_DIALOGS}" ] && [ -z "${force_fix}" ] && { log_msg "${tip_msg}"; return 1; }

	# sanity check
	[ -z "${l_conf_fixes}" ] && { reg_failure "Failed to parse config."; return 1; }

	if [ -n "${DO_DIALOGS}" ] && [ -z "${force_fix}" ]
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

	[ "${REPLY}" = n ] && { log_msg "${tip_msg}"; return 1; }

	fix_config "${l_replace_keys}" "${l_migrated_keys}" || { reg_failure "Failed to fix the config."; log_msg "${tip_msg}"; return 1; }

	# automatically create missing addnmount entries during version update
	if [ -n "${ABL_IN_INSTALL}" ] && [ -n "${DNSMASQ_INDEXES}" ] && get_dnsmasq_instances && detect_processing_utils
	then
		suggest_addnmounts
	fi

	:
}

# 1 - keys to replace (whitespace-separated)
# 2 - keys to migrate
fix_config()
{
	local replace_keys="${1}" migrated_keys="${2}" fixed_config

	case "${replace_keys}" in
		*DNSMASQ_INDEXES*|*DNSMASQ_CONF_DIRS*)
			select_dnsmasq_instances -n || return 1
			# shellcheck disable=SC2034
			MIGRATE_DNSMASQ_INDEXES="${DNSMASQ_INDEXES}" MIGRATE_DNSMASQ_CONF_DIRS="${DNSMASQ_CONF_DIRS}" ;;
	esac

	# recreate config from default while replacing values with values from the existing config
	fixed_config="$(
		print_def_config -n "${DNSMASQ_INDEXES}" -c "${DNSMASQ_CONF_DIRS}" |
		while IFS="${_NL_}" read -r def_line
		do
			case "${def_line}" in
				\#*|'') printf '%s\n' "${def_line}"; continue ;;
				*=*)
					key=${def_line%%=*}
					curr_val=
					if is_included "${key}" "${replace_keys}" " "
					then
						printf '%s\n' "${def_line}"
						continue
					elif is_included "${key}" "${migrated_keys}" " "
					then
						eval "[ -n \"\${MIGRATE_${key}+set}\" ]" ||
							{ reg_failure "fix_config: '\$MIGRATE_${key}' not set."; exit 1; }
						eval "curr_val=\"\${MIGRATE_${key}}\""
						printf '%s\n' "${key}=\"${curr_val}\""
						continue
					fi
					eval "curr_val=\"\${${key}}\""
					printf '%s\n' "${key}=\"${curr_val}\""
					continue
			esac
		done
		:
	)" || return 1

	local old_config_f="/tmp/adblock-lean_config.old"
	if ! cp "${ABL_CONFIG_FILE}" "${old_config_f}"
	then
		reg_failure "Failed to save old config file as ${old_config_f}."
		if [ -z "${APPROVE_UPD_CHANGES}" ]
		then
			[ -z "${DO_DIALOGS}" ] && return 1
			log_msg "Proceed with suggested config changes? (y|n)"
			pick_opt "y|n" || return 1
			[ "${REPLY}" = n ] && return 1
		fi
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
	local tmp_config="${ABL_CONF_STAGING_DIR}/write-config.tmp"

	[ -z "${1}" ] && { reg_failure "write_config(): no config passed."; return 1; }

	if [ -n "${DO_DIALOGS}" ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ -f "${ABL_CONFIG_FILE}" ]
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

multi_inst_needed()
{
	case "${DNSMASQ_INDEXES}" in *[0-9]" "[0-9]*) return 0; esac
	return 1
}

# 1 (optional) - var name for missing addnmounts output

# return codes:
# 0 - compression and multiple instances possible
# 1 - error
# 2 - compression not possible, multiple instances possible
# 3 - compression and multiple instances not possible
# shellcheck disable=SC2120
check_addnmounts()
{
	[ -n "${1}" ] && unset "${1}"
	local rv ca_missing=
	try_check_addnmounts
	rv=${?}
	[ -n "${1}" ] && eval "${1}=\"${ca_missing}\""
	[ ${rv} = 1 ] && reg_failure "Failed to check addnmount entries for dnsmasq instances."
	return ${rv}
}

try_check_addnmounts()
{
	check_addnmount()
	{
		local path="${1}"
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

	local me=check_addnmounts index addnmounts req_path rv='' compr_addnm_missing

	check_util uci || { reg_failure "${me}: uci not found."; return 1; }

	for index in ${DNSMASQ_INDEXES}
	do
		case "${index}" in
			''|*[!0-9]*)
				reg_failure "${me}: Invalid dnsmasq index '${index}'."
				return 1
		esac
		addnmounts="$(uci -q get dhcp.@dnsmasq["${index}"].addnmount | ${SED_CMD} -E 's~/(\s|$)~ ~g')" ||
			{ reg_failure "${me}: uci command failed."; return 1; }

		check_addnmount "/bin/busybox"
		case ${?} in
			0) ;;
			1) return 1 ;;
			*)
				rv=3
				add2list ca_missing "/bin/busybox" ' '
		esac

		compr_addnm_missing=
		if [ "${compression_util}" != none ] &&
			for req_path in "${EXTR_CMD_STDOUT%% *}" "${SHARED_BLOCKLIST_PATH}${COMPR_EXT}"
			do
				[ -n "${req_path}" ] || { reg_failure "${me}: internal error."; return 1; }
				check_addnmount "${req_path}"
				case "${?}" in
					0) : ;;
					1) return 1 ;;
					*)
						: "${rv:=2}"
						add2list ca_missing "${req_path}" ' '; compr_addnm_missing=1
				esac
			done && [ -z "${compr_addnm_missing}" ]
		then
			:
		elif multi_inst_needed
		then
			check_addnmount "${SHARED_BLOCKLIST_PATH}"
			case ${?} in
				0) ;;
				1) return 1 ;;
				*)
					rv=3
					[ "${compression_util}" = none ] && add2list ca_missing "${SHARED_BLOCKLIST_PATH}" ' '
			esac
		fi
	done

	return ${rv:-0}
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

	get_dnsmasq_instances && [ "${DNSMASQ_INSTANCES_CNT}" != 0 ] ||
	{
		reg_failure "Failed to detect dnsmasq instances or no dnsmasq instances are running."
		stop -noexit
		get_dnsmasq_instances && [ "${DNSMASQ_INSTANCES_CNT}" != 0 ] || return 1
	}

	local conf_dirs='' conf_dirs_instance index indexes='' ifaces='' REPLY first diff conf_dirs_cnt conf_dirs_print='' add_dir

	if [ "${DNSMASQ_INSTANCES_CNT}" = 1 ]
	then
		log_msg -blue "Detected only 1 dnsmasq instance - skipping manual instance selection."
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
			log_msg -blue "Detected multiple dnsmasq instances which are using the same conf-dir. Skipping manual instance selection."
			DNSMASQ_INDEXES="${DNSMASQ_RUNNING_INDEXES%% *}"
		else
			# if conf-dirs are not shared, ask the user
			log_msg -blue "Multiple dnsmasq instances detected."
			REPLY=a
			if [ -n "${DO_DIALOGS}" ]
			then
				log_msg "" "Existing dnsmasq instances and assigned network interfaces:"
				for index in ${DNSMASQ_RUNNING_INDEXES}
				do
					eval "instance=\"\${INST_NAME_${index}}\"" \
						"ifaces=\"\${IFACES_${index}}\""
					log_msg "${index}. Instance '${instance}': interfaces '${ifaces}'"
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

			[ "${REPLY}" = a ] && { log_msg "Aborted config generation."; exit 0; }
			DNSMASQ_INDEXES="${REPLY}"
		fi
	fi
	log_msg "Selected dnsmasq indexes: '${DNSMASQ_INDEXES}'."

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

	detect_processing_utils && suggest_addnmounts

	:
}

clean_dnsmasq_dir()
{
	[ -n "${ALL_CONF_DIRS}" ] || { get_dnsmasq_instances; [ -n "${ALL_CONF_DIRS}" ]; } ||
		{ reg_failure "Failed to detect dnsmasq conf directory. Can not remove adblock-lean files."; return 1; }
	local IFS="${_NL_}"
	for dir in ${ALL_CONF_DIRS}
	do
		IFS="${DEFAULT_IFS}"
		rm -f "${dir}"/.abl-blocklist.* "${dir}"/abl-blocklist \
			"${dir}"/abl-conf-script "${dir}"/.abl-extract_blocklist
	done
	rm -f "${SHARED_BLOCKLIST_PATH:-???}"*
	:
}

# populates global vars:
# ALL_CONF_DIRS, DNSMASQ_RUNNING_INDEXES, DNSMASQ_INSTANCES_CNT
# INST_NAME_${index}, IFACES_${index}, CONF_DIRS_${index}, CONF_DIRS_CNT_${index}, RUNNING_${index},
get_dnsmasq_instances() {
	# shellcheck disable=SC2317
	add_conf_dir()
	{
		local confdir
		config_get confdir "${1}" confdir
		[ -n "${confdir}" ] && add2list ALL_CONF_DIRS "${confdir}"
	}

	local nonempty='' instance instances running_instances index l1_conf_file l1_conf_files conf_dirs i s f dir 
	unset DNSMASQ_RUNNING_INDEXES ALL_CONF_DIRS
	DNSMASQ_INSTANCES_CNT=0
	reg_action -blue "Checking dnsmasq instances."

	# gather conf dirs from /etc/config/dhcp
	if [ -z "${DHCP_LOADED}" ]
	then
		# shellcheck source=/dev/null
		{ check_func config_load 1>/dev/null || . /lib/functions.sh; } &&
		config_load dhcp ||
			{ reg_failure "Failed to load /etc/config/dhcp"; return 1; }
		DHCP_LOADED=1
	fi

	config_foreach add_conf_dir dnsmasq

	# gather conf dirs from /tmp/
	for dir in /tmp/dnsmasq.d /tmp/dnsmasq.cfg*
	do
		case "${dir}" in ''|*".cfg*") continue; esac
		add2list ALL_CONF_DIRS "${dir}"
	done

	# gather info from '/etc/init.d/dnsmasq info'

	# shellcheck source=/dev/null
	. /usr/share/libubox/jshn.sh &&
	json_load "$(/etc/init.d/dnsmasq info)" &&
	json_get_keys nonempty &&
	[ -n "${nonempty}" ] &&
	json_select dnsmasq &&
	json_select instances &&
	json_get_keys instances || return 1

	index=0
	for instance in ${instances}
	do
		unset "INST_NAME_${index}" "RUNNING_${index}" "IFACES_${index}" "CONF_DIRS_${index}" "CONF_DIRS_CNT_${index}"

		case "${instance}" in
			*[!a-zA-Z0-9_]*) log_msg -warn "" "Detected dnsmasq instance with invalid name '${instance}'. Ignoring."; continue
		esac
		json_is_a "${instance}" object || continue # skip if $instance is not object
		json_select "${instance}" &&
		json_get_var "RUNNING_${index}" running &&
		json_is_a command array &&
		json_select command || return 1

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
		ifaces="$(${AWK_CMD} -F= '/^\s*interface=/ {if (!seen[$2]++) {ifaces = ifaces $2 ", "} } END {print ifaces}' "$@")"

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
		eval "INST_NAME_${index}=\"${instance}\"
			CONF_DIRS_${index}=\"${conf_dirs}\"
			IFACES_${index}=\"${ifaces%, }\""
		cnt_lines "CONF_DIRS_CNT_${index}" "${conf_dirs}"
		index=$((index+1))
	done
	json_cleanup
	cnt_lines DNSMASQ_INSTANCES_CNT "${running_instances}"

	:
}

# Checks that configured dnsmasq instances are running and verifies that their indexes and conf-dirs match the config
# return codes:
# 0 - dnsmasq running
# 1 - dnsmasq instance is not running or other error
check_dnsmasq_instances()
{
	local instance index dir instance_conf_dirs conf_dir_reg all_abl_conf_dirs='' \
		inst_ind="dnsmasq instance with index" please_run="Please run 'service adblock-lean select_dnsmasq_instances'."

	get_dnsmasq_instances ||
	{
		reg_failure "No running dnsmasq instances found."
		stop -noexit
		get_dnsmasq_instances || { reg_failure "dnsmasq service appears to be broken."; return 1; }
	}

	[ -n "${DNSMASQ_INDEXES}" ] || { reg_failure "dnsmasq instances are not set."; return 1; }

	for index in ${DNSMASQ_INDEXES}
	do
		eval "[ \"\${RUNNING_${index}}\" = 1 ]" ||
		{
			reg_failure "${inst_ind} ${index} is not running."
			stop -noexit
			get_dnsmasq_instances &&
			eval "[ \"\${RUNNING_${index}}\" = 1 ]" ||
			{
				reg_failure "${inst_ind} ${index} is misconfigured or not running."
				return 1
			}
		}

		conf_dir_reg=
		eval "instance_conf_dirs=\"\${CONF_DIRS_${index}}\""
		[ -n "${instance_conf_dirs}" ] || { reg_failure "dnsmasq config directory is not set for instance with index ${index}."; return 1; }
		all_abl_conf_dirs="${all_abl_conf_dirs}${instance_conf_dirs}${_NL_}"

		local IFS="${_NL_}"
		for dir in ${instance_conf_dirs}
		do
			IFS="${DEFAULT_IFS}"
			is_included "${dir}" "${DNSMASQ_CONF_DIRS}" " " && conf_dir_reg=1
			[ -d "${dir}" ] ||
			{
				reg_failure "Conf-dir '${dir}' does not exist. ${inst_ind} ${index} is misconfigured. ${please_run}"
				return 1
			}
		done
		IFS="${DEFAULT_IFS}"

		[ -n "${conf_dir_reg}" ] ||
		{
			reg_failure "Conf-dirs for ${inst_ind} ${index} changed. ${please_run}"
			return 1
		}

		# check if config section exists in /etc/config/dhcp
		uci show "dhcp.@dnsmasq[${index}]" &>/dev/null ||
		{
			reg_failure "${inst_ind} ${index} is running but not registered in /etc/config/dhcp. Use the command 'service dnsmasq restart' and then re-try."
			return 1
		}
	done

	for dir in ${DNSMASQ_CONF_DIRS}
	do
		is_included "${dir}" "${all_abl_conf_dirs}" "${_NL_}" ||
			{ reg_failure "conf-dir directory '${dir}' is set in config but not used by dnsmasq instances '${DNSMASQ_INDEXES}'."; return 1; }
	done

	:
}

