#!/bin/sh
# shellcheck disable=SC2154,SC2086
# ABL_VERSION=dev

# get keys from an associative array
# whitespace-delimited output is set as a value of a global variable
# 1 - array name
# 2 - var name for output
get_a_arr_keys() {
	___me="get_a_arr_keys"
	case ${#} in 2) ;; *) wrongargs "${@}"; return 1; esac
	_arr_name="${1}"
	_out_var="${2}"
	_check_vars _arr_name _out_var || return 1

	eval "${_out_var}=\"\$(printf '%s ' \${_a_${_arr_name}___keys:-})\""

	:
}

# 1 - array name
# 2 - 'key=value' pair
set_a_arr_el() {
	___me="set_a_arr_el"
	case ${#} in 2) ;; *) wrongargs "${@}"; return 1; esac
	_arr_name="${1}"; ___pair="${2}"
	case "${___pair}" in *=* ) ;; *) printf '%s\n' "${___me}: Error: '${___pair}' is not a 'key=value' pair." >&2; return 1; esac
	___key="${___pair%%=*}"
	___new_val="${___pair#*=}"
	_check_vars _arr_name ___key || return 1

	eval "___keys=\"\${_a_${_arr_name}___keys:-}\"
			_a_${_arr_name}_${___key}"='${___new_val}'

	case "${___keys}" in
		*"${_NL_}${___key}"|*"${_NL_}${___key}${_NL_}"* ) ;;
		*) eval "_a_${_arr_name}___keys=\"${___keys}${_NL_}${___key}\""
	esac

	:
}

# 1 - array name
# 2 - key
# 3 - var name for output
get_a_arr_val() {
	___me="get_a_arr_val"
	case ${#} in 3) ;; *) wrongargs "${@}"; return 1; esac
	_arr_name="${1}"; ___key="${2}"; _out_var="${3}"
	_check_vars _arr_name ___key _out_var || return 1
	eval "${_out_var}=\"\${_a_${_arr_name}_${___key}}\""
}


## Backend functions

_check_vars() {
	case "${nocheckvars:-}" in *?*) return 0; esac
	for ___var in "${@}"; do
		eval "_var_val=\"\$${___var}\""
		case "${_var_val}" in ''|*[!A-Za-z0-9_]* )
			case "${___var}" in
				___key) _var_desc="key" ;;
				_arr_name) _var_desc="array name" ;;
				_out_var) _var_desc="output variable name"
			esac
			printf '%s\n' "${___me}: Error: invalid ${_var_desc} '${_var_val}'." >&2
			return 1
		esac
	done
}

wrongargs() {
	echo "${___me}: Error: '${*}': wrong number of arguments '${#}'." >&2
}

_NL_='
'