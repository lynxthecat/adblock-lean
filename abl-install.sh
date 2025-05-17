#!/bin/sh
# shellcheck disable=SC3043,SC1090,SC3044

# silence shellcheck warnings
: "${LIBS_SOURCED}"

ABL_INSTALLER_VER=2
ABL_UPD_DIR="/var/run/adblock-lean-update"
ABL_CONFIG_DIR=/etc/adblock-lean
ABL_PID_DIR=/tmp/adblock-lean
ABL_CONFIG_FILE=${ABL_CONFIG_DIR}/config
ABL_SERVICE_PATH=/etc/init.d/adblock-lean
ABL_DIR=/var/run/adblock-lean
ABL_INST_DIR="${ABL_DIR}/remote_abl"
UCL_ERR_FILE="${ABL_DIR}/uclient-fetch_err"
: "${ABL_REPO_AUTHOR:=lynxthecat}"
ABL_GH_URL_API="https://api.github.com/repos/${ABL_REPO_AUTHOR}/adblock-lean"
ABL_MAIN_BRANCH=master
ABL_FILES_REG_PATH=/etc/adblock-lean/abl-reg.md5

# silence shellcheck warnings
: "${ABL_INSTALLER_VER}" "${ABL_CONFIG_FILE}"

LC_ALL=C
DEFAULT_IFS='	 
'
_NL_='
'
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
[ -n "${luci_skip_dialogs}" ] && export ABL_LUCI_SOURCED=1

DO_DIALOGS=
[ -z "${ABL_LUCI_SOURCED}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] && DO_DIALOGS=1

if sed --version 2>/dev/null | grep -qe '(GNU sed)'
then
	SED_CMD="sed"
else
	SED_CMD="busybox sed"
fi


# exit with code ${1}
# if function 'abl_luci_exit' is defined, execute it before exit
cleanup_and_exit()
{
	trap - INT TERM EXIT
	rm -rf "${ABL_DIR}" "${ABL_PID_DIR}"
	[ -n "${ABL_LUCI_SOURCED}" ] && abl_inst_luci_exit "${1}"
	exit "${1}"
}

# check if var names are safe to use with eval
are_var_names_safe() {
	local var_name
	for var_name in "${@}"
	do
		case "${var_name}" in *[!a-zA-Z_]*) reg_failure "Invalid var name '${var_name}'."; return 1; esac
	done
	:
}

check_func()
{
	[ "$(type "${1}" 2>/dev/null | head -n1)" = "${1} is a function" ]
}

check_util()
{
	command -v "${1}" 1>/dev/null
}

# asks the user to pick an option
# 1 - input in the format 'a|b|c'
# output via $REPLY
pick_opt()
{
	while :
	do
		printf %s "${1}: " 1>${MSGS_DEST}
		read -r REPLY
		case "${REPLY}" in *[!A-Za-z0-9_]*) printf '\n%s\n\n' "Please enter ${1}" 1>${MSGS_DEST}; continue; esac
		eval "case \"${REPLY}\" in 
				${1}) return 0 ;;
				*) printf '\n%s\n\n' \"Please enter ${1}\" 1>${MSGS_DEST}
			esac"
	done
}

# checks if string $1 is included in newline-separated list $2
# if $3 is specified, uses the value as list delimiter
# result via return status
is_included() {
	local delim="${3:-"${_NL_}"}"
	case "$2" in
		"$1"|"$1${delim}"*|*"${delim}$1"|*"${delim}$1${delim}"*)
			return 0 ;;
		*)
			return 1
	esac
}

try_mv()
{
	[ -z "${1}" ] || [ -z "${2}" ] && { reg_failure "try_mv(): bad arguments."; return 1; }
	mv -f "${1}" "${2}" || { reg_failure "Failed to move '${1}' to '${2}'."; return 1; }
	:
}

# 0 - (optional) '-p'
# 1 - path
try_mkdir()
{
	local p=
	[ "${1}" = '-p' ] && { p='-p'; shift; }
	[ -d "${1}" ] && return 0
	mkdir ${p} "${1}" || { reg_failure "Failed to create directory '${1}'."; return 1; }
	:
}

# prints each argument into a separate line
print_msg()
{
	local m
	for m in "${@}"
	do
		printf '%s\n' "${m}" > "$MSGS_DEST"
	done
}

log_msg()
{
	local m msgs='' msgs_prefix='' _arg err_l=info

	local IFS="${DEFAULT_IFS}"
	for _arg in "$@"
	do
		case "${_arg}" in
			"-err") err_l=err msgs_prefix="Error: " ;;
			'') msgs="${msgs}dummy${_DELIM_}" ;;
			*) msgs="${msgs}${msgs_prefix}${_arg}${_DELIM_}"; [ -n "${msgs_prefix}" ] && msgs_prefix=
		esac
	done
	msgs="${msgs%"${_DELIM_}"}"
	IFS="${_DELIM_}"

	for m in ${msgs}
	do
		IFS="${DEFAULT_IFS}"
		case "${m}" in
			dummy) echo ;;
			*)
				print_msg "${m}"
				logger -t abl-install -p user."${err_l}" "${m}"
		esac
	done
	:
}

reg_failure()
{
	log_msg -err "" "${1}"
	luci_errors="${luci_errors}${1}${_NL_}"
}

# Get version and update channel of adblock-lean file
# Assigns vars $2 = version, $3 = update channel
# 1 - path to adblock-lean service file
# Return codes:
# 1 - error
# 2 - no version found
# 3 - new version format
# 4 - old version format
get_abl_version()
{
	get_ver_str()
	{
		local key_ptrn='' migr_ptrn=''
		case "${1}" in
			version)
				key_ptrn="\\s*ABL_VERSION"
				[ "${3}" = '-o' ] && migr_ptrn='s/^[^_]*_//;' ;;
			upd_channel)
				key_ptrn="\\s*ABL_UPD_CHANNEL"
				[ "${3}" = '-o' ] && { key_ptrn="\\s*ABL_VERSION" migr_ptrn='s/_.*//;'; }
		esac
		[ "${3}" = '-o' ] && key_ptrn="\\s*#${key_ptrn}"

		${SED_CMD} -n "/^${key_ptrn}=/{s/^${key_ptrn}=//;s/#.*$//;s/\"//g;${migr_ptrn}p;:1 n;b1;}" "${2}"
	}

	local gv_ver='' gv_upd_ch='' gv_rv=''
	if [ -n "${2}${3}" ]
	then
		are_var_names_safe "${2}" "${3}" || return 1
		eval "${2}"='' "${3}"=''
	fi
	# version format in v0.7.2 and later
	if grep -q '^\s*ABL_UPD_CHANNEL=' "${1}" &&
		gv_upd_ch="$(get_ver_str upd_channel "${1}")" &&
		gv_ver="$(get_ver_str version "${1}")" &&
		[ -n "${gv_upd_ch}" ] && [ -n "${gv_ver}" ]
	then
		gv_rv=3
	# version format in v0.6.0 - v0.7.1
	elif grep -q '^\s*#\s*ABL_VERSION=' "${1}" &&	
		gv_upd_ch="$(get_ver_str upd_channel "${1}" -o)" &&
		gv_ver="$(get_ver_str version "${1}" -o)" &&
		[ -n "${gv_upd_ch}" ] && [ -n "${gv_ver}" ]
	then
		gv_rv=4
	else
		gv_rv=2
	fi
	[ -n "${2}${3}" ] && eval "${2}"='${gv_ver}' "${3}"='${gv_upd_ch}'
	return ${gv_rv}
}

inst_failed()
{
	local fail_msg="${1}"
	[ -s "${UCL_ERR_FILE}" ] && fail_msg="${fail_msg} uclient-fetch errors: '$(cat "${UCL_ERR_FILE}")'"
	[ -n "${fail_msg}" ] && reg_failure "${fail_msg}"
	reg_failure "Failed to install adblock-lean."
	rm -rf "${ABL_INST_DIR}" "${UCL_ERR_FILE}"
	exit 1
}

failsafe_log()
{
	printf '%s\n' "${1}" > "${MSGS_DEST:-/dev/tty}"
	logger -t adblock-lean "${1}"
}

# shellcheck disable=SC2120
# get config format from config or main script file contents
# input via STDIN or ${1}
get_config_format()
{
	local conf_form_sed_expr='/^[ \t]*(CONFIG_FORMAT|#[ \t]*config_format)=v/{s/.*=v//;p;:1 n;b1;}'
	if [ -n "${1}" ]
	then
		${SED_CMD} -En "${conf_form_sed_expr}" "${1}"
	else
		${SED_CMD} -En "${conf_form_sed_expr}"
	fi
}

# Get GitHub ref and tarball url for specified component, update channel, branch and version
# 1 - update channel: release|snapshot|branch=<github_branch>|commit=<commit_hash>
# 2 - version (optional): [version|commit_hash]
# Output via variables:
#   $3 - github ref (version/commit hash), $4 - tarball url, $5 - version type ('version' or 'commit')
get_gh_ref()
{
	set_res_vars()
	{
		# validate resulting ref
		case "${gr_ref}" in
			*[^"${_NL_}"]*"${_NL_}"*[^"${_NL_}"]*)
				reg_failure "Got multiple download URLs for version '${gr_version}'." \
					"If using commit hash, please specify the complete commit hash string."
				return 1 ;;
			''|*[!a-zA-Z0-9._-]*)
				reg_failure "Failed to get GitHub download URL for ${gr_ver_type} '${gr_version}' (update channel: '${gr_channel}')."
				return 1
		esac

		case "${gr_channel}" in
			release|latest) gr_channel=release gr_version="${gr_ref#v}" ;;
			*) gr_version="${gr_ref}"
		esac

		eval "${3}"='${gr_version}' "${4}"='${ABL_GH_URL_API}/tarball/${gr_ref}' "${5}"='${gr_ver_type}' \
			"prev_ref"='${gr_ref}' "prev_ver_type"='${gr_ver_type}' \
			"prev_upd_channel"='${gr_channel}' "prev_version"='${gr_version}'
	}

	local gr_branch gr_branches='' gr_grep_ptrn='' gr_ref='' gr_ver_type='' gr_fetch_rv=0 \
		gr_fetch_tmp_dir="${ABL_UPD_DIR}/ref_fetch" \
		prev_ref prev_ver_type prev_upd_channel prev_version \
		gr_channel="${1}" gr_version="${2}"

	[ "$gr_channel" = release ] && gr_version="${gr_version#v}"

	local gr_ucl_err_file="${gr_fetch_tmp_dir}/ucl_err"

	are_var_names_safe "${3}" "${4}" "${5}" || return 1
	eval "${3}='' ${4}='' ${5}=''"

	eval "prev_ref=\"\${prev_ref}\"
		prev_ver_type=\"\${prev_ver_type}\"
		prev_upd_channel=\"\${prev_upd_channel}\"
		prev_version=\"\${prev_version}\""

	# if commit hash is specified and it's 40-char long, use it directly without API query or cache check
	case "${gr_channel}" in
		snapshot|branch=*|commit=*) [ "${#gr_version}" = 40 ] && gr_ref="${gr_version}"
	esac

	# if previously stored data exists, use it without API query or cache check
	if [ -z "${gr_ref}" ] && [ -n "${prev_ref}" ] && [ -n "${prev_ver_type}" ] && \
		[ "${prev_upd_channel}" = "${gr_channel}" ] && [ "${gr_version}" = "${prev_version}" ]
	then
			gr_ref="${prev_ref}" gr_ver_type="${prev_ver_type}"
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
					read -r prev_ref prev_ver_type < "${cache_file}" &&
					[ -n "${prev_ref}" ] && [ -n "${prev_ver_type}" ]
				then
					gr_ref="${prev_ref}" gr_ver_type="${prev_ver_type}"
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

	try_mkdir -p "${gr_fetch_tmp_dir}" || return 1
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
					reg_failure "Failed to get adblock-lean branches via GH API (url: '${ABL_GH_URL_API}/branches')."
					[ -f "${gr_ucl_err_file}" ] &&
						log_msg "uclient-fetch log:${_NL_}$(cat "${gr_ucl_err_file}")"
						rm -f "${gr_ucl_err_file}"
					return 1
				}
				rm -f "${gr_ucl_err_file}"
				gr_grep_ptrn="^${gr_hash}"
			fi ;;
		*)
			reg_failure "Invalid update channel '${gr_channel}'."
			return 1
	esac

	# Get GH ref
	[ -z "${gr_ref}" ] && gr_ref="$(
		case "${gr_channel}" in
			release)
				uclient-fetch "${ABL_GH_URL_API}/releases" -O- 2> "${gr_ucl_err_file}" | {
					jsonfilter -e '@[@.prerelease=false]' |
					jsonfilter -a -e "@[@.target_commitish=\"${ABL_MAIN_BRANCH}\"].tag_name"
					cat 1>/dev/null
				} ;;
			snapshot|branch=*|commit=*)
				for gr_branch in ${gr_branches}
				do
					ref_fetch_url="${ABL_GH_URL_API}/commits?sha=${gr_branch}"
					uclient-fetch "${ref_fetch_url}" -O- 2> "${gr_ucl_err_file}" | {
						jsonfilter -e '@[@.commit]["url"]' |
						${SED_CMD} 's/.*\///' # only leave the commit hash
						cat 1>/dev/null
					}
				done
		esac |
		{
			if [ -n "${gr_grep_ptrn}" ]
			then
				grep "${gr_grep_ptrn}"
			else
				head -n1 # get latest version or commit
			fi
			cat 1>/dev/null
		}
	)"

	if [ -z "${gr_ref}" ]
	then
		gr_fetch_rv=1
		reg_failure "Failed to get GitHub download URL for ${gr_ver_type} '${gr_version}' (update channel: '${gr_channel}')."
		[ -f "${gr_ucl_err_file}" ] && log_msg "uclient-fetch output:${_NL_}$(cat "${gr_ucl_err_file}")"
	fi
	rm -rf "${gr_fetch_tmp_dir:-?}"
	[ "$gr_fetch_rv" = 0 ] || return 1

	# write query result to cache
	try_mkdir -p "${gr_cache_dir}" &&
	printf '%s\n' "${gr_ref} ${gr_ver_type}" > "${gr_cache_dir}/${cache_filename}"

	set_res_vars "${@}" || return 1
	:
}

# Fetches and unpacks adblock-lean distribution
# 1 - tarball url
# 2 - distribution directory
fetch_abl_dist()
{
	[ -n "${1}" ] && [ -n "${2}" ] || { reg_failure "fetch_abl_dist: missing arguments."; return 1; }

	local tarball_url_fetch="${1}" dist_dir_fetch="${2}"

	local fetch_rv extract_dir fetch_dir="${dist_dir_fetch}/fetch"
	local  tarball="${fetch_dir}/remote_abl.tar.gz" ucl_err_file="${fetch_dir}/ucl_err" \


	rm -f "${ucl_err_file}" "${tarball}"
	rm -rf "${fetch_dir}/${ABL_REPO_AUTHOR}-adblock-lean-"*
	try_mkdir -p "${fetch_dir}" || return 1

	uclient-fetch "${tarball_url_fetch}" -O "${tarball}" 2> "${ucl_err_file}" &&
	grep -q "Download completed" "${ucl_err_file}" &&
	tar -C "${fetch_dir}" -xzf "${tarball}" &&
	extract_dir="$(find "${fetch_dir}/" -type d -name "${ABL_REPO_AUTHOR}-adblock-lean-*")" &&
		[ -n "${extract_dir}" ] && [ "${extract_dir}" != "/" ]
	fetch_rv=${?}
	rm -f "${tarball}"

	[ "${fetch_rv}" != 0 ] && [ -s "${ucl_err_file}" ] &&
		log_msg "uclient-fetch output: ${_NL_}$(cat "${ucl_err_file}")."
	rm -f "${ucl_err_file}"

	[ "${fetch_rv}" = 0 ] && {
		mv "${extract_dir:-?}"/* "${dist_dir_fetch:-?}/" ||
			{ rm -rf "${extract_dir:-?}"; reg_failure "Failed to move files to dist dir."; return 1; }
	}
	rm -rf "${extract_dir:-?}" "${fetch_dir:-?}"

	return ${fetch_rv}
}

clean_abl_env()
{
	unset action ABL_CMD ABL_LIB_FILES ABL_EXTRA_FILES ABL_EXEC_FILES LIBS_SOURCED CONFIG_FORMAT
	unset -f abl_post_update_1 abl_post_update_2 load_config update source_libs check_libs install_abl_files cleanup_and_exit
}

# Prints file list from adblock-lean service file
# 1 - file path
# 2 - file types (EXEC|ALL)
get_file_list()
{
	clean_abl_env
	# shellcheck source=/dev/null
	[ -f "${1}" ] && . "${1}" || return 1
	if check_func print_file_list # v0.7.2 and later
	then
		print_file_list "${2}"
	elif check_func install_abl_files # v0.6.0-v0.7.1
	then
		case "${2}" in
			EXEC) printf '%s\n' "${ABL_SERVICE_PATH}" ;;
			*)
				printf '%s\n' "${ABL_SERVICE_PATH}${_NL_}${ABL_LIB_FILES}${_NL_}${ABL_EXTRA_FILES}" |
					${SED_CMD} 's/\s\s*/\n/g' | ${SED_CMD} '/^$/d'
		esac
	else # v0.5.4 and earlier
		printf '%s\n' "${ABL_SERVICE_PATH}"
	fi
	:
}

# 1 - path to distribution dir
# 2 - version
# 3 - update channel
# 4 - force file list
install_abl_files()
{
	local file preinst_path old_files='' exec_files='' \
		preinst_reg_file="${dist_dir}/preinst_reg.md5" \
		prev_config_format='' upd_config_format='' config_format_changed='' \
		dist_dir="${1}" version="${2}" upd_channel="${3}" new_file_list="${4}"

	[ -n "${1}" ] && [ -n "${2}" ] && [ -n "${3}" ] || inst_failed "Missing arguments."
	log_msg "" "Installing new files..."

	# normalize path
	try_mkdir -p "${dist_dir}${ABL_SERVICE_PATH%/*}"
	mv "${dist_dir}/adblock-lean" "${dist_dir}${ABL_SERVICE_PATH}" || inst_failed

	# get new file list
	if [ -z "${new_file_list}" ]
	then
		new_file_list="$(get_file_list "${dist_dir}${ABL_SERVICE_PATH}" ALL)" &&
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
	exec_files="$(get_file_list "${dist_dir}${ABL_SERVICE_PATH}" EXEC)"

	# handle update
	if [ -n "${IS_UPDATE}" ]
	then
		# get currently installed file list
		old_files="$(get_file_list "${ABL_SERVICE_PATH}" ALL)"
		prev_config_format="$(get_config_format < "${ABL_SERVICE_PATH}")"
		upd_config_format="$(get_config_format < "${dist_dir}${ABL_SERVICE_PATH}")"
		[ -n "${upd_config_format}" ] && [ -n "${prev_config_format}" ] && \
			[ "${upd_config_format}" != "${prev_config_format}" ] &&
			config_format_changed=1

		local IFS="${_NL_}"

		# delete obsolete files
		for file in ${old_files}
		do
			case "${file}" in /*) ;; *) continue; esac # only accept absolute paths
			if [ -f "${file}" ] && ! is_included "${file}" "${new_file_list}" "${_NL_}"
			then
				log_msg "Deleting obsolete file ${file}."
				rm -f "${file}"
			fi
		done
		IFS="${DEFAULT_IFS}"

		(
			clean_abl_env
			# shellcheck source=/dev/null
			if . "${dist_dir}${ABL_SERVICE_PATH}" && check_func abl_post_update_1
			then
				abl_post_update_1
			fi
		)
	fi

	# version and update channel string replacement
	busybox sed -i "
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
		log_msg "File '${file}' did not change - not updating."
	done

	local mod_files_bk_dir="/tmp/abl_old_modified_files"
	for file in ${man_changed_files}
	do
		[ -n "${file}" ] && [ -f "${file}" ] || continue
		log_msg "Warning: File '${file}' was manually modified - overwriting."
		if try_mkdir -p "${mod_files_bk_dir}" && cp "${file}" "${mod_files_bk_dir}/${file##*/}"
		then
			log_msg "Saved a backup copy of manually modified file to ${mod_files_bk_dir}/${file##*/}"
		else
			log_msg "Warning: Can not create a backup copy of manually modified file '${file}' - overwriting anyway."
		fi
	done

	# Copy changed files
	for file in ${changed_files}
	do
		preinst_path="${dist_dir}${file}"
		log_msg "Copying file '${file}'."
		try_mkdir -p "${file%/*}" && cp "${preinst_path}" "${file}" ||
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
		try_mkdir -p "${ABL_FILES_REG_PATH%/*}" &&
		printf '%s\n' "${md5sums}" |
			busybox sed "s~\s${dist_dir}~ ~" > "${ABL_FILES_REG_PATH}" ||
				inst_failed "Failed to register new files."
	fi
	IFS="${DEFAULT_IFS}"

	if [ -n "${IS_UPDATE}" ] && grep -m1 -q '[ 	]*abl_post_update_2()' "${dist_dir}${ABL_SERVICE_PATH}"
	then
		(
			clean_abl_env
			# shellcheck source=/dev/null
			if . "${dist_dir}${ABL_SERVICE_PATH}" && check_func abl_post_update_2
			then
				abl_post_update_2
			fi
		)
	fi

	if [ -n "${config_format_changed}" ]
	then
		(
			clean_abl_env
			failsafe_log "NOTE: config format has changed from v${prev_config_format} to v${upd_config_format}."
			# load config in new version
			# shellcheck source=/dev/null
			if  . "${ABL_SERVICE_PATH}" &&
				{ ! check_func source_libs || source_libs; } &&
				check_func load_config && load_config
			then
				:
			else
				failsafe_log "Please run 'service adblock-lean start' to initialize the new config."
			fi
		:
		)
	fi

	:
}

fetch_and_install()
{
	trap 'cleanup_and_exit 1' INT TERM
	trap 'cleanup_and_exit ${?}' EXIT

	# unset vars and functions from current version to have a clean slate with the new version
	fetch_failed()
	{
		local fail_msg="${1}"
		[ -s "${UCL_ERR_FILE}" ] && fail_msg="${fail_msg} uclient-fetch errors: '$(cat "${UCL_ERR_FILE}")'"
		[ -n "${fail_msg}" ] && reg_failure "${fail_msg}"
		rm -rf "${ABL_UPD_DIR:-???}" "${ABL_PID_DIR:-???}" "${UCL_ERR_FILE:-???}"
		inst_failed
	}

	unexp_arg()
	{
		fetch_failed "fetch_and_install: unexpected argument '${1}'."
	}

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

	if ${ABL_SERVICE_PATH} enabled
	then
		${ABL_SERVICE_PATH} stop
	fi 2>/dev/null

	rm -rf "${ABL_UPD_DIR:-???}"
	try_mkdir -p "${ABL_UPD_DIR}" || fetch_failed

	upd_channel="${req_upd_channel:-"${ABL_UPD_CHANNEL}"}"
	upd_channel="${force_upd_channel:-"${upd_channel}"}"
	upd_channel="${upd_channel:-"release"}"

	dist_dir="${ABL_UPD_DIR}/dist"
	try_mkdir -p "${dist_dir}" || fetch_failed

	if [ -n "${sim_path}" ]
	then
		print_msg "Installing in simulation mode."
		[ -d "${sim_path}" ] || fetch_failed "Update simulation directory '${sim_path}' does not exist."
		[ -n "${ver_str_arg}" ] || fetch_failed "Specify new version string."
		upd_ver="${ver_str_arg}"

		[ -d "${sim_path}" ] || fetch_failed "Simulation source directory doesn't exist."
		cp -rT "${sim_path}" "${dist_dir}"
		log_msg "" "Installing adblock-lean version '${upd_ver}' (update channel: '${upd_channel}')."
	else
		get_gh_ref "${upd_channel}" "${req_ver}" upd_ver tarball_url ver_type || fetch_failed
		case "${upd_channel}" in
			commit=*)
				# set update channel to 'commit=<full_commit_hash>'
				upd_channel="${upd_channel%=*}=${upd_ver}"
		esac
		log_msg "" "Downloading adblock-lean, ${ver_type} '${upd_ver}' (update channel: '${upd_channel}')."
		fetch_abl_dist "${tarball_url}" "${dist_dir}" || fetch_failed
	fi

	get_abl_version "${dist_dir}/adblock-lean"
	(
		case "${?}" in
			2)
				# no version found - call install_abl_files() from this installer
				rm -f "${ABL_FILES_REG_PATH}"
				export pid_file="/tmp/adblock-lean/adblock-lean.pid" # for compatibility with older versions
				install_abl_files "${dist_dir}" "${upd_ver}" "${upd_channel}" "${ABL_SERVICE_PATH}" ;;
			3)
				# new version format - call install_abl_files() from fetched installer
				clean_abl_env
				# shellcheck source=/dev/null
				INST_SOURCED=1 . "${dist_dir}/abl-install.sh" ||
					{ reg_failure "Failed to source fetched install script."; exit 1; }
				install_abl_files "${dist_dir}" "${upd_ver}" "${upd_channel}" ;;
			4)
				# old version format - call install_abl_files() from fetched service file
				rm -f "${ABL_FILES_REG_PATH}"
				clean_abl_env
				# shellcheck source=/dev/null
				. "${dist_dir}/adblock-lean" ||
					{ reg_failure "Failed to source fetched script."; exit 1; }
				printf '%s\n' "${ABL_SERVICE_PATH} ${ABL_LIB_FILES} ${ABL_EXTRA_FILES}" > "${dist_dir}/inst_files"
				install_abl_files "${dist_dir}" "${upd_channel}_v${upd_ver}" ;;
			*) reg_failure "Failed to get version from fetched adblock-lean distribution."; exit 1 ;;
		esac
	) || exit 1

	rm -rf "${ABL_UPD_DIR:-???}" "${ABL_PID_DIR:-???}" "${UCL_ERR_FILE:-???}"
	log_msg "adblock-lean (version '${upd_ver}') has been installed."

	if [ -n "${DO_DIALOGS}" ]
	then
		if [ -n "${IS_UPDATE}" ] && [ -s "${ABL_CONFIG_FILE}" ]
		then
			print_msg "" "Start adblock-lean now? (y|n)"
			pick_opt "y|n"
			if [ "$REPLY" = y ]
			then
				clean_abl_env
				# shellcheck source=/dev/null
				. "${ABL_SERVICE_PATH}" || exit 1
				enable &&
				start
			else
				exit 0
			fi
		else
			print_msg "" "Set up adblock-lean now? (y|n)"
			pick_opt "y|n"
			if [ "$REPLY" = y ]
			then
				clean_abl_env
				# shellcheck source=/dev/null
				. "${ABL_SERVICE_PATH}" || exit 1
				setup
			else
				exit 0
			fi
		fi
	fi
}

[ -s "${ABL_SERVICE_PATH}" ] && IS_UPDATE=1

if [ -z "${INST_SOURCED}" ]
then
	fetch_and_install "${@}"
else
	:
fi