#!/bin/sh
# shellcheck disable=SC3043,SC3045,SC3003

### Helpers

sch_is_included() {
	is_included "${@}"
}

sch_append() {
	abl_append "${@}"
}

sch_rm_elem() {
	subtract_a_from_b "${2}" "${3}" "${1}"
}

sch_is_uint() {
	is_uint "${@}"
}

sch_get_uptime_cs() {
	get_uptime_cs "${@}"
}

sch_fail_msg() {
	reg_fail "${@}"
}

sch_is_cmd() {
	is_cmd "${@}"
}

sch_job_term_ppid() {
	term_ppid "${@}"
}

sch_has_f() {
	has_f
}

sch_tr_leading() {
	sch_check_name "var" "${1}" &&
	tr_leading "${@}"
}

# --- Unmodified code from upstream below

# Look up PID of a job in list of '<pid>:<job ID>' entries
# 1: out var
# 2: job ID
# 3: cur list
sch_pid_of_id() {
	local spi_l=" ${3} " spi_p
	export -n "${1:?}="

	case "${spi_l}" in
		*":${2} "*) ;;
		*) return 1
	esac

	spi_p="${spi_l%%":${2} "*}"
	export -n "${1}=${spi_p##* }"
}

# Get reuse-proof '<pid>_<starttime>' of current shell process
# 1: out-var
sch_get_uid() {
	local sgu_had_f sgu_pid sgu_start sgu_line \
		IFS=" "$'\t'$'\n' \
		sgu_out="${1:?}"
	export -n "${sgu_out}="

	IFS= read -r sgu_line 2>/dev/null < /proc/self/stat || sgu_line=

	sgu_pid="${sgu_line%% *}"
	# Strip 'pid (comm) ' greedily - comm may contain ') ' and spaces
	sgu_line="${sgu_line##*") "}"

	sch_has_f && sgu_had_f=1
	set -f
	set -- ${sgu_line}
	[ -n "${sgu_had_f}" ] || set +f

	# Start time is stat field 22; the strip leaves state (field 3) first
	[ "${#}" -ge 20 ] && shift 19 && sgu_start="${1}"

	sch_is_uint "${sgu_pid}" "${sgu_start}" ||
		{ sch_fail_msg "Failed to get PID and start time from /proc/self/stat."; return 1; }
	export -n "${sgu_out}=${sgu_pid}_${sgu_start}"
}

sch_check_name() {
	local pfx="SCH_JOB_PARAMS_${#SCHED_ID}_${SCHED_ID}_" max_len=2020

	[ "${1}" = var ] && max_len=$((max_len + ${#pfx}))

	[ "${#2}" -le "${max_len}" ] &&
	case "${2}" in
		''|*[!a-zA-Z0-9_]*) false ;;
		*) : ;;
	esac &&
	{
		[ "${1}" != var ] ||
		case "${2}" in
			[a-zA-Z_]*) : ;;
			*) false
		esac
	} &&
	return 0

	sch_fail_msg "${3}${3:+": "}${1}${1:+ }'${2}' is empty string or contains incompatible characters, or is too long."
	return 1
}

# Validate user-supplied var name
# 1: name
# 2: caller name
sch_check_var_name() {
	sch_check_name "var" "${1}" "${2}" || return 1
	case "${1}" in
		sch_*|_sch_*|SCH_*|SCHED_*|DO_JOB_CB|JOB_DONE_CB|JOB_TERM_CB|IFS)
			sch_fail_msg "${2}: var name '${1}' is reserved for internal use."
			return 1
	esac
}

# 1: caller
# any extra args attached to err msg
sch_in_main_process() {
	local uid arg args caller="${1}"
	sch_get_uid uid &&
	[ "${uid}" = "${SCHED_UID}" ] &&
	eval "[ -n \"\${SCH_STARTED_${uid}}\" ]" &&
		return 0
	[ "${#}" -ge 1 ] && shift
	for arg in "${@}"; do
		args="${args}${args:+, }'${arg}'"
	done
	sch_fail_msg "${caller}: Scheduler is not running in this process or SCHED_UID '${SCHED_UID}' doesn't match this process UID '${uid}'.${args:+" args: ${args}"}"
	return 1
}

# Resolve the ${SCHED_ID} namespace infix '<len of SCHED_ID>_<SCHED_ID>_'
# 1: out var name
# 2: caller name
sch_get_ns() {
	export -n "${1:?}="
	[ -z "${SCHED_ID}" ] ||
		sch_check_name "SCHED_ID" "${SCHED_ID}" "${2}" || return 1
	export -n "${1}=${#SCHED_ID}_${SCHED_ID}_"
}

sch_finalize() {
	local sch_me=sch_finalize sch_unfinished_ids sch_exp_e sch_job_id sch_running_pids \
		IFS=" "$'\t'$'\n' \
		sch_rv="${1}"

	sch_in_main_process "${sch_me}" "${@}" ||
		return "${sch_rv:-1}"

	unset "SCH_STARTED_${SCHED_UID}"

	trap ':' USR1 INT TERM EXIT

	[ -n "${2}" ] && [ "${sch_rv}" != 0 ] && sch_fail_msg "${2}"

	exec 3>&-
	[ -n "${sch_run_dir}" ] && rm -rf "${sch_run_dir}"

	if [ -n "${SCH_HAD_F}" ]; then set -f; else set +f; fi

	# Collect pids of jobs still accounted as running
	for sch_exp_e in ${SCH_RUNNING}; do
		sch_append sch_running_pids "${sch_exp_e%%:*}"
	done

	[ -n "${JOB_TERM_CB}" ] &&
	[ -n "${sch_running_pids}" ] &&
		sch_term_run ${sch_running_pids}

	# Add pids of timed-out and aborted jobs to <running_pids>
	for sch_exp_e in ${SCH_UNREAPED}; do
		sch_append sch_running_pids "${sch_exp_e%%:*}"
	done

	# Compute sch_unfinished_ids
	for sch_job_id in ${SCH_JOB_IDS}; do
		sch_is_included "${sch_job_id}" "${SCH_OK_IDS} ${SCH_UNDISPATCHED_IDS} ${SCH_FAIL_IDS} ${SCH_EXPIRED_IDS} ${SCH_ABORTED_IDS}" ||
			sch_append sch_unfinished_ids "${sch_job_id}"
	done

	[ -n "${SCHED_FINALIZE_CB}" ] && {
		"${SCHED_FINALIZE_CB}" "${sch_rv}" "${sch_running_pids}" "${SCH_OK_IDS}" "${SCH_FAIL_IDS}" "${sch_unfinished_ids}" "${SCH_UNDISPATCHED_IDS}" "${SCH_EXPIRED_IDS}" "${SCH_ABORTED_IDS}"
		sch_rv=${?}
	}

	exit "${sch_rv}"
}

sch_start_job() {
	local \
		sch_job_rv \
		sch_job_id="${1:?}"

	shift

	trap '
		sch_job_rv=${?}
		printf "%s %s\n" "${sch_job_rv}" "${sch_job_id}" >&3 2>/dev/null
		exit "${sch_job_rv}"
	' EXIT

	job_get_params -export "${sch_job_id}" sch_all || exit 1

	if [ -n "${SCHED_INNER_SUBSHELL}" ]; then
		( "${DO_JOB_CB:?}" "${sch_job_id}" "${@}" 3>&- )
	else
		"${DO_JOB_CB:?}" "${sch_job_id}" "${@}"
	fi

	exit "${?}"
}

# Invoke JOB_DONE_CB, export params unconditionally
# 1: callback command
# 2: job ID
# Extra args: passed to the callback as-is
sch_run_done_cb() {
	local sch_me=sch_run_done_cb \
		sch_had_f \
		sch_p \
		sch_names \
		sch_ns \
		sch_cb="${1}" \
		sch_dc_id="${2}"

	shift

	sch_get_ns sch_ns "${sch_me}" || return 1
	eval "sch_names=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_dc_id}}\""

	sch_has_f && sch_had_f=1
	set -f

	for sch_p in ${sch_names}; do
		sch_check_var_name "${sch_p}" "${sch_me}" || { sch_names=; break; }
	done

	[ -z "${sch_names}" ] || {
		#shellcheck disable=SC2086
		local ${sch_names}
		job_get_params -export "${sch_dc_id}" sch_all
	}

	[ -n "${sch_had_f}" ] || set +f

	"${sch_cb}" "${@}"
}

sch_read_rec() {
	local srr_out="${1:?}" srr_fifo="${2:?}" srr_t="${3:?}" \
		srr_rec srr_tail

	export -n "${srr_out}="
	[ "${srr_t}" -gt 0 ] || return 1

	IFS= read -t "${srr_t}" -r srr_rec < "${srr_fifo}" ||
	{
		# Timed out, possibly mid-record
		IFS= read -t 0 -r _ < "${srr_fifo}" &&
			IFS= read -t 1 -r srr_tail < "${srr_fifo}"

		[ -n "${BASH_VERSION}" ] || [ -n "${SHED_VERSION}" ] || [ -n "${srr_rec}" ] || srr_tail=

		srr_rec="${srr_rec}${srr_tail}"
		[ -n "${srr_rec}" ] || return 1
	}

	[ -n "${srr_rec}" ] || return 0

	export -n "${srr_out}=${srr_rec}"
}

# Take the completion records queued on the IPC FIFO, act on them, then sweep expired deadlines.
# Called only when no job can be dispatched, so the wait for a record is unconditional.
# Wait is capped by the run's remaining time and by the nearest job deadline.
# 1: current time (centiseconds)
sch_process_records() {
	local \
		sch_cs \
		sch_now_cs \
		sch_read_t_cs \
		sch_read_t_s \
		sch_rec \
		sch_n \
		sch_batch \
		sch_dl_prev \
		sch_job_pid \
		sch_job_id \
		sch_done_rv \
		sch_done_id \
		sch_had_f \
		sch_e \
		sch_cur_time_cs="${1:?}"

	sch_has_f && sch_had_f=1

	# Cap the wait by the nearest deadline
	sch_read_t_cs="${SCH_REMAIN_TIME_CS}"
	set -f
	for sch_e in ${SCH_DEADLINES}; do
		sch_cs=$(( ${sch_e%%:*} - sch_cur_time_cs ))
		[ "${sch_cs}" -lt "${sch_read_t_cs}" ] && sch_read_t_cs="${sch_cs}"
	done
	[ -n "${sch_had_f}" ] || set +f

	sch_read_t_s=$(( (sch_read_t_cs + 99) / 100 ))

	# Capped at 100 records per call, so that a sustained writer cannot defer dispatch and the timeout check indefinitely
	# A deadline already past makes the first read a no-op: count it only if it consumed a record
	sch_n=0
	sch_read_rec sch_rec "${SCH_IPC_FIFO}" "${sch_read_t_s}" && sch_n=1
	while :; do
		# Empty means a read timeout, or an empty line
		if [ -n "${sch_rec}" ]; then
			# ${sch_rec} comes off the FIFO unvalidated - never glob it
			set -f
			set -- ${sch_rec}
			[ -n "${sch_had_f}" ] || set +f

			[ "${#}" = 2 ] && sch_is_uint "${1}" && sch_is_included "${2}" "${SCH_JOB_IDS}" ||
				sch_finalize 1 "Malformed completion record: '${sch_rec}'."
			sch_append sch_batch "${1}:${2}"
		fi

		[ "${sch_n}" -lt 100 ] || break

		# 'read -t 0' reports whether more data is waiting, consumes nothing
		IFS= read -t 0 -r _ < "${SCH_IPC_FIFO}" || break
		sch_n=$((sch_n+1))
		sch_read_rec sch_rec "${SCH_IPC_FIFO}" 1
	done

	# One reading serves both the progress stamp and the expiry sweep. Taken before any
	#   callback runs, so time a callback spends counts against the idle timeout
	sch_get_uptime_cs sch_now_cs || sch_finalize 1

	# Arrival wins over expiry: records are handled before deadlines are swept.
	for sch_e in ${sch_batch}; do
		sch_done_rv="${sch_e%%:*}"
		sch_done_id="${sch_e#*:}"

		if sch_pid_of_id sch_job_pid "${sch_done_id}" "${SCH_UNREAPED}"; then
			# Late record from a job already timed out or aborted - discard
			sch_rm_elem SCH_UNREAPED "${sch_job_pid}:${sch_done_id}" "${SCH_UNREAPED}"
		elif sch_pid_of_id sch_job_pid "${sch_done_id}" "${SCH_RUNNING}"; then
			sch_rm_elem SCH_RUNNING "${sch_job_pid}:${sch_done_id}" "${SCH_RUNNING}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))

			[ -n "${SCH_DEADLINES}" ] &&
				sch_deadline_rm_id SCH_DEADLINES "${sch_done_id}" "${SCH_DEADLINES}"

			if [ "${sch_done_rv}" = 0 ]; then
				sch_append SCH_OK_IDS "${sch_done_id}"
			else
				sch_append SCH_FAIL_IDS "${sch_done_id}"
			fi

			# Only a genuine completion is progress; a discarded late record is not
			SCH_LAST_PROGRESS_TIME_CS="${sch_now_cs}"

			[ -z "${JOB_DONE_CB}" ] ||
			sch_run_done_cb "${JOB_DONE_CB}" "${sch_done_id}" "${sch_done_rv}" ||
				sch_finalize ${?}
		else
			sch_finalize 1 "Unexpected completion record for job ID '${sch_done_id}'."
		fi
	done

	[ -n "${SCH_DEADLINES}" ] && {
		# Rebuild the list, acting on entries that expired (deadline <= now).
		# Carries run state a callback can reach, so the split runs with globbing off
		sch_dl_prev="${SCH_DEADLINES}"
		SCH_DEADLINES=
		set -f
		for sch_e in ${sch_dl_prev}; do
			# Restored per iteration: the expiry path calls into user code
			[ -n "${sch_had_f}" ] || set +f

			if [ "${sch_e%%:*}" -le "${sch_now_cs}" ]; then
				sch_job_id="${sch_e#*:}"

				# Gone from SCH_RUNNING: a callback above aborted it - drop the entry,
				#   the job is already classified
				sch_pid_of_id sch_job_pid "${sch_job_id}" "${SCH_RUNNING}" || continue
				sch_rm_elem SCH_RUNNING "${sch_job_pid}:${sch_job_id}" "${SCH_RUNNING}"
				SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))
				sch_append SCH_EXPIRED_IDS "${sch_job_id}"
				sch_append SCH_UNREAPED "${sch_job_pid}:${sch_job_id}"

				# Kill the timed-out job's whole process tree (wrapper included)
				[ -n "${JOB_TERM_CB}" ] &&
					sch_term_run "${sch_job_pid}"

				[ -z "${JOB_DONE_CB}" ] ||
				sch_run_done_cb "${JOB_DONE_CB}" "${sch_job_id}" 124 "${sch_job_pid}" ||
					sch_finalize ${?}
			else
				sch_append SCH_DEADLINES "${sch_e}"
			fi
		done
		[ -n "${sch_had_f}" ] || set +f
	}

	return 0
}


# Remove job's entry from list of '<deadline>:<job ID>' entries
sch_deadline_rm_id() {
	local sdr_e=" ${3} "

	case "${sdr_e}" in
		*":${2} "*) ;;
		*) export -n "${1:?}=${3}"; return 1
	esac

	sdr_e="${sdr_e%%":${2} "*}"
	sdr_e="${sdr_e##* }:${2}"
	sch_rm_elem "${1}" "${sdr_e}" "${3}"
}


# Args: passed to the command
sch_term_run() {
	"${JOB_TERM_CB}" "${@}" ||
		sch_fail_msg "Job termination callback '${JOB_TERM_CB}' returned code ${?}."
	:
}

#
# User-facing functions
#

schedule_jobs() {
	# 1: var name
	# 2: required(1/empty)
	sch_check_cb() {
		local val
		sch_check_name "var" "${1}" "sch_check_cb" || return 1
		eval "val=\"\${${1}}\""
		[ -z "${val}" ] && [ -z "${2}" ] && return 0
		[ -z "${val}" ] && { sch_fail_msg "Required callback is missing (set via \${${1}})."; return 1; }
		sch_is_cmd "${val}" || { sch_fail_msg "Invalid value of ${1} '${val}'."; return 1; }
	}

	# Normalize delimiters to single-space
	sch_normalize_ids() {
		local \
			IFS=" "$'\t'$'\n' \
			out_var="${1}"

		set -f
		set -- ${2}
		IFS=" "
		export -n "${out_var}=${*}"
		[ -n "${SCH_HAD_F}" ] || set +f
	}

	sch_normalize_uint() {
		local val="${2}"
		export -n "${1:?}="
		[ -z "${val}" ] && [ -z "${3}" ] && return 0
		sch_is_uint "${val}" && [ "${val}" -ge 1 ] ||
			{ sch_fail_msg "Invalid value '${val}' of env var SCHED_${1#SCH_}."; return 1; }
		sch_tr_leading val "${val}" "0"
		export -n "${1}=${val}"
	}

	local \
		SCH_RV_IDLE_TIMEOUT=81 \
		SCH_RV_GLOBAL_TIMEOUT=82 \
		SCH_RV_USR1=83 \
		SCH_RV_INT_TERM=84

	local \
		IFS=" "$'\t'$'\n' \
		SCHED_PID \
		SCHED_UID \
		sch_cur_time_cs \
		sch_idle_remain_time_cs \
		sch_job_id \
		sch_job_pid \
		sch_ns \
		sch_seen_ids \
		sch_job_to \
		sch_dl_now_cs \
		sch_run_dir \
		sch_run_n \
		sch_dir="/tmp" \
		\
		SCH_IPC_FIFO \
		SCH_RUNNING_JOBS_CNT=0 \
		SCH_HAD_F \
		SCH_REMAIN_TIME_CS \
		SCH_INIT_UPTIME_CS \
		SCH_LAST_PROGRESS_TIME_CS \
		SCH_IN_FAIL_MSG_CB \
		SCH_RUNNING \
		SCH_MAX_JOBS \
		SCH_TIMEOUT_S \
		SCH_IDLE_TIMEOUT_S \
		SCH_JOB_TIMEOUT_S \
		SCH_DEADLINES \
		SCH_UNREAPED \
		\
		SCH_PENDING_IDS \
		SCH_ABORTED_IDS \
		SCH_UNDISPATCHED_IDS \
		SCH_OK_IDS \
		SCH_FAIL_IDS \
		SCH_EXPIRED_IDS \
		\
		SCH_JOB_IDS="${1?}"
	
	: "${SCH_REMAIN_TIME_CS}" "${SCH_JOB_TIMEOUT_S}" # Silence shellcheck warning

	shift 1

	sch_has_f && SCH_HAD_F=1

	[ -n "${SCHED_AUTO_JOB_TERM}" ] && JOB_TERM_CB=sch_job_term_ppid

	# Check callbacks
	sch_check_cb SCHED_FAIL_MSG_CB &&
	sch_check_cb SCHED_FINALIZE_CB &&
	sch_check_cb DO_JOB_CB required &&
	sch_check_cb JOB_DONE_CB &&
	sch_check_cb JOB_TERM_CB &&
	sch_check_cb SCHED_DISPATCH_TICK_CB || exit 1

	# Check env vars, normalize into internal copies
	sch_normalize_uint SCH_MAX_JOBS "${SCHED_MAX_JOBS}" required &&
	sch_normalize_uint SCH_TIMEOUT_S "${SCHED_TIMEOUT_S:-900}" &&
	sch_normalize_uint SCH_IDLE_TIMEOUT_S "${SCHED_IDLE_TIMEOUT_S:-300}" &&
	sch_normalize_uint SCH_JOB_TIMEOUT_S "${SCHED_JOB_TIMEOUT_S}" || exit 1

	# Check namespace; register scheduler start
	sch_get_ns sch_ns "schedule_jobs" &&
	sch_get_uptime_cs SCH_INIT_UPTIME_CS &&
	sch_get_uid SCHED_UID ||
		exit 1
	SCHED_PID="${SCHED_UID%%_*}"
	export -n "SCH_STARTED_${SCHED_UID}=1"

	sch_normalize_ids SCH_JOB_IDS "${SCH_JOB_IDS}" || exit 1

	# Validate job IDs, check duplicates
	set -f
	for sch_job_id in ${SCH_JOB_IDS}; do
		[ -n "${SCH_HAD_F}" ] || set +f
		sch_check_name "job ID" "${sch_job_id}" || exit 1
		sch_is_included "${sch_job_id}" "${sch_seen_ids}" &&
			{ sch_fail_msg "Duplicate Job ID '${sch_job_id}'."; exit 1; }
		sch_append sch_seen_ids "${sch_job_id}"
	done
	[ -n "${SCH_HAD_F}" ] || set +f

	SCH_UNDISPATCHED_IDS="${SCH_JOB_IDS}"
	SCH_PENDING_IDS="${SCH_JOB_IDS}"

	# Main logic

	SCH_LAST_PROGRESS_TIME_CS="${SCH_INIT_UPTIME_CS}"

	mkdir -p "${sch_dir}" ||
		sch_finalize 1 "Failed to create directory '${sch_dir}'."

	sch_run_n=0
	while :; do
		sch_run_dir="${sch_dir}/sched_${SCHED_UID}.${sch_run_n}"
		SCH_IPC_FIFO="${sch_run_dir}/ipc"
		# Owner-only FIFO and run dir
		(
			umask 077
			mkdir "${sch_run_dir}" 2>/dev/null &&
			{
				mkfifo "${SCH_IPC_FIFO}" || {
					rm -rf "${sch_run_dir}"
					false
				}
			}
		) && break
		sch_run_n=$((sch_run_n + 1))
		[ "${sch_run_n}" -lt 16 ] ||
			sch_finalize 1 "Failed to create run directory or FIFO file under '${sch_dir}'."
	done

	exec 3<>"${SCH_IPC_FIFO}" ||
		sch_finalize 1 "Failed to open FIFO '${SCH_IPC_FIFO}'."

	trap 'sch_finalize "${SCH_RV_USR1}"' USR1
	trap 'sch_finalize "${SCH_RV_INT_TERM}"' INT TERM
	trap 'sch_finalize "${?}" "Scheduler process exited unexpectedly."' EXIT

	# Start jobs

	# Filling a free concurrency slot outranks everything:
	#   the FIFO is only read, and deadlines only swept, once no slot can be filled.
	# ${SCH_PENDING_IDS} shrinks as jobs are dispatched; jobs_abort() may also remove from it
	while [ -n "${SCH_PENDING_IDS}" ] || [ "${SCH_RUNNING_JOBS_CNT}" -gt 0 ]; do
		[ -e "${SCH_IPC_FIFO}" ] || sch_finalize 1 "Scheduler FIFO disappeared."

		# Check if global or idle timeout is due, update SCH_REMAIN_TIME_CS
		sch_get_uptime_cs sch_cur_time_cs || sch_finalize 1
		SCH_REMAIN_TIME_CS=$(( SCH_TIMEOUT_S*100 - (sch_cur_time_cs-SCH_INIT_UPTIME_CS) ))
		sch_idle_remain_time_cs=$(( SCH_IDLE_TIMEOUT_S*100 - (sch_cur_time_cs-SCH_LAST_PROGRESS_TIME_CS) ))

		if [ ! "${SCH_REMAIN_TIME_CS}" -gt 0 ]; then
			sch_finalize "${SCH_RV_GLOBAL_TIMEOUT}" "Processing timeout (${SCH_TIMEOUT_S} s) for scheduler (PID: ${SCHED_PID})."
		elif [ ! "${sch_idle_remain_time_cs}" -gt 0 ]; then
			sch_finalize "${SCH_RV_IDLE_TIMEOUT}" "Idle timeout (${SCH_IDLE_TIMEOUT_S} s) for scheduler (PID: ${SCHED_PID})."
		fi

		if [ "${sch_idle_remain_time_cs}" -lt "${SCH_REMAIN_TIME_CS}" ]; then
			SCH_REMAIN_TIME_CS="${sch_idle_remain_time_cs}"
		fi

		sch_job_id="${SCH_PENDING_IDS%% *}"

		if [ "${SCH_RUNNING_JOBS_CNT}" -lt "${SCH_MAX_JOBS}" ] && [ -n "${sch_job_id}" ]; then
			# Callback may have broken the contract by changing sch_ns or SCHED_ID - recompute sch_ns before fork
			sch_get_ns sch_ns "schedule_jobs" || sch_finalize 1

			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT + 1))

			sch_start_job "${sch_job_id}" "${@}" &
			sch_job_pid="${!}"
			# Track the child first - on a signal, finalize can only kill what's listed here
			sch_append SCH_RUNNING "${sch_job_pid}:${sch_job_id}"

			sch_rm_elem SCH_PENDING_IDS "${sch_job_id}" "${SCH_PENDING_IDS}"
			sch_rm_elem SCH_UNDISPATCHED_IDS "${sch_job_id}" "${SCH_UNDISPATCHED_IDS}"

			# Reset the idle timeout at job start
			sch_get_uptime_cs sch_dl_now_cs || sch_finalize 1
			SCH_LAST_PROGRESS_TIME_CS="${sch_dl_now_cs}"

			# Register job's timeout deadline if it has one
			eval "sch_job_to=\"\${SCH_TIMEOUT_JOB_${sch_ns}${sch_job_id}:-\${SCH_JOB_TIMEOUT_S}}\""

			[ -n "${sch_job_to}" ] &&
				sch_append SCH_DEADLINES "$((sch_dl_now_cs + sch_job_to*100)):${sch_job_id}"

			[ -z "${SCHED_DISPATCH_TICK_CB}" ] ||
				"${SCHED_DISPATCH_TICK_CB}" "${sch_job_id}"

			# Keep filling free slots before any completion record is acted on
			continue
		fi

		# Waits for a completion record.
		# Updates ${SCH_RUNNING_JOBS_CNT}; ${SCH_RUNNING}; ${SCH_LAST_PROGRESS_TIME_CS}
		sch_process_records "${sch_cur_time_cs}"
	done

	sch_finalize 0
}

# args: one or more whitespace-separated job ID lists
jobs_init() {
	local \
		IFS=" "$'\t'$'\n' \
		had_f \
		cur_params \
		param \
		job_id \
		ns \
		rv=0

	# Resolved before any name is built: 'unset' with an invalid name aborts busybox ash
	sch_get_ns ns "jobs_init" || return 1

	sch_has_f && had_f=1
	set -f

	#shellcheck disable=SC2048
	for job_id in ${*}; do
		sch_check_name "job ID" "${job_id}" "jobs_init" ||
			{ rv=1; break; }
		eval "cur_params=\"\${SCH_JOB_PARAMS_${ns}${job_id}}\""

		for param in ${cur_params}; do
			case "${param}" in
				''|*[!a-zA-Z0-9_]*) continue ;;
			esac
			unset "SCH_JOB_PARAM_${ns}${#job_id}_${job_id}_${param}"
		done
		unset "SCH_JOB_PARAMS_${ns}${job_id}" \
			"SCH_TIMEOUT_JOB_${ns}${job_id}"
	done

	[ -n "${had_f}" ] || set +f
	return "${rv}"
}

# 1: job ID
# Extra args: <param=value> pairs
job_set_params() {
	local sch_me=job_set_params \
		IFS=" "$'\t'$'\n' \
		sch_param \
		sch_val \
		sch_cur_params \
		sch_pair \
		sch_pair_seen \
		sch_ns \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift

	sch_get_ns sch_ns "${sch_me}" || return 1
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	for sch_pair; do
		sch_pair_seen=1
		case "${sch_pair}" in
			*=*) ;;
			*)
				sch_fail_msg "${sch_me}: Invalid key-value pair '${sch_pair}'."
				return 1
		esac

		sch_param="${sch_pair%%=*}"
		sch_val="${sch_pair#"${sch_param}="}"
		sch_check_name "param" "${sch_param}" "${sch_me}" || return 1

		eval "sch_cur_params=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_job_id}}\""
		sch_is_included "${sch_param}" "${sch_cur_params}" ||
		sch_append "SCH_JOB_PARAMS_${sch_ns}${sch_job_id}" "${sch_param}" ||
			return 1
		export -n "SCH_JOB_PARAM_${sch_ns}${#sch_job_id}_${sch_job_id}_${sch_param}=${sch_val}"
	done

	[ -n "${sch_pair_seen}" ] ||
		{ sch_fail_msg "${sch_me}: no params specified."; return 1; }
}

# 0 (optional): '-export'
# 1: job ID
# Extra args: "sch_all" or <list of params, one per argument>, or <list of var=param>
job_get_params() {
	local sch_export
	[ "${1}" = '-export' ] && { sch_export="export "; shift; }

	local sch_me=job_get_params \
		IFS=" "$'\t'$'\n' \
		sch_param \
		sch_var \
		sch_had_f \
		sch_job_params \
		sch_param_seen \
		sch_ns \
		sch_job_id="${1}"

	[ -n "${1+x}" ] && shift
	sch_get_ns sch_ns "${sch_me}" || return 1
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	[ "${*}" = sch_all ] && {
		eval "sch_job_params=\"\${SCH_JOB_PARAMS_${sch_ns}${sch_job_id}}\""
		[ -n "${sch_job_params}" ] || return 0

		sch_has_f && sch_had_f=1
		set -f
		set -- ${sch_job_params}
		[ -n "${sch_had_f}" ] || set +f
	}

	for sch_param; do
		sch_param_seen=1
		sch_var="${sch_param}"
		case "${sch_param}" in
			*=*)
				sch_var="${sch_param%%=*}"
				sch_param="${sch_param#*=}"
		esac

		sch_check_name "param" "${sch_param}" "${sch_me}" &&
		sch_check_var_name "${sch_var}" "${sch_me}" || return 1

		eval "${sch_export}${sch_var}=\"\${SCH_JOB_PARAM_${sch_ns}${#sch_job_id}_${sch_job_id}_${sch_param}}\""
	done

	[ -n "${sch_param_seen}" ] ||
		{ sch_fail_msg "${sch_me}: no params specified."; return 1; }
}

# Set a per-job timeout, overriding ${SCHED_JOB_TIMEOUT_S} for this job
# 1: job ID
# 2: timeout in seconds
job_set_timeout() {
	local sch_me=job_set_timeout \
		IFS=" "$'\t'$'\n' \
		sch_val="${2}" \
		sch_ns \
		sch_job_id="${1}"

	sch_get_ns sch_ns "${sch_me}" &&
	sch_check_name "job ID" "${sch_job_id}" "${sch_me}" || return 1

	sch_is_uint "${sch_val}" && [ "${sch_val}" -ge 1 ] || {
		sch_fail_msg "${sch_me}: invalid timeout value '${sch_val}' for job '${sch_job_id}'."
		return 1
	}
	sch_tr_leading sch_val "${sch_val}" "0"
	export -n "SCH_TIMEOUT_JOB_${sch_ns}${sch_job_id}=${sch_val}"
}

jobs_abort() {
	local \
		me=jobs_abort \
		IFS=" "$'\t'$'\n' \
		job_id job_pid kill_pids

	# guard against calls from DO_JOB_CB, SCHED_FINALIZE_CB or outside the scheduler
	sch_in_main_process "${me}" "${@}" || return 1

	for job_id in "${@}"; do
		sch_check_name "job ID" "${job_id}" "${me}" || continue
		sch_is_included "${job_id}" "${SCH_JOB_IDS}" || { sch_fail_msg "${me}: unknown job ID '${job_id}'."; continue; }
		# Not dispatched yet: stays undispatched rather than aborted - outcome matters more than cause
		if sch_is_included "${job_id}" "${SCH_PENDING_IDS}"; then
			sch_rm_elem SCH_PENDING_IDS "${job_id}" "${SCH_PENDING_IDS}"
		elif sch_pid_of_id job_pid "${job_id}" "${SCH_RUNNING}"; then
			sch_rm_elem SCH_RUNNING "${job_pid}:${job_id}" "${SCH_RUNNING}"
			[ -n "${SCH_DEADLINES}" ] &&
				sch_deadline_rm_id SCH_DEADLINES "${job_id}" "${SCH_DEADLINES}"
			SCH_RUNNING_JOBS_CNT=$((SCH_RUNNING_JOBS_CNT - 1))
			sch_append SCH_UNREAPED "${job_pid}:${job_id}"
			sch_append SCH_ABORTED_IDS "${job_id}"
			[ -n "${JOB_TERM_CB}" ] && sch_append kill_pids "${job_pid}"
		fi
	done
	[ -n "${kill_pids}" ] || return 0
	sch_term_run ${kill_pids}
	:
}
