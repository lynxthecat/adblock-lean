#!/bin/sh
# shellcheck disable=SC3043,SC1090

# silence shellcheck warnings
: "${LIBS_SOURCED}"

ABL_CONFIG_DIR=/etc/adblock-lean
ABL_CONFIG_FILE=${ABL_CONFIG_DIR}/config
ABL_SERVICE_PATH=/etc/init.d/adblock-lean
ABL_DIR=/var/run/adblock-lean
ABL_INST_DIR="${ABL_DIR}/remote_abl"
UCL_ERR_FILE="${ABL_DIR}/uclient-fetch_err"
ABL_GH_URL_API=https://api.github.com/repos/lynxthecat/adblock-lean

LC_ALL=C
DEFAULT_IFS='	 
'
_NL_='
'
IFS="${DEFAULT_IFS}"
_DELIM_="$(printf '\35')"

if [ -z "${MSGS_DEST}" ] && [ -t 0 ]
then
	MSGS_DEST=/dev/tty
else
	MSGS_DEST=/dev/null
fi

DO_DIALOGS=
[ -z "${luci_skip_dialogs}" ] && [ "${MSGS_DEST}" = "/dev/tty" ] && DO_DIALOGS=1

if sed --version 2>/dev/null | grep -qe '(GNU sed)'
then
	SED_CMD="sed"
else
	SED_CMD="busybox sed"
fi


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
		printf %s "$1: " 1>${MSGS_DEST}
		read -r REPLY
		case "$REPLY" in *[!A-Za-z0-9_]*) printf '\n%s\n\n' "Please enter $1" 1>${MSGS_DEST}; continue; esac
		eval "case \"$REPLY\" in 
				$1) return 0 ;;
				*) printf '\n%s\n\n' \"Please enter $1\" 1>${MSGS_DEST}
			esac"
	done
}

get_md5()
{
	md5sum "${1}" | cut -d' ' -f1
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

# shellcheck disable=SC2120
# get config format from config or main script file contents
# input via STDIN or ${1}
get_config_format()
{
	local conf_form_sed_expr='/^[ \t]*(CONFIG_FORMAT|#[ \t]*config_format)=v/{s/.*=v//;p;:1 n;b1;}'
	if [ -n "${1}" ]
	then
		$SED_CMD -En "${conf_form_sed_expr}" "${1}"
	else
		$SED_CMD -En "${conf_form_sed_expr}"
	fi
}

# 1 - new version
# 2 - path to file
update_version()
{
	${SED_CMD} -i "/^\s*#\s*ABL_VERSION=/{s/.*/# ABL_VERSION=${1}/;:1 n;b1;}" "${2}"
}

# Get GitHub ref and tarball url for specified version
# 1 - [latest|snapshot|v<version>|tag=<github_tag>|commit=<commit_hash>]
# Output via variables:
#   $2 - github ref, $3 - tarball url, $4 - update channel
get_gh_ref_data()
{
	local me=get_gh_ref_data ref_fetch_url jsonfilter_ptrn commit version="${1}"
	local gh_ref=''  gh_channel=''
	unset "${2}" "${3}" "${4}"

	case "${version}" in
		snapshot)
			ref_fetch_url="${ABL_GH_URL_API}/commits/master"
			jsonfilter_ptrn='@.sha' # latest commit is first on the list
			gh_channel=snapshot ;;
		latest)
			ref_fetch_url="${ABL_GH_URL_API}/releases"
			jsonfilter_ptrn='@[0].tag_name' # latest tag is first on the list
			gh_channel=release ;;
		v[0-9]*)
			gh_ref="${version}"
			gh_channel=release ;;
		tag=*)
			gh_ref="${version#tag=}"
			gh_channel=tag ;;
		commit=*)
			commit="${version#commit=}"
			gh_ref="${commit%"${commit#???????}"}" # trim commit hash to 7 characters
			gh_channel=commit ;;
		*) reg_failure "${me}: invalid version '${version}'."; return 1
	esac

	if [ -n "${ref_fetch_url}" ]
	then
		# Get ref for latest/snapshot
		log_msg "Getting GitHub ref for ${version} version of adblock-lean from GitHub."
		gh_ref="$(
			uclient-fetch -q "${ref_fetch_url}" -O - 2> "${UCL_ERR_FILE}" |
			jsonfilter -e "${jsonfilter_ptrn}" |
			if [ "${version}" = snapshot ]
			then
				head -c7; cat 1>/dev/null
			else
				cat
			fi
		)"
	fi

	# validate resulting ref
	case "${gh_ref}" in
		''|*[!a-zA-Z0-9._-]*) reg_failure "${me}: failed to get GitHub ref for version '${version}'."; return 1
	esac

	eval "${2}"='${gh_ref}' "${3}"='${ABL_GH_URL_API}/tarball/${gh_ref}' "${4}"='${gh_channel}'
	: "${gh_channel}" # silence shellcheck warning

	:
}


# assigns path to extracted distribution directory to $1
# 1 - var name for output
# 2 - tarball url
# 3 - github ref
fetch_abl_dist()
{
	local fetch_tarball_url="${2}" fetch_ref="${3}"
	local fetch_dir fetch_rv tarball="${ABL_INST_DIR}/remote_abl.tar.gz"
	log_msg "Downloading adblock-lean, version '${fetch_ref}'."
	rm -rf "${UCL_ERR_FILE}" "${ABL_INST_DIR}/lynxthecat-adblock-lean-"*
	uclient-fetch "${fetch_tarball_url}" -O "${tarball}" 2> "${UCL_ERR_FILE}" &&
	grep -q "Download completed" "${UCL_ERR_FILE}" &&
	tar -C "${ABL_INST_DIR}" -xzf "${tarball}" &&
	fetch_dir="$(find "${ABL_INST_DIR}/" -type d -name "lynxthecat-adblock-lean-*")"
	fetch_rv=${?}

	[ "${fetch_rv}" != 0 ] && [ -s "${UCL_ERR_FILE}" ] && ! grep -q "Download completed" "${UCL_ERR_FILE}" &&
		reg_failure "uclient-fetch errors: '$(cat "${UCL_ERR_FILE}")'."
	rm -f "${UCL_ERR_FILE}"
	eval "${1}"='${fetch_dir}'
	: "${fetch_dir}" # silence shellcheck warning
	return ${fetch_rv}
}

# 1 - path to distribution dir
# 2 - version string to write to files
install_abl_files()
{
	local file preinst_path new_files curr_files
	local dist_dir="${1}" version="${2}"

	# read new files list
	read -r new_files < "${dist_dir}/new_files" ||
	{
		reg_failure "Failed to read file '${dist_dir}/new_files'."
		return 1
	}

	# read current files list
	if [ -f "${dist_dir}/curr_files" ]
	then
		read -r curr_files < "${dist_dir}/curr_files" ||
		{
			reg_failure "Failed to read file '${dist_dir}/curr_files'."
			return 1
		}
	fi

	# delete obsolete files
	for file in ${curr_files}
	do
		if [ -f "${file}" ] && ! is_included "${file}" "${new_files}" " "
		then
			log_msg "Deleting obsolete file ${file}."
			rm -f "${file}"
		fi
	done

	for file in ${new_files}
	do
		case "${file##*/}" in
			adblock-lean) preinst_path="${dist_dir}/adblock-lean" ;;
			*) preinst_path="${dist_dir}/${file}"
		esac

		# set new ABL_VERSION
		update_version "${version}" "${preinst_path}"

		if [ -f "${file}" ] && check_util md5sum && [ "$(get_md5 "${preinst_path}")" = "$(get_md5 "${file}")" ]
		then
			log_msg "File '${file}' did not change - not updating."
		else
			log_msg "Copying file '${file##*/}'."
			{ [ -d "${file%/*}" ] || try_mkdir -p "${file%/*}"; } &&
				cp "${preinst_path}" "${file}" ||
			{
				reg_failure "Failed to copy file '${file##*/}'."
				return 1
			}
		fi
	done

	chmod +x "${ABL_SERVICE_PATH}"
	:
}

inst_failed()
{
	local fail_msg="${1}"
	[ -s "${UCL_ERR_FILE}" ] && fail_msg="${fail_msg} uclient-fetch errors: '$(cat "${UCL_ERR_FILE}")'"
	[ -n "${fail_msg}" ] && reg_failure "${fail_msg}"
	reg_failure "Failed to install adblock-lean."
	rm -rf "${ABL_INST_DIR}" "${UCL_ERR_FILE}"
}

failsafe_log()
{
	printf '%s\n' "${1}" > "${MSGS_DEST:-/dev/tty}"
	logger -t adblock-lean "${1}"
}

unexp_arg()
{
	inst_failed "abl-install: unexpected argument '${1}'."
}


if ${ABL_SERVICE_PATH} enabled 2>/dev/null
then
	${ABL_SERVICE_PATH} stop
fi

try_mkdir -p "${ABL_DIR}" || exit 1

unset VERSION DIST_DIR REF TARBALL_URL UPD_CHANNEL

while getopts ":s:v:" opt; do
	case ${opt} in
		s) SIM_PATH=${OPTARG} ;;
		v) VERSION=${OPTARG} ;;
		*) unexp_arg "-${OPTARG}"; exit 1
	esac
done
shift $((OPTIND-1))
[ -z "${*}" ] || { unexp_arg "${*}"; exit 1; }

rm -rf "${ABL_INST_DIR}"
try_mkdir -p "${ABL_INST_DIR}" || { inst_failed; exit 1; }

if [ -n "${SIM_PATH}" ]
then
	print_msg "" "Running in simulation mode."
	[ -d "${SIM_PATH}" ] || { inst_failed "Directory '${SIM_PATH}' does not exist."; exit 1; }
	[ -n "${VERSION}" ] || { inst_failed "Specify new version."; exit 1; }
	UPD_CHANNEL=dev REF="${VERSION}"
	DIST_DIR="${ABL_INST_DIR}/simulation"
	try_mkdir -p "${DIST_DIR}" || { inst_failed; exit 1; }
	cp -rT "${SIM_PATH}" "${DIST_DIR}"
else
	: "${VERSION:=latest}"
	get_gh_ref_data "${VERSION}" REF TARBALL_URL UPD_CHANNEL &&
	fetch_abl_dist DIST_DIR "${TARBALL_URL}" "${REF}" || { inst_failed; exit 1; }
fi

(
	# unset vars and functions from current version to have a clean slate with the new version
	unset_vars()
	{
		unset ABL_LIB_FILES ABL_EXTRA_FILES
		unset -f abl_post_update_1 abl_post_update_2 get_config_format load_config
	}

	unset is_update prev_config_format
	export pid_file=/tmp/adblock-lean/adblock-lean.pid # for compatibility with older versions

	# register config format in the installed adblock-lean version
	if [ -s "${ABL_CONFIG_FILE}" ]
	then
		prev_config_format="$(get_config_format < "${ABL_CONFIG_FILE}")"
	fi

	# register files list in the installed adblock-lean version
	if [ -s "${ABL_SERVICE_PATH}" ]
	then
		unset_vars
		is_update=1
		touch "${DIST_DIR}/is_update"
		curr_abl_files="${ABL_SERVICE_PATH}"
		# shellcheck source=/dev/null
		if . "${ABL_SERVICE_PATH}"
		then
			for file in ${ABL_LIB_FILES} ${ABL_EXTRA_FILES}
			do
				curr_abl_files="${curr_abl_files} ${file}"
			done
			printf '%s\n' "${curr_abl_files}" > "${DIST_DIR}/curr_files"
		fi
	fi

	unset_vars
	# shellcheck source=/dev/null
	. "${DIST_DIR}/adblock-lean" || { failsafe_log "Error: Failed to source the downloaded script."; exit 1; }

	# if updating, call abl_post_update_1() in new version
	[ -n "${is_update}" ] && check_util abl_post_update_1 && abl_post_update_1

	# register files included in the new version
	new_abl_files="${ABL_SERVICE_PATH}"
	for file in ${ABL_LIB_FILES} ${ABL_EXTRA_FILES}
	do
		new_abl_files="${new_abl_files} ${file}"
	done
	printf '%s\n' "${new_abl_files}" > "${DIST_DIR}/new_files"

	# register config format in the new adblock-lean version
	check_util get_config_format && upd_config_format="$(get_config_format < "${DIST_DIR}/adblock-lean")"

	if [ -n "${upd_config_format}" ] && [ -n "${prev_config_format}" ] && [ "${upd_config_format}" != "${prev_config_format}" ]
	then
		failsafe_log "NOTE: config format has changed from v${prev_config_format} to v${upd_config_format}."
		# load config and call abl_post_update_2() in new version
		if { ! check_util source_libs || source_libs "${DIST_DIR}${ABL_LIB_DIR}"; } && check_util load_config
		then
			load_config
			check_util abl_post_update_2 && abl_post_update_2
		else
			failsafe_log "Please run 'service adblock-lean start' to initialize the new config."
		fi
	fi
	:
) 1>/dev/null || { inst_failed "Failed to source the new version of adblock-lean. Update is cancelled."; exit 1; }

print_msg ""

install_abl_files "${DIST_DIR}" "${UPD_CHANNEL}_${REF}" || { inst_failed; exit 1; }

IS_UPDATE=
[ -f "${DIST_DIR}/is_update" ] && IS_UPDATE=1

rm -rf "${ABL_INST_DIR}" "${UCL_ERR_FILE}"

log_msg "adblock-lean ${REF} has been installed."

if [ -n "${DO_DIALOGS}" ]
then
	if [ -n "${IS_UPDATE}" ]
	then
		print_msg "" "Start adblock-lean now? (y|n)"
		pick_opt "y|n"
		if [ "$REPLY" = y ]
		then
			# shellcheck source=/dev/null
			${ABL_SERVICE_PATH} start
		fi
	else
		print_msg "" "Set up adblock-lean now? (y|n)"
		pick_opt "y|n"
		if [ "$REPLY" = y ]
		then
			# shellcheck source=/dev/null
			${ABL_SERVICE_PATH} setup
		fi
	fi
fi

:
