#!/bin/sh
# shellcheck disable=SC3043,SC1090,SC3044,SC3060,SC3040,SC3045,SC2181
# shellcheck source=/dev/null

export -n ABL_INSTALLER_VER=4

ABL_SERVICE_PATH=/etc/init.d/adblock-lean
ABL_TMP_DIR=/var/run/adblock-lean/tmp
ABL_INST_DIR=${ABL_TMP_DIR}/remote_abl
ABL_PID_DIR=/tmp/abl-pid
ABL_CFG_DIR=/etc/adblock-lean

LEGACY_CFG_FILE=/etc/adblock-lean/config # unified config was used in adblock-lean v0.8.1 and earlier
GLOBAL_CFG_FILE=${ABL_CFG_DIR}/global.conf
UCL_ERR_FILE=${ABL_TMP_DIR}/uclient-fetch_err

: "${ABL_REPO_AUTHOR:=lynxthecat}"
ABL_GH_URL_API="https://api.github.com/repos/${ABL_REPO_AUTHOR}/adblock-lean"
ABL_MAIN_BRANCH=master
ABL_FILES_REG_PATH=/etc/adblock-lean/abl-reg.md5

LC_ALL=C
_NL_='
'
DEFAULT_IFS="	 ${_NL_}"
IFS="${DEFAULT_IFS}"

_DELIM_="$(printf '\35')"

if [ -z "${MSGS_DEST}" ]
then
	if [ -t 0 ]
	then
		export MSGS_DEST=/dev/tty
	else
		export MSGS_DEST=/dev/null
	fi
fi

# $luci_skip_dialogs is set if sourced from external RPC script for luci
[ -n "${luci_skip_dialogs}" ] && export -n ABL_LUCI_SOURCED=1

[ -z "${DO_DIALOGS}" ] && [ -z "${ABL_LUCI_SOURCED}" ] && [ -z "${APPROVE_UPD_CHANGES}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] && \
	DO_DIALOGS=1

if sed --version 2>/dev/null | grep -qe '(GNU sed)'
then
	SED_CMD="sed"
else
	SED_CMD="busybox sed"
fi

AWK_CMD="/bin/busybox awk"


check_util_install() { command -v "${1:?}" 1>/dev/null; }

is_uint_install()
{
	local _v
	for _v in "${@}"
	do
		case "${_v}" in
			''|*[!0-9]*) return 1
		esac
	done
	:
}

# adds a string to a space-separated list if it's not included yet
# 1 - name of var which contains the list
# 2 - new value(s)
# 3 - (optional) list delimiter (instead of whitespace)
# returns 1 if bad var name, 0 otherwise
add2list_install() {
	case "${1:?}" in *[!A-Za-z0-9_]*)
		return 1
	esac

	local a2l_val curr_list delim="${3:-" "}"

	eval "curr_list=\"\${${1}}\""
	local IFS="${delim}"
	for a2l_val in ${2}
	do
		case "${a2l_val}" in '') continue; esac
		is_included_install "${a2l_val}" "${curr_list}" "${delim}" && continue
		curr_list="${curr_list}${curr_list:+"${delim}"}${a2l_val}"
	done
	export -n "${1}=${curr_list}"
	:
}

# checks if string $1 is included in newline-separated list $2
# if $3 is specified, uses the value as list delimiter
# result via return status
is_included_install() {
	local delim="${3:-"${_NL_}"}"
	case "$2" in
		"$1"|"$1${delim}"*|*"${delim}$1"|*"${delim}$1${delim}"*)
			return 0 ;;
		*)
			return 1
	esac
}

# sets global variables for colors, tab delimiter and cr_lf
set_ansi_install()
{
	local IFS=" "
	# shellcheck disable=SC2046
	set -- $(printf '\033[0;31m \033[0;32m \033[1;34m \033[1;33m \033[0;35m \033[38;5;214m \033[0m \35 \t \r')
	export -n red="${1}" green="${2}" blue="${3}" yellow="${4}" purple="${5}" orange="${6}" n_c="${7}" _DELIM_="${8}" TAB="${9}" CR="${10}" CR_LF="${10}${_NL_}"
}

# exit with code ${1}
# if function 'abl_luci_exit' is defined, execute it before exit
cleanup_and_exit_install()
{
	trap - INT TERM EXIT
	rm -rf "${ABL_TMP_DIR}" "${ABL_PID_DIR}"
	[ "${1}" = 1 ] && reg_failure_install "Failed to install adblock-lean."
	[ -n "${ABL_LUCI_SOURCED}" ] && abl_inst_luci_exit "${1}"
	exit "${1}"
}

unset_vars_install()
{
	are_var_names_safe_install "${@}" || return 1
	local var
	for var in "${@}"
	do
		[ -n "${var}" ] && export -n "${var}="
	done
	:
}

# check if var names are safe to use with eval
are_var_names_safe_install() {
	local var_name
	for var_name in "${@}"
	do
		case "${var_name}" in *[!a-zA-Z_]*) reg_failure_install "Invalid var name '${var_name}'."; return 1; esac
	done
	:
}

check_func_install()
{
	[ "$(type "${1}" 2>/dev/null | head -n1)" = "${1} is a function" ]
}

# asks the user to pick an option
# 1 - input in the format 'a|b|c'
# output via $REPLY
pick_opt_install()
{
	while :
	do
		printf %s "${1}: " 1>"${MSGS_DEST}"
		read -r REPLY
		case "${REPLY}" in *[!A-Za-z0-9_]*) printf '\n%s\n\n' "Please enter ${1}" 1>"${MSGS_DEST}"; continue; esac
		eval "case \"\${REPLY}\" in
				${1}) return 0 ;;
				*) printf '\n%s\n\n' \"Please enter \${1}\" 1>\"\${MSGS_DEST}\"
			esac"
	done
}

# Env vars:
#   FF_EXEC=<cmd>: execute command for each found and processed file. '{}' in <cmd> is replaced with path to file.
# Args:
#   1: var name for newline-separated paths output
#   2: dir
#   3: filename prefix
#   4: filename mid
#   5: filename suffix
find_files_install()
{
	local me=find_files_install exec='' ff_file ff_found='' \
		ff_path_out_var="${1}" ff_dir="${2}" ff_prefix="${3}" ff_mid="${4}" ff_suffix="${5}"

	unset_vars_install "${ff_path_out_var}" || return 1

	[ -n "${FF_EXEC}" ] && { check_util_install "${FF_EXEC%% *}" || { reg_failure_install "${me}: invalid exec cmd '${FF_EXEC}'"; return 1; }; }

	# shellcheck disable=SC2027
	for ff_file in "${ff_dir}/${ff_prefix}"${ff_mid}"${ff_suffix}"
	do
		case "${ff_file}" in
			''|*"*"*) continue ;;
			[\$\(\)\{\}\"\`\'] ) reg_msg_install -warn "${me}: path '${ff_file}' contains unsupported characters. Ignoring the file."; continue
		esac
		[ -f "${ff_file}" ] || continue # ignore dirs and symlinks

		[ -n "${FF_EXEC}" ] &&
		{
			exec="${FF_EXEC//"{}"/"\"${ff_file}\""}"
			eval "${exec}" || { reg_failure_install "${me}: '${exec}' returned code ${?}"; return 1; }
		}

		ff_found="${ff_found}${ff_found:+"${_NL_}"}${ff_file}"
	done

	[ -n "${ff_found}" ] || return 2

	export -n "${ff_path_out_var:-_}=${ff_found}" || return 1
	:
}

# Splits path to file into dir, filename, ext
split_path_install()
{
	local sp_file='' sp_fname='' sp_ext='' sp_dir='' \
		sp_dir_out_var="${1}" sp_fname_out_var="${2}" sp_ext_out_var="${3}" sp_path="${4}"

	unset_vars_install "${sp_dir_out_var}" "${sp_fname_out_var}" "${sp_ext_out_var}" || return 1

	case "${sp_path}" in
		# ignore files directly in /
		/[!/]*)
			sp_file="${sp_path##*"/"}"
			sp_fname="${sp_file%.*}"
			case "${sp_file}" in
				*.*) sp_ext="${sp_file##*.}" ;;
			esac
	esac

	[ -n "${sp_fname}" ] || return 1

	sp_dir="${sp_path%"${sp_file}"}"
	sp_dir="${sp_dir%"/"}"

	[ -n "${sp_dir}" ] && [ -n "${sp_fname}" ] &&
	export -n "${sp_dir_out_var}=${sp_dir}" "${sp_fname_out_var}=${sp_fname}" "${sp_ext_out_var}=${sp_ext}"
}

# 0 - (optional) '-p'
# 1 - path
try_mkdir_install()
{
	local p=
	[ "${1}" = '-p' ] && { p='-p'; shift; }
	[ -d "${1}" ] && return 0
	mkdir ${p} "${1}" || { reg_failure_install "Failed to create directory '${1}'."; return 1; }
	:
}

print_msg_install()
{ reg_msg_install -4 "${@}"; }

log_msg_install()
{ reg_msg_install -1 "${@}"; }

# Depending on msg-specific log level, on global ${ABL_LOG_LEVEL} and on ${ABL_DEBUG}:
# Prints each msg separately to console [ and to log file ] [ and sends to system log ]
# -[0|1|2|3|4|5] : specifies log level (default: 3)
# Optional arguments: '-noprint', '-nolog', '-err', '-warn', '-[color]'
reg_msg_install()
{
	append_msg()
	{
		msgs="${msgs}${msgs_prefix}${1}${_DELIM_}"
		[ -n "${msgs_prefix}" ] && msgs_prefix=
	}

	local m msgs='' msgs_prefix='' _arg err_l=info color='' _n_c='' noprint='' \
		log_level='' nolog=''

	# Default log levels:
	# 1 - syslog and session log
	# 2 - session log (more important messages)
	# 3 - session log (less important messages)
	# 4 - print to /dev/tty
	# 5 - debug messages: print to /dev/stderr

	# ${ABL_LOG_LEVEL} <n> modifies which levels are sent to syslog

	local msgs_dest="${MSGS_DEST}" session_log_thresh=3 \
		sys_log_thresh="${ABL_LOG_LEVEL:-"1"}" print_thresh=4

	[ -n "${ABL_DEBUG}" ] && print_thresh=5

	local IFS="${DEFAULT_IFS}"
	for _arg in "${@}"
	do
		case "${_arg}" in
			-[0-9])
				if [ -z "${log_level}" ]
				then
					log_level="${_arg#"-"}"
				else
					append_msg "${_arg}"
				fi ;;
			"-noprint") noprint=1 ;;
			"-nolog") nolog=1 ;;
			"-err") err_l=err color="${red}" msgs_prefix="Error: " ;;
			"-warn") err_l=warn color="${yellow}" msgs_prefix="Warning: " ;;
			-blue|-red|-green|-purple|-yellow) eval "color=\"\$${_arg#"-"}\"" ;;
			'') msgs="${msgs}dummy${_DELIM_}" ;;
			*) append_msg "${_arg}"
		esac
	done
	msgs="${msgs%"${_DELIM_}"}"
	[ -n "${color}" ] && _n_c="${n_c}"

	: "${log_level:=3}"

	[ "${log_level}" = 5 ] && msgs_dest="/dev/stderr" # Debug

	set -f
	IFS="${_DELIM_}"
	for m in ${msgs}
	do
		IFS="${DEFAULT_IFS}"
		case "${m}" in
			dummy) printf '\n' > "${msgs_dest}" ;;
			*)
				[ -z "${noprint}" ] && [ "${log_level}" -le "${print_thresh}" ] &&
					printf '%s\n' "${color}${m}${_n_c}" > "${msgs_dest}"

				[ -z "${nolog}" ] && [ "${log_level}" -le "${sys_log_thresh}" ] &&
					logger -t adblock-lean -p user."${err_l}" "${m}"

				[ "${log_level}" -le "${session_log_thresh}" ] &&
					write_log_file_install "${m}" "${err_l}"
		esac
	done
	IFS="${DEFAULT_IFS}"
	set +f
}

# 1 - msg
# 2 - err level
write_log_file_install()
{
	[ -n "${ABL_CURR_LOG_FILE}" ] && date +"[%b %d %Y, %H:%M:%S] ${2:-info}: ${1}" >> "${ABL_CURR_LOG_FILE}"
}

reg_failure_install()
{
	log_msg_install -err "" "${1}"
	luci_errors="${luci_errors}${1}${_NL_}"
}

get_cfg_id_install()
{
	local _cfg_id \
		_cfg_fname="${2##*"/"}"

	case "${_cfg_fname}" in
		config|global.conf|blockset-*.conf) : ;;
		*)
			reg_failure_install "Invalid config filename '${_cfg_fname}' in file '${2}'. Only English letters, numbers and underlines are allowed. Ignoring the file."
			return 1
	esac

	_cfg_id="${_cfg_fname#"blockset-"}"
	_cfg_id="${_cfg_id%".conf"}"
	case "${_cfg_id}" in
		''|*[!a-zA-Z0-9_]*)
			reg_failure_install "Invalid config name '${_cfg_id}' in file '${2}'. Only English letters, numbers and underlines are allowed. Ignoring the file."
			return 1 ;;
	esac
	export -n "${1}=${_cfg_id}"
	:
}

inst_failed()
{
	local fail_msg="${1}"
	[ -s "${UCL_ERR_FILE}" ] && fail_msg="${fail_msg} uclient-fetch errors: '$(cat "${UCL_ERR_FILE}")'"
	rm -rf "${ABL_INST_DIR}" "${UCL_ERR_FILE}"
	[ -n "${fail_msg}" ] && reg_failure_install "${fail_msg}"
	exit 1
}

failsafe_log()
{
	printf '%s\n' "${1}" > "${MSGS_DEST:-/dev/tty}"
	logger -t adblock-lean "${1}"
	write_log_file_install "${1}" info
}

# shellcheck disable=SC2120
# get config format from adblock-lean config or service script
get_cfg_format_install()
{
	${SED_CMD:?} -En '/^[ \t]*(CONFIG_FORMAT|#[ \t]*config_format)=v/{s/.*=v//;p;:1 n;b1;}' "${1:?}" |
	grep '^[0-9][0-9]*$' && return 0

	log_msg_install -warn "" "Failed to determine fromat version of config file '${1}'."
	printf '0\n'
	return 1
}

# Get GitHub ref and tarball url for specified component, update channel, branch and version
# 1 - update channel: release|snapshot|branch=<github_branch>|commit=<commit_hash>
# 2 - version (optional): [version|commit_hash]
# Output via variables:
#   $3 - github ref (version/commit hash), $4 - tarball url, $5 - version type ('version' or 'commit')
get_gh_ref_install()
{
	set_res_vars()
	{
		# validate resulting ref
		case "${gr_ref}" in
			*[^"${_NL_}"]*"${_NL_}"*[^"${_NL_}"]*)
				reg_failure_install "Got multiple download URLs for version '${gr_version}'." \
					"If using commit hash, please specify the complete commit hash string."
				return 1 ;;
			''|*[!a-zA-Z0-9._-]*)
				reg_failure_install "Failed to get GitHub download URL for ${gr_ver_type} '${gr_version}' (update channel: '${gr_channel}')."
				return 1
		esac

		case "${gr_channel}" in
			release|latest) gr_channel=release gr_version="${gr_ref#v}" ;;
			*) gr_version="${gr_ref}"
		esac

		export -n "${3}=${gr_version}" "${4}=${ABL_GH_URL_API}/tarball/${gr_ref}" "${5}=${gr_ver_type}" \
			"PREV_REF=${gr_ref}" "PREV_VER_TYPE=${gr_ver_type}" \
			"PREV_UPD_CHANNEL=${gr_channel}" "PREV_VERSION=${gr_version}"
	}

	get_and_process_ref()
	{
		local branch url \
			channel="${1}" ptrn="${2}" branches="${3}" err_file="${4}"
		case "${channel}" in
			release)
				uclient-fetch "${ABL_GH_URL_API}/releases" -O- 2> "${err_file}" | {
					jsonfilter -e '@[@.prerelease=false]' |
					jsonfilter -a -e "@[@.target_commitish=\"${ABL_MAIN_BRANCH}\"].tag_name"
					cat 1>/dev/null
				} ;;
			snapshot|branch=*|commit=*)
				for branch in ${branches}
				do
					url="${ABL_GH_URL_API}/commits?sha=${branch}"
					uclient-fetch "${url}" -O- 2> "${err_file}" | {
						jsonfilter -e '@[@.commit]["url"]' |
						${SED_CMD} 's/.*\///' # only leave the commit hash
						cat 1>/dev/null
					}
				done
		esac |
		if [ -n "${ptrn}" ]
		then
			grep "${ptrn}"
		else
			head -n1 # get latest version or commit
			cat 1>/dev/null
		fi
	}

	local gr_branches='' gr_grep_ptrn='' gr_ref='' gr_ver_type='' gr_fetch_rv=0 \
		gr_fetch_tmp_dir="${ABL_INST_DIR}/ref_fetch" \
		cached_ref cached_ver_type \
		gr_channel="${1}" gr_version="${2}"

	[ "$gr_channel" = release ] && gr_version="${gr_version#v}"

	local gr_ucl_err_file="${gr_fetch_tmp_dir}/ucl_err"

	are_var_names_safe_install "${3}" "${4}" "${5}" || return 1
	export -n "${3}=" "${4}=" "${5}="

	# if commit hash is specified and it's 40-char long, use it directly without API query or cache check
	case "${gr_channel}" in
		snapshot|branch=*|commit=*) [ "${#gr_version}" = 40 ] && gr_ref="${gr_version}"
	esac

	# if previously stored data exists, use it without API query or cache check
	if [ -z "${gr_ref}" ] && [ -n "${PREV_REF}" ] && [ -n "${PREV_VER_TYPE}" ] && \
		[ "${PREV_UPD_CHANNEL}" = "${gr_channel}" ] && [ "${gr_version}" = "${PREV_VERSION}" ]
	then
		gr_ref="${PREV_REF}" gr_ver_type="${PREV_VER_TYPE}"
	elif [ -z "${gr_ref}" ]
	then
		# ref cache
		local cache_ttl cache_file cache_filename="${gr_version}_${gr_channel}" gr_cache_dir="/tmp/abl_cache"
		case "${gr_channel}" in
			commit=*) cache_ttl=2880 ;; # 48 hours
			*) cache_ttl=10 # 10 minutes
		esac

		# clean up old cache
		find "${gr_cache_dir:-?}" -maxdepth 1 -type f -mmin +"${cache_ttl}" -exec rm -f {} \; 2>/dev/null

		# check if the query is cached
		cache_file="$(find "${gr_cache_dir:-?}" -maxdepth 1 -type f -name "${cache_filename}" -print 2>/dev/null)"
		case "${cache_file}" in
			'') ;; # found nothing
			*[^"${_NL_}"]*"${_NL_}"*[^"${_NL_}"]*)
				# found multiple files - delete them
				local file IFS="${_NL_}"
				for file in ${cache_file}
				do
					[ -n "${file}" ] || continue
					rm -f "${file}"
				done
				IFS="${DEFAULT_IFS}" ;;
			*)
				# found cached query
				if [ -z "${IGNORE_CACHE}" ] && [ -f "${cache_file}" ] &&
					read -r cached_ref cached_ver_type < "${cache_file}" &&
					[ -n "${cached_ref}" ] && [ -n "${cached_ver_type}" ]
				then
					gr_ref="${cached_ref}" gr_ver_type="${cached_ver_type}"
				else
					rm -f "${cache_file:-???}"
				fi
		esac
	fi

	if [ -n "${gr_ref}" ]
	then
		set_res_vars "${@}" || return 1
		return 0
	fi

	try_mkdir_install -p "${gr_fetch_tmp_dir}" || return 1
	rm -f "${gr_ucl_err_file}"

	case "${gr_channel}" in
		release)
			gr_ver_type=version
			[ -n "${gr_version}" ] && gr_grep_ptrn="^v${gr_version#v}$" ;;
		snapshot)
			gr_ver_type=commit
			gr_branches="${ABL_MAIN_BRANCH}"
			[ -n "${gr_version}" ] && gr_grep_ptrn="^${gr_version}$" ;;
		branch=*)
			gr_ver_type=commit
			gr_branches="${gr_channel#*=}"
			[ -n "${gr_version}" ] && gr_grep_ptrn="^${gr_version}$" ;;
		commit=*)
			gr_ver_type=commit
			local gr_hash="${gr_channel#*=}"

			if [ "${#gr_hash}" = 40 ]
			then
				# if upd. ch. is 'commit', the upd. ch. string includes commit hash -
				#    if it's 40-char long, use it directly without API query
				gr_ref="${gr_hash}"
			else
				gr_branches="$(
					uclient-fetch "${ABL_GH_URL_API}/branches" -O-  2> "${gr_ucl_err_file}" |
						{ jsonfilter -e '@[@]["name"]'; cat 1>/dev/null; }
				)"
				[ -n "${gr_branches}" ] || {
					reg_failure_install "Failed to get adblock-lean branches via GH API (url: '${ABL_GH_URL_API}/branches')."
					[ -f "${gr_ucl_err_file}" ] &&
						log_msg_install "uclient-fetch log:${_NL_}$(cat "${gr_ucl_err_file}")"
						rm -f "${gr_ucl_err_file}"
					return 1
				}
				rm -f "${gr_ucl_err_file}"
				gr_grep_ptrn="^${gr_hash}"
			fi ;;
		*)
			reg_failure_install "Invalid update channel '${gr_channel}'."
			return 1
	esac

	# Get GH ref
	[ -z "${gr_ref}" ] &&
		gr_ref="$(get_and_process_ref "${gr_channel}" "${gr_grep_ptrn}" "${gr_branches}" "${gr_ucl_err_file}")"

	if [ -z "${gr_ref}" ]
	then
		gr_fetch_rv=1
		reg_failure_install "Failed to get GitHub download URL for ${gr_ver_type} '${gr_version}' (update channel: '${gr_channel}')."
		[ -f "${gr_ucl_err_file}" ] && log_msg_install "uclient-fetch output:${_NL_}$(cat "${gr_ucl_err_file}")"
	fi
	rm -rf "${gr_fetch_tmp_dir:-?}"
	[ "$gr_fetch_rv" = 0 ] || return 1

	# write query result to cache
	try_mkdir_install -p "${gr_cache_dir}" &&
	printf '%s\n' "${gr_ref} ${gr_ver_type}" > "${gr_cache_dir}/${cache_filename}"

	set_res_vars "${@}" || return 1
	:
}

# Fetches and unpacks adblock-lean distribution
# 1 - tarball url
# 2 - distribution directory
fetch_abl_dist_install()
{
	[ -n "${1}" ] && [ -n "${2}" ] || { reg_failure_install "fetch_abl_dist_install: missing arguments."; return 1; }

	local tarball_url_fetch="${1}" dist_dir_fetch="${2}"

	local fetch_rv extract_dir fetch_dir="${dist_dir_fetch}/fetch"
	local tarball="${fetch_dir}/remote_abl.tar.gz" ucl_err_file="${fetch_dir}/ucl_err"

	rm -f "${ucl_err_file}" "${tarball}"
	rm -rf "${fetch_dir}/${ABL_REPO_AUTHOR}-adblock-lean-"*
	try_mkdir_install -p "${fetch_dir}" || return 1

	uclient-fetch "${tarball_url_fetch}" -O "${tarball}" 2> "${ucl_err_file}" &&
	grep -q "Download completed" "${ucl_err_file}" &&
	tar -C "${fetch_dir}" -xzf "${tarball}" &&
	extract_dir="$(find "${fetch_dir}/" -type d -name "${ABL_REPO_AUTHOR}-adblock-lean-*")" &&
		[ -n "${extract_dir}" ] && [ "${extract_dir}" != "/" ]
	fetch_rv=${?}
	rm -f "${tarball}"

	[ "${fetch_rv}" != 0 ] && [ -s "${ucl_err_file}" ] &&
		log_msg_install "uclient-fetch output: ${_NL_}$(cat "${ucl_err_file}")."
	rm -f "${ucl_err_file}"

	[ "${fetch_rv}" = 0 ] && {
		mv "${extract_dir:-?}"/* "${dist_dir_fetch:-?}/" ||
			{ rm -rf "${extract_dir:-?}"; reg_failure_install "Failed to move files to dist dir."; return 1; }
	}
	rm -rf "${extract_dir:-?}" "${fetch_dir:-?}"

	return ${fetch_rv}
}

# Looks for blockset-*.conf files and populates var ${1}
find_set_configs_install()
{
	# shellcheck disable=SC2329
	add_cfg_file()
	{
		local cfg_id
		split_path_install _ cfg_id _  "${1}"
		cfg_id="${cfg_id#"blockset-"}"
		case "${cfg_id}" in ''|*[!a-zA-Z0-9_]*)
			reg_failure_install "Invalid blockset name '${cfg_id}' in file '${1}'. Only English letters, numbers and underlines are allowed. Ignoring the file."
			return 0
		esac

		add2list_install "${2}" "${1}" "${_NL_}"
	}

	unset_vars_install "${1}" || return 1

	FF_EXEC="add_cfg_file {} ${1}" \
		find_files_install _ "${ABL_CFG_DIR:?}" "blockset-" "*" ".conf"

	case ${?} in
		0|2) ;;
		*) return 1
	esac

	:
}

clean_env_install()
{
	# blockset-specific context cleanup should not be needed but should stay as a bit of defensive code
	local set_id
	[ -n "${BL_PARAMS_MAP}" ] && check_func_install unset_param_vars && unset_param_vars "${SET_IDS}"
	for set_id in ${SET_IDS}
	do
		unset "BL_ENV_SET_${set_id}"
	done
	unset action ABL_INIT_ACT ABL_CMD CUR_CMD CUR_ACT ABL_LIB_FILES ABL_EXTRA_FILES ABL_EXEC_FILES LIBS_SOURCED CONFIG_FORMAT CONFIG_LOADED BL_PARAMS_MAP VAR2CFG_MAP SET_IDS GLOBAL_ENV_SET SKIP_SET_ENV MAIN_UTILS_DETECTED
	unset -f abl_post_update_1 abl_post_update_2 load_config update source_libs check_libs install_abl_files cleanup_and_exit
}

# Prints file list from adblock-lean service file
# 1 - file path
# 2 - file types (EXEC|ALL)
get_file_list_install()
{
	clean_env_install
	local _file_types="${2}"
	# shellcheck source=/dev/null
	[ -f "${1}" ] && . "${1}" || return 1
	if check_func_install print_file_list # v0.7.2 and later
	then
		print_file_list "${_file_types}"
	elif check_func_install install_abl_files # v0.6.0-v0.7.1
	then
		case "${_file_types}" in
			EXEC) printf '%s\n' "${ABL_SERVICE_PATH:?}" ;;
			*)
				printf '%s\n' "${ABL_SERVICE_PATH}${_NL_}${ABL_LIB_FILES}${_NL_}${ABL_EXTRA_FILES}" |
					${SED_CMD:?} 's/\s\s*/\n/g' | ${SED_CMD} '/^$/d'
		esac
	else # v0.5.4 and earlier
		printf '%s\n' "${ABL_SERVICE_PATH}"
	fi
	:
}

rm_incompat_config()
{
	local IFS="${DEFAULT_IFS}" cfg_fname incompat_cfg_bk cfg_path \
		rm_cfg_paths="${1}"
	[ -n "${rm_cfg_paths}" ] || return 0

	IFS="${_NL_}"
	for cfg_path in ${rm_cfg_paths}
	do
		[ -n "${cfg_path}" ] || continue
		IFS="${DEFAULT_IFS}"
		log_msg_install "" "Warning: removing incompatible config file '${cfg_path}'."
		split_path_install _ cfg_fname _  "${cfg_path}"

		[ -n "${cfg_fname}" ] || { rm -f "${cfg_path}"; continue; }

		incompat_cfg_bk="/tmp/adblock-lean_config_${cfg_fname}.old"

		mv -f "${cfg_path}" "${incompat_cfg_bk}" &&
		{
			log_msg_install "Old config file was saved as ${incompat_cfg_bk}" ""
			continue
		}

		reg_failure_install "Failed to save old config file as ${incompat_cfg_bk}."
		rm -f "${cfg_path}"
	done
	IFS="${DEFAULT_IFS}"
}

get_cur_main_cfg_path()
{
	local _cfg_path
	export -n "${1}="
	{
		[ -s "${GLOBAL_CFG_FILE}" ] &&
		_cfg_path="${GLOBAL_CFG_FILE}"
	} ||
	{
		[ -s "${LEGACY_CFG_FILE}" ] &&
		_cfg_path="${LEGACY_CFG_FILE}"
	}
	export -n "${1}=${_cfg_path}"
}

# 1 - path to distribution dir
# 2 - version
# 3 - update channel
# 4 - force file list
install_abl_files()
{
	local IFS="${DEFAULT_IFS:?}" \
		file preinst_path old_files='' exec_files='' \
		preinst_reg_file="${dist_dir}/preinst_reg.md5" \
		cfg_fname \
		cfg_files_to_rm \
		cur_main_cfg_path \
		cur_cfg_format='' upd_cfg_format='' \
		cur_blockset_cfg_files \
		dist_dir="${1}" version="${2}" upd_channel="${3}" new_file_list="${4}"

	[ -n "${1}" ] && [ -n "${2}" ] && [ -n "${3}" ] || inst_failed "install_abl_files: Missing arguments."



	[ -f "${dist_dir}/adblock-lean" ] || inst_failed "Can not find ${dist_dir}/adblock-lean"

	log_msg_install "" "Installing new files..."


	upd_cfg_format="$(get_cfg_format_install "${dist_dir}/adblock-lean")" || inst_failed
	get_cur_main_cfg_path cur_main_cfg_path

	### Check for incompatible, broken or too old config on upgrade
	if \
		[ -n "${cur_main_cfg_path}" ] &&
		{
			! cur_cfg_format="$(get_cfg_format_install "${cur_main_cfg_path}")" ||
			{ [ "${cur_cfg_format}" -lt 9 ] && [ "${cur_cfg_format}" != "${upd_cfg_format}" ]; }
		}
	then
		add2list_install cfg_files_to_rm "${cur_main_cfg_path}" "${_NL_}"
		cur_main_cfg_path=
		cur_cfg_format=
	fi

	# Normalize path
	try_mkdir_install -p "${dist_dir}${ABL_SERVICE_PATH%/*}"
	mv "${dist_dir}/adblock-lean" "${dist_dir}${ABL_SERVICE_PATH}" || inst_failed

	# get new file list
	if [ -z "${new_file_list}" ]
	then
		new_file_list="$(get_file_list_install "${dist_dir}${ABL_SERVICE_PATH}" ALL)" &&
		[ -n "${new_file_list}" ] ||
			inst_failed "Failed to get the file list from fetched adblock-lean version."
	fi

	printf '%s\n' "${new_file_list}" > "${dist_dir}/new_file_list"

	# check new files
	for file in ${new_file_list}
	do
		[ -z "${file}" ] || [ -f "${dist_dir}${file}" ] && continue
		inst_failed "Missing file: '${dist_dir}${file}'."
	done

	# get new exec file list
	exec_files="$(get_file_list_install "${dist_dir}${ABL_SERVICE_PATH}" EXEC)"

	# handle update
	if [ -n "${ABL_IS_UPDATE}" ]
	then
		# get currently installed file list
		old_files="$(get_file_list_install "${ABL_SERVICE_PATH}" ALL)"

		# delete obsolete files
		local IFS="${_NL_}"
		for file in ${old_files}
		do
			case "${file}" in /*) ;; *) continue; esac # only accept absolute paths
			if [ -f "${file}" ] && ! is_included_install "${file}" "${new_file_list}" "${_NL_}"
			then
				log_msg_install "Deleting obsolete file ${file}."
				rm -f "${file}"
			fi
		done
		IFS="${DEFAULT_IFS}"

		[ -n "${cur_main_cfg_path}" ] &&
		(
			clean_env_install
			# shellcheck source=/dev/null
			. "${dist_dir}${ABL_SERVICE_PATH}" &&
			check_func_install abl_post_update_1 &&
				abl_post_update_1
		)
	fi

	# version and update channel string replacement
	${SED_CMD:?} -i "
		/^\s*ABL_VERSION\s*=/{s/.*/ABL_VERSION=\"${version}\"/;}
		/^\s*ABL_UPD_CHANNEL\s*=/{s/.*/ABL_UPD_CHANNEL=\"${upd_channel}\"/;}" \
			"${dist_dir}${ABL_SERVICE_PATH}"

	# Check for changed files
	local changed_files='' unchanged_files='' man_changed_files=''

	if [ -s "${ABL_FILES_REG_PATH}" ]
	then
		# prefix file paths in the reg file for md5sum comparison
		${SED_CMD} -E "/^$/d;s~([^ 	]+$)~${dist_dir}\\1~" "${ABL_FILES_REG_PATH}" > "${preinst_reg_file}"

		# Detect unchanged files
		md5sum -c "${preinst_reg_file}" 2>/dev/null |
			${SED_CMD} -n "/:\s*OK\s*$/{s/\s*:\s*OK\s*$//;s~^\s*${dist_dir}~~;p;}" > "${dist_dir}/unchanged"
		rm -f "${preinst_reg_file}"

		# Detect manually modified files
		man_changed_files="$(md5sum -c "${ABL_FILES_REG_PATH}" 2>/dev/null |
			${SED_CMD} -n "/:\s*FAILED\s*$/{s/\s*:\s*FAILED\s*$//;p;}")"

		# Remove manually modified files from unchanged files
		if [ -n "${man_changed_files}" ]
		then
			unchanged_files="$(
				printf '%s\n' "${man_changed_files}" | busybox awk '
					NR==FNR {man_ch[$0];next}
					{
						if ($0=="" || $0 in man_ch) {next}
						print $0
					}
				' - "${dist_dir}/unchanged"
			)"
		else
			unchanged_files="$(cat "${dist_dir}/unchanged")"
		fi
		rm -f "${dist_dir}/unchanged"

		# remove unchanged files from ${new_file_list} to reliably get a list of files to copy
		changed_files="$(
			printf '%s\n' "${unchanged_files}" | busybox awk '
				NR==FNR {unch[$0];next}
				{
					if ($0=="" || $0 in unch) {next}
					print $0
				}
			' - "${dist_dir}/new_file_list"
		)"
	else
		changed_files="${new_file_list}"
	fi

	local IFS="${_NL_}"
	for file in ${unchanged_files}
	do
		[ -n "${file}" ] || continue
		log_msg_install "File '${file}' did not change - not updating."
	done

	local mod_files_bk_dir="/tmp/abl_old_modified_files"
	for file in ${man_changed_files}
	do
		[ -n "${file}" ] && [ -f "${file}" ] || continue
		log_msg_install "Warning: File '${file}' was manually modified - overwriting."
		if try_mkdir_install -p "${mod_files_bk_dir}" && cp "${file}" "${mod_files_bk_dir}/${file##*/}"
		then
			log_msg_install "Saved a backup copy of manually modified file to ${mod_files_bk_dir}/${file##*/}"
		else
			log_msg_install "Warning: Can not create a backup copy of manually modified file '${file}' - overwriting anyway."
		fi
	done

	# Copy changed files
	for file in ${changed_files}
	do
		preinst_path="${dist_dir}${file}"
		log_msg_install "Copying file '${file}'."
		try_mkdir_install -p "${file%/*}" && cp "${preinst_path}" "${file}" ||
			inst_failed "Failed to copy file '${preinst_path}' to '${file}'."
	done

	# make files executable
	[ -n "${exec_files}" ] && {
		set -- ${exec_files} # relying on IFS=\n
		for file in "${@}"
		do
			[ -n "${file}" ] || continue
			chmod +x "${file}" || inst_failed "Failed to make file '$file' executable."
		done
	}

	# save the md5sum registry file if needed
	if [ -n "${changed_files}" ] || [ ! -s "${ABL_FILES_REG_PATH}" ]
	then
		# make md5sum registry of new files
		# relying on IFS=\n
		# shellcheck disable=SC2046
		set -- $(
			printf '%s\n' "${new_file_list}" |
			busybox sed "/^$/d;s~^\s*~${dist_dir}~"
		) &&
		md5sums="$(md5sum "$@")" && [ -n "${md5sums}" ] &&
		try_mkdir_install -p "${ABL_FILES_REG_PATH%/*}" &&
		printf '%s\n' "${md5sums}" |
			busybox sed "s~\s${dist_dir}~ ~" > "${ABL_FILES_REG_PATH}" ||
				inst_failed "Failed to register new files."
	fi
	IFS="${DEFAULT_IFS}"


	rm_incompat_config "${cfg_files_to_rm}"

	# Migrate old (unified) config file (config format < v12) to split config
	find_set_configs_install cur_blockset_cfg_files
	[ -f "${LEGACY_CFG_FILE:?}" ] && [ -s "${GLOBAL_CFG_FILE:?}" ] && [ -n "${cur_blockset_cfg_files}" ] &&
	{
		local legacy_mv_path=${ABL_CFG_DIR}/legacy-config.bak
		reg_msg_install -warn "Found both split-config files (global.conf, blockset-*.conf) and legacy unified config file ('config')."
		reg_msg_install "Moving the legacy config file to ${legacy_mv_path}"
		mv -f "${LEGACY_CFG_FILE}" "${legacy_mv_path}" || rm -f "${LEGACY_CFG_FILE}"
	}

	local IFS="${_NL_}" migr_req
	for cfg_file in ${cur_main_cfg_path}${_NL_}${cur_blockset_cfg_files}
	do
		[ -n "${cfg_file}" ] && [ -s "${cfg_file}" ] || continue
		IFS="${DEFAULT_IFS}"

		cur_cfg_format="$(get_cfg_format_install "${cfg_file}")" &&
		is_uint_install "${cur_cfg_format}" ||
		{
			migr_req=1
			log_msg_install "" "Fromat version of config file '${cfg_file}' is unknown."
			continue
		}

		[ "${cur_cfg_format}" -lt "${upd_cfg_format}" ] &&
		{
			migr_req=1
			log_msg_install "" "Config file '${cfg_file}' has older config format (v${cur_cfg_format}) than current (v${upd_cfg_format})."
			continue
		}

		[ "${cur_cfg_format}" -gt "${upd_cfg_format}" ] &&
		{
			log_msg_install -warn "" "Existing config file '${cfg_file}' has newer config version (v${cur_cfg_format}) than config version in fetched adblock-lean (v${upd_cfg_format})."
			continue
		}
	done
	IFS="${DEFAULT_IFS}"

	if [ -n "${migr_req}" ]
	then
		log_msg_install -purple "Migrating previous adblock-lean config."
		(
			# Newline-separated list of options to migrate in the format <old_key=new_key>
			migrate_opts_global='
				list_part_failed_action=blockset_part_failed_action
				cron_schedule=upd_schedule
				unload_blocklist_before_update=unload_blockset_before_update
				min_blocklist_part_line_count=min_block_part_entries
				min_blocklist_ipv4_part_line_count=min_ipv4_block_part_entries
				min_ipv4_blocklist_part_line_count=min_ipv4_block_part_entries
				min_allowlist_part_line_count=min_allow_part_entries
				max_file_part_size_KB=max_part_size_KB
			'

			migrate_opts_blockset='
				DNSMASQ_INDEX=dnsmasq_indexes
				DNSMASQ_INDEXES=dnsmasq_indexes
				DNSMASQ_CONF_D=dnsmasq_conf_dirs
				DNSMASQ_CONF_DIRS=dnsmasq_conf_dirs
				blocklist_urls=raw_block_lists
				allowlist_urls=raw_allow_lists
				blocklist_ipv4_urls=raw_ipv4_block_lists
				dnsmasq_blocklist_urls=dnsmasq_block_lists
				dnsmasq_blocklist_ipv4_urls=dnsmasq_ipv4_block_lists
				dnsmasq_allowlist_urls=dnsmasq_allow_lists
				min_good_line_count=min_good_entries
				max_blocklist_file_size_KB=max_blockset_file_size_KB
			'

			# convert into _DELIM_ separated lists
			for cfg_type in global blockset
			do
				IFS="${DEFAULT_IFS:?}"
				eval "set -- \${migrate_opts_${cfg_type}}"
				IFS="${_DELIM_:?}"
				export -n "migrate_opts_${cfg_type}=${*}"
			done
			IFS="${DEFAULT_IFS}"

			clean_env_install
			migr_fail=

			# shellcheck source=/dev/null
			. "${dist_dir}${ABL_SERVICE_PATH}" &&
			check_func_install source_libs &&
			ABL_SOURCE_PATH_PREFIX="${dist_dir}" source_libs &&
			check_func_install parse_config &&
			check_func_install print_def_cfg &&
			check_func_install try_mkdir_install &&
			cfg_staging_dir="/tmp/abl-conf-staging" &&
			try_mkdir_install -p "${cfg_staging_dir}" || migr_fail=1

			[ -z "${migr_fail}" ] &&
			for cfg_type in global bl
			do
				prev_cfg_files=
				case "${cfg_type}" in
					global)
						migrate_opts="${migrate_opts_global}"
						if [ -s "${GLOBAL_CFG_FILE}" ]
						then
							prev_cfg_files="${GLOBAL_CFG_FILE}"
						elif [ -s "${LEGACY_CFG_FILE}" ]
						then
							prev_cfg_files="${LEGACY_CFG_FILE}"
						fi
						;;
					bl)
						prev_cfg_files=${cur_blockset_cfg_files}
						migrate_opts="${migrate_opts_blockset}"
						[ -z "${prev_cfg_files}" ] && [ -s "${LEGACY_CFG_FILE}" ] &&
							prev_cfg_files="${LEGACY_CFG_FILE}"
						;;
				esac
				[ -n "${prev_cfg_files}" ] || continue

				IFS="${_NL_}"
				for cfg_file in ${prev_cfg_files}
				do
					IFS="${DEFAULT_IFS}"
					cfg_id_orig=
					get_cfg_id_install cfg_id_orig "${cfg_file}" || { migr_fail=1; break; }
					cfg_id="${cfg_id_orig}"

					# Handle old (unified) config
					[ "${cfg_id}" = "config" ] &&
					{
						case "${cfg_type}" in
							global) cfg_id=global ;;
							bl) cfg_id=01 # Migrate to blockset config with ID '01'
						esac
					}

					case "${cfg_type}" in
						global)
							new_cfg_path="${GLOBAL_CFG_FILE}"
							var_suffix=
							bk_f_prefix='' ;;
						bl)
							var_suffix="_${cfg_id}"
							new_cfg_path="${ABL_CFG_DIR}/blockset-${cfg_id}.conf"
							bk_f_prefix="blockset-"
					esac

					bk_cfg_f="/tmp/adblock-lean_config_${bk_f_prefix}${cfg_id}.bk"
					[ "${cfg_id_orig}" != "config" ] && # unified config is backed up later
						if cp "${cfg_file}" "${bk_cfg_f}"
						then
							reg_msg_install "Old config file was saved as ${bk_cfg_f}"
						else
							reg_failure_install "Failed to save old config file as ${bk_cfg_f}"
						fi

					ACCEPT_UNKNOWN_SET_IDS=1 \
					CFG_IGNORE_NONCRIT=1 \
					CFG_MIGRATE_OPTS="${migrate_opts}" \
						parse_config "${cfg_type}" "${cfg_id}" "${cfg_file}" &&

					fixed_cfg="$(
						ACCEPT_UNKNOWN_SET_IDS=1 print_def_cfg "${cfg_type}" -i "${cfg_id}" |
						while IFS="${_NL_}" read -r def_line
						do
							curr_val=
							case "${def_line}" in
								\#*|'') printf '%s\n' "${def_line}"; continue ;;
								*=*)
									key=${def_line%%=*}
									eval "[ -n \"\${${key}${var_suffix}+x}\" ]" || continue # ignore keys corresponding to unset variables
									eval "curr_val=\"\${${key}${var_suffix}}\""
									printf '%s\n' "${key}=\"${curr_val}\""
									continue
							esac
						done
					)" &&
					printf '%s\n' "${fixed_cfg}" > "${new_cfg_path}" &&
					continue

					migr_fail=1
					break 2
				done
				IFS="${DEFAULT_IFS}"
			done
			IFS="${DEFAULT_IFS}"

			rm -rf "${cfg_staging_dir}"
			[ -z "${migr_fail}" ] &&
			{
				bk_cfg_f="/tmp/adblock-lean_config.old"
				[ -s "${LEGACY_CFG_FILE}" ] &&
					if cp "${LEGACY_CFG_FILE}" "${bk_cfg_f}"
					then
						reg_msg_install "" "Old config file was saved as ${bk_cfg_f}"
					else
						reg_failure_install "Failed to save old config file as ${bk_cfg_f}."
					fi

				rm -f "${LEGACY_CFG_FILE}"
				log_msg_install -green "Successfully migrated config."
				exit 0
			}

			reg_failure_install "Failed to migrate config."
			[ -s "${LEGACY_CFG_FILE}" ] &&
				log_msg_install -yellow "Please rename or delete the config file '${LEGACY_CFG_FILE}' and use the command 'service adblock-lean setup' to create new config."
		)
	fi

	[ -n "${cur_main_cfg_path}" ] &&
	grep -m1 -q '[ 	]*abl_post_update_2()' "${dist_dir}${ABL_SERVICE_PATH}" &&
	(
		clean_env_install
		# shellcheck source=/dev/null
		. "${dist_dir}${ABL_SERVICE_PATH}" &&
		check_func_install abl_post_update_2 &&
		abl_post_update_2
	)

	:
}

fetch_and_install()
{
	# unset vars and functions from current version to have a clean slate with the new version
	fetch_failed()
	{
		local fail_msg="${1}"
		[ -s "${UCL_ERR_FILE:?}" ] && fail_msg="${fail_msg} uclient-fetch errors: '$(cat "${UCL_ERR_FILE}")'"
		[ -n "${fail_msg}" ] && reg_failure_install "${fail_msg}"
		rm -rf "${ABL_PID_DIR:?}"
		inst_failed
	}

	unexp_arg() { fetch_failed "fetch_and_install: unexpected argument '${1}'."; }


	trap 'cleanup_and_exit_install 1' INT TERM
	trap 'cleanup_and_exit_install ${?}' EXIT

	set -o pipefail

	local util

	for util in tar find uclient-fetch
	do
		check_util_install "${util}" || inst_failed "Utility '${util}' not found."
	done

	local file req_ver='' ver_str_arg='' ver_type='' dist_dir='' upd_ver='' tarball_url='' \
		upd_channel='' req_upd_channel='' force_upd_channel=''

	IGNORE_CACHE=
	while getopts ":s:v:U:W:i" opt
	do
		case ${opt} in
			s) export sim_path="$OPTARG" ;;
			v) ver_str_arg=$OPTARG ;;
			U) force_upd_channel=$OPTARG ;;
			W) req_ver=$OPTARG ;;
			i) IGNORE_CACHE=1 ;; # global var
			*) unexp_arg "$OPTARG"
		esac
	done
	shift $((OPTIND-1))
	[ -z "${*}" ] || unexp_arg "${*}"

	# parse version string from arguments into $req_upd_channel, $req_ver
	case "${ver_str_arg}" in
		'') ;;
		release|latest)
			req_upd_channel=release req_ver='' ;;
		snapshot)
			req_upd_channel="${ver_str_arg}" req_ver='' ;;
		commit=*)
			req_upd_channel="${ver_str_arg}" req_ver="${ver_str_arg#*=}" ;;
		branch=*)
			req_upd_channel="${ver_str_arg}" req_ver='' ;;
		[0-9]*|v[0-9]*)
			req_upd_channel=release
			req_ver="${ver_str_arg#*=}"
			req_ver="${req_ver#v}"
			;;
		*) fetch_failed "Invalid version string '${ver_str_arg}'."
	esac

	if ${ABL_SERVICE_PATH} enabled 2>/dev/null
	then
		ABL_IN_INSTALL='' DO_DIALOGS=0 ${ABL_SERVICE_PATH} stop
	fi

	rm -rf "${ABL_INST_DIR:-???}"
	try_mkdir_install -p "${ABL_INST_DIR}" || fetch_failed

	upd_channel="${req_upd_channel:-"${ABL_UPD_CHANNEL}"}"
	upd_channel="${force_upd_channel:-"${upd_channel}"}"
	upd_channel="${upd_channel:-"release"}"

	dist_dir="${ABL_INST_DIR}/dist"
	try_mkdir_install -p "${dist_dir}" || fetch_failed

	if [ -n "${sim_path}" ]
	then
		print_msg_install "Installing in simulation mode."
		[ -d "${sim_path}" ] || fetch_failed "Update simulation directory '${sim_path}' does not exist."
		[ -n "${ver_str_arg}" ] || fetch_failed "Specify new version string."
		upd_ver="${ver_str_arg}"

		[ -d "${sim_path}" ] || fetch_failed "Simulation source directory doesn't exist."
		cp -rT "${sim_path}" "${dist_dir}"
		log_msg_install -purple "" "Installing adblock-lean version ${blue}${upd_ver}${n_c} (update channel: ${blue}${upd_channel}${n_c})."
	else
		get_gh_ref_install "${upd_channel}" "${req_ver}" upd_ver tarball_url ver_type || fetch_failed
		case "${upd_channel}" in
			commit=*)
				# set update channel to 'commit=<full_commit_hash>'
				upd_channel="${upd_channel%=*}=${upd_ver}"
		esac
		log_msg_install "" "Downloading adblock-lean, ${ver_type} '${upd_ver}' (update channel: '${upd_channel}')."
		fetch_abl_dist_install "${tarball_url}" "${dist_dir}" || fetch_failed
	fi


	[ -f "${dist_dir}/adblock-lean" ] || inst_failed "Can not find ${dist_dir}/adblock-lean"

	[ -f "${dist_dir}/abl-install.sh" ] || inst_failed "Can not find file ${dist_dir}/abl-install.sh"
	grep -m1 -q '[ 	]*install_abl_files()' "${dist_dir}/abl-install.sh" ||
		inst_failed "Downloaded adblock-lean install script does not define the function 'install_abl_files' - try a newer adblock-lean version."

	# Refuse to install versions earlier than v0.7.2
	${AWK_CMD:?} \
		'
			BEGIN{v=7;u=7}
			/^[ 	]*ABL_VERSION=/ {v=1; next}
			/^[ 	]*ABL_UPD_CHANNEL=/ {u=1; next}
			END{if (v==1 && u==1) exit 0; exit 1}
		' "${dist_dir}/adblock-lean" ||
	inst_failed "Fetched adblock-lean service script does not specify either ABL_VERSION or ABL_UPD_CHANNEL."


	local cur_cfg_format upd_cfg_format cur_main_cfg_path
	upd_cfg_format="$(get_cfg_format_install "${dist_dir}/adblock-lean")" || inst_failed
	get_cur_main_cfg_path cur_main_cfg_path

	### Remove incompatible newer config on downgrade from pre-0.9 to very old versions
	if \
		[ "${cur_main_cfg_path}" = "${LEGACY_CFG_FILE:?}" ] &&
		cur_cfg_format="$(get_cfg_format_install "${cur_main_cfg_path}")" &&
		[ "${cur_cfg_format}" -ge 9 ] &&
		[ "${upd_cfg_format}" -lt 9 ]
	then
		rm_incompat_config "${cur_main_cfg_path}"
		cur_main_cfg_path=
		cur_cfg_format=
	fi

	[ -n "${cur_cfg_format}" ] && [ "${cur_cfg_format}" -gt "${upd_cfg_format}" ] &&
		log_msg_install -warn "" \
			"Existing config file '${cur_main_cfg_path}' has newer config version (v${cur_cfg_format}) than config version in fetched adblock-lean (v${upd_cfg_format})."

	### Source fetched install script and use its install_abl_files() method for installation
	(
		clean_env_install &&
		INST_SOURCED=1 . "${dist_dir}/abl-install.sh" ||
			{ reg_failure_install "Failed to source fetched install script."; exit 1; }
		install_abl_files "${dist_dir}" "${upd_ver}" "${upd_channel}"
	) || inst_failed

	rm -rf "${ABL_INST_DIR}" "${ABL_PID_DIR:-???}" "${UCL_ERR_FILE:-???}"
	trap - INT TERM EXIT
	log_msg_install "" "adblock-lean (version '${upd_ver}') has been installed."


	local cur_blockset_cfg_files cfg_found=
	get_cur_main_cfg_path cur_main_cfg_path
	find_set_configs_install cur_blockset_cfg_files

	[ "${cur_main_cfg_path}" = "${LEGACY_CFG_FILE}" ] ||
	{ [ "${cur_main_cfg_path}" = "${GLOBAL_CFG_FILE}" ] && [ -n "${cur_blockset_cfg_files}" ]; } &&
		cfg_found=1

	if [ -n "${cfg_found}" ]
	then
		if [ "${DO_DIALOGS}" = 1 ]
		then
			print_msg -blue "" "Start adblock-lean now? (y|n)"
			pick_opt "y|n"
		fi

		[ "${DO_DIALOGS}" = 1 ] && [ "${REPLY}" = y ] || exit 0

		clean_abl_env
		. "${ABL_SERVICE_PATH}" || return 1
		start
		exit ${?}
	elif \
		[ -n "${DO_DIALOGS}" ] &&
		print_msg -blue "" "Set up adblock-lean now? (y|n)" &&
		pick_opt "y|n" &&
		[ "$REPLY" = y ]
	then
		clean_abl_env
		set +o pipefail # for compatibility with older versions
		# shellcheck source=/dev/null
		. "${ABL_SERVICE_PATH}"
		setup
		exit ${?}
	else
		log_msg -yellow "adblock-lean config is not found. Please use the command 'service adblock-lean setup' to set up adblock-lean."
		exit 0
	fi
}


set_ansi_install

# Test process substitution support
printf '%s\n%s\n' "#!/bin/sh" "printf %s >(:)" > /tmp/abl-test
/bin/sh /tmp/abl-test 1>/dev/null 2>/dev/null ||
{
	rm -f /tmp/abl-test
	inst_failed "/bin/sh does not support process substitution. To use adblock-lean, please update OpenWrt to 23.05 or later version."
}
rm -f /tmp/abl-test

dnsmasq --help | grep -qe "--conf-script" ||
	inst_failed "The version of dnsmasq installed on this system is too old. To use adblock-lean, upgrade this system to OpenWrt 23.05 or later."


export ABL_IN_INSTALL=1
[ -s "${ABL_SERVICE_PATH}" ] && export ABL_IS_UPDATE=1

if [ -z "${INST_SOURCED}" ]
then
	fetch_and_install "${@}"
else
	:
fi
