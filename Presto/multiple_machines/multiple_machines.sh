#!/bin/bash
#================================================================
#%
#% SYNOPSIS
#+    ${SCRIPT_NAME} [-hv] [-o[file]] args ...
#%
#% DESCRIPTION
#%    Script to run the TPC-H benchmark on Presto. 
#%    You can specify three different deployment strategies (WIM, WIN or WIC), 
#%    three different data placement policies (FT, INT or MEM), 
#%    number of workers and number of cores per worker. 
#%
#% OPTIONS
#%    -o [file], --output=[file]    Set log file (default=/dev/null)
#%                                  use DEFAULT keyword to autoname file
#%                                  The default value is /dev/null.
#%    -w, --coordinator-worker      Mandatory: yes or no, set the coordinator-worker instance in this machine.
#%    -n, --number                  Mandatory: machine number.
#%    -a, --coordinator-address     Mandatory: coordinator-worker instance IP address and port (format ip_address:port).
#%    -l, --local-ip                Mandatory: local IP address.
#%    -c, --cluster-size            Mandatory: total cluster size for the test.
#%    -s, --scale-factor            TPC-H scale factor (default=100).
#%    -t, --timelog                 Add timestamp to log ("+%y/%m/%d@%H:%M:%S")
#%    -x, --ignorelock              Ignore if lock file exists
#%    -h, --help                    Print this help
#%    -v, --version                 Print script information
#%
#% EXAMPLES
#%    ${SCRIPT_NAME} -o DEFAULT -t -m WIN -s 100
#%
#================================================================
#-
#- IMPLEMENTATION
#-    version         ${SCRIPT_NAME} 0.0.1
#-    author          Alessandro Fogli <a.fogli18@imperial.ac.uk>
#-

trap 'error "${SCRIPT_NAME}: FATAL ERROR at $(date "+%HH%M") (${SECONDS}s): Interrupt signal intercepted! Exiting now..."
	2>&1 | tee -a ${fileLog:-/dev/null} >&2 ;
	exit 99;' INT QUIT TERM
trap 'cleanup' EXIT

#============================
#  FUNCTIONS
#============================

	#== fecho function ==#
fecho() {
	_Type=${1} ; shift ;
	[[ ${SCRIPT_TIMELOG_FLAG:-0} -ne 0 ]] && printf "$( date ${SCRIPT_TIMELOG_FORMAT} ) "
	echo "${*}"
	if [[ "${_Type}" = CAT ]]; then
		_Tag=""
		[[ "$1" == \[*\] ]] && _Tag="${_Tag} ${1}"
		if [[ ${SCRIPT_TIMELOG_FLAG:-0} -eq 0 ]]; then
			cat -un - | awk '$0="'"${_Tag}"' "$0; fflush();' ;
		elif [[ "${GNU_AWK_FLAG}" ]]; then # fast - compatible linux
			cat -un - | awk -v tformat="${SCRIPT_TIMELOG_FORMAT#+} " '$0=strftime(tformat)"'"${_Tag}"' "$0; fflush();' ;
		#elif [[ "${PERL_FLAG}" ]]; then # fast - if perl installed
		#	cat -un - | perl -pne 'use POSIX qw(strftime); print strftime "'${SCRIPT_TIMELOG_FORMAT}' ' "${_Tag}"' ", gmtime();'
		else # average speed but resource intensive- compatible unix/linux
			cat -un - | while read LINE; do \
				[[ ${OLDSECONDS:=$(( ${SECONDS}-1 ))} -lt ${SECONDS} ]] && OLDSECONDS=$(( ${SECONDS}+1 )) \
				&& TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) "; printf "${TSTAMP}${_Tag} ${LINE}\n"; \
			done 
		fi
	fi
}

	#== custom function ==#
check_cre_file() {
	_File=${1}
	_Script_Func_name="${SCRIPT_NAME}: check_cre_file"
	[[ "x${_File}" = "x" ]] && error "${_Script_Func_name}: No parameter" && return 1
	[[ "${_File}" = "/dev/null" ]] && return 0
	[[ -e ${_File} ]] && error "${_Script_Func_name}: ${_File}: File already exists" && return 2
	touch ${_File} 1>/dev/null 2>&1
	[[ $? -ne 0 ]] && error "${_Script_Func_name}: ${_File}: Cannot create file" && return 3
	rm -f ${_File} 1>/dev/null 2>&1
	[[ $? -ne 0 ]] && error "${_Script_Func_name}: ${_File}: Cannot delete file" && return 4
	return 0
}

	#== error management functions ==#
info() { fecho INF "${*}"; }

warning() { fecho WRN "WARNING: ${*}" 1>&2 ; }

error() { fecho ERR "ERROR: ${*}" 1>&2 ; }

debug() { [[ ${flagDbg} -ne 0 ]] && fecho DBG "DEBUG: ${*}" 1>&2; }


tag() { [[ "x$1" == "x--eol" ]] && awk '$0=$0" ['$2']"; fflush();' || awk '$0="['$1'] "$0; fflush();' ; }

infotitle() { _txt="# ${*} #"; _txt2="#$( echo " ${*} " | tr '[:print:]' '#' )#" ;
	info ""; info "$_txt2"; info "$_txt"; info "$_txt2"; info "";
}

	#== startup and finish functions ==#
cleanup() { 
	stop_coordinator_and_workers
	remove_workers_directory
	[[ flagScriptLock -ne 0 ]] && [[ -e "${SCRIPT_DIR_LOCK}" ]] && rm -fr ${SCRIPT_DIR_LOCK}; }

scriptstart() { trap 'kill -TERM ${$}; exit 99;' TERM
	info "${SCRIPT_NAME}: Start $(date "+%y/%m/%d@%H:%M:%S") with pid ${EXEC_ID} by ${USER}@${HOSTNAME}:${PWD}"\
		$( [[ ${flagOptLog} -eq 1 ]] && echo " (LOG: ${fileLog})" || echo " (NOLOG)" );
	flagMainScriptStart=1 && ipcf_save "PRG" "${EXEC_ID}" "${FULL_COMMAND}"
}

scriptfinish() {
	kill $(jobs -p) 1>/dev/null 2>&1 && warning "${SCRIPT_NAME}: Some bg jobs have been killed" ;
	[[ ${flagOptLog} -eq 1 ]] && info "${SCRIPT_NAME}: LOG file can be found here: ${fileLog}" ;
	countErr="$( ipcf_count ERR )" ; countWrn="$( ipcf_count WRN )" ;
	[[ $rc -eq 0 ]] && endType="INF" || endType="ERR";
	fecho ${endType} "${SCRIPT_NAME}: Finished$([[ $countErr -ne 0 ]] && echo " with ERROR(S)") at $(date "+%HH%M") (Time=${SECONDS}s, Error=${countErr}, Warning=${countWrn}, RC=$rc).";
	exit $rc ; }

	#== usage functions ==#
usage() { printf "Usage: "; scriptinfo usg ; }

usagefull() { scriptinfo ful ; }

scriptinfo() { headFilter="^#-"
	[[ "$1" = "usg" ]] && headFilter="^#+"
	[[ "$1" = "ful" ]] && headFilter="^#[%+]"
	[[ "$1" = "ver" ]] && headFilter="^#-"
	head -${SCRIPT_HEADSIZE:-99} ${0} | grep -e "${headFilter}" | sed -e "s/${headFilter}//g" -e "s/\${SCRIPT_NAME}/${SCRIPT_NAME}/g"; }

	#== Inter Process Communication File functions (ipcf) ==#
#== Create semaphore on fd 101 #==  Not use anymore ==# 
# ipcf_cre_sem() { SCRIPT_SEM_RC="${SCRIPT_DIR_LOCK}/pipe-rc-${$}";
# 	mkfifo "${SCRIPT_SEM_RC}" && exec 101<>"${SCRIPT_SEM_RC}" && rm -f "${SCRIPT_SEM_RC}"; }
#==  Use normal file instead for persistency ==# 
ipcf_save() { # Usage: ipcf_save <TYPE> <ID> <DATA>
	_Line="${1}|${2}"
	shift 2 && _Line+="|${*}"
	[[ "${*}" == "${_Line}" ]] \
		&& warning "ipcf_save: Failed: Wrong format: ${*}" && return 1
	echo "${_Line}" >> ${ipcf_file} ;
	[[ "${?}" -ne 0 ]] \
		&& warning "ipcf_save: Failed: Writing error to ${ipcf_file}: ${*}" && return 2
	return 0 ;
}

ipcf_load() { # Usage: ipcf_load <TAG> <ID> ; Return: $ipcf_return ;
	ipcf_return=""
	_Line="$( grep "^${1}${ipcf_IFS}${2}" ${ipcf_file} | tail -1 )" ;
	[[ "$( echo "${_Line}" | wc -w )" -eq 0 ]] \
		&& warning "ipcf_load: Failed: No data found: ${1} ${2}" && return 1 ;
	IFS="${ipcf_IFS}" read ipcftype ipcfid ipcfdata <<< $(echo "${_Line}") ;
	[[ "$( echo "${ipcfdata}" | wc -w )" -eq 0 ]] \
		&& warning "ipcf_load: Failed: Cannot parse - wrong format: ${1} ${2}" && return 2 ;
	ipcf_return="$ipcfdata" && echo "${ipcf_return}" && return 0 ;
}

ipcf_count() { # Usage: ipcf_count <TAG> [<ID>] ; Return: $ipcf_return ;
	ipcf_return="$( grep "^${1}${ipcf_IFS}${2:-0}" ${ipcf_file} | wc -l )";
	echo ${ipcf_return}; return 0;
}

ipcf_save_rc() { rc=$? && ipcf_return="${rc}"; ipcf_save "RC_" "${1:-0}" "${rc}"; return $? ; }

ipcf_load_rc() { # Usage: ipcf_load_rc [<ID>] ; Return: $ipcf_return ;
	ipcf_return=""; ipcfdata=""; ipcf_load "RC_" "${1:-0}" >/dev/null ;
	[[ "${?}" -ne 0 ]] && warning "ipcf_load_rc: Failed: No rc found: ${1:-0}" && return 1 ;
	[[ ! "${ipcfdata}" =~ ^-?[0-9]+$ ]] \
		&& warning "ipcf_load_rc: Failed: Not a Number (ipcfdata=${ipcfdata}): ${1:-0}" && return 2 ;
	rc="${ipcfdata}" && ipcf_return="${rc}" && echo "${rc}"; return 0 ;
}

ipcf_save_cmd() { # Usage: ipcf_save_cmd <CMD> ; Return: $ipcf_return ;
	ipcf_return=""; cmd_id="" ;
	_cpid="$(exec sh -c 'echo $PPID')"; _NewId="$( printf '%.5d' ${_cpid:-${RANDOM}} )" ;
	ipcf_save "CMD" "${_NewId}" "${*}" ;
	[[ "${?}" -ne 0 ]] && warning "ipcf_save_cmd: Failed: ${1:-0}" && return 1 ;
	cmd_id="${_NewId}" && ipcf_return="${cmd_id}" && echo "${ipcf_return}"; return 0;
}

ipcf_load_cmd() { # Usage: ipcf_load_cmd <ID> ; Return: $ipcf_return ;
	ipcf_return=""; cmd="" ;
	if [[ "x${1}"  =~ ^x[0]*$ ]]; then ipcfdata="0" ;
	else
		ipcfdata=""; ipcf_load "CMD" "${1:-0}" >/dev/null ;
		[[ "${?}" -ne 0 ]] && warning "ipcf_load_cmd: Failed: No cmd found: ${1:-0}" && return 1 ;
	fi
	cmd="${ipcfdata}" && ipcf_return="${ipcfdata}" && echo "${ipcf_return}"; return 0 ;
}

ipcf_assert_cmd() { # Usage: ipcf_assert_cmd [<ID>] ;
	cmd=""; rc=""; msg="";
	ipcf_load_cmd ${1:-0} >/dev/null
	[[ "${?}" -ne 0 ]] && warning "ipcf_assert_cmd: Failed: No cmd found: ${1:-0}" && return 1 ;
	ipcf_load_rc ${1:-0} >/dev/null
	[[ "${?}" -ne 0 ]] && warning "ipcf_assert_cmd: Failed: No rc found: ${1:-0}" && return 2 ;
	msg="[${1:-0}] Command succeeded [OK] (rc=${rc}): ${cmd} " ;
	[[ $rc -ne 0 ]] && error "$(echo ${msg} | sed -e "s/succeeded \[OK\]/failed [KO]/1")" || info "${msg}" ;
	return $rc ;
}

	#== exec_cmd function ==#
exec_cmd() { # Usage: exec_cmd <CMD> ;
	cmd_id="" ; ipcf_save_cmd "${*}" >/dev/null || return 1 ;
	{ {
		eval ${*}
		ipcf_save_rc ${cmd_id} ;
	} 2>&1 1>&3 | tag STDERR 1>&2 ; } 3>&1 2>&1 | fecho CAT "[${cmd_id}]" "${*}"
	ipcf_assert_cmd ${cmd_id}
	return $rc ;
}

wait_cmd() { # Usage: wait_cmd [<TIMEOUT>] ;
	_num_timer=0 ; _num_fail_cmd=0 ; _num_run_jobs=0 ;
	_tmp_txt="" ; _tmp_rc=0 ; _flag_nokill=0 ;
	_cmd_id_fail="" ; _cmd_id_check="" ; _cmd_id_list="" ;
	_tmp_grep_bash="exec_cmd" ;
	[[ "x$BASH" == "x" ]] && _tmp_grep_bash=""
	sleep 1
	[[ "x$1" == "x--nokill" ]] && _flag_nokill=1 && shift
	_num_timeout=${1:-32768} ;
	_num_start_line="$( grep -sn "^CHK${ipcf_IFS}" ${ipcf_file} | tail -1 | cut -f1 -d: )"
	_cmd_id_list="$( tail -n +${_num_start_line:-0} ${ipcf_file} | grep "^CMD${ipcf_IFS}" | cut -d"${ipcf_IFS}" -f2 | xargs ) " ;
	while true; do
		# Retrieve all RC from ipcf_file to Array
		unset -v _cmd_rc_a
		[[ "x$BASH" == "x" ]] && typeset -A _cmd_rc_a || declare -A _cmd_rc_a #Other: ps -ocomm= -q $$
		eval $( tail -n +${_num_start_line:-0} ${ipcf_file} | grep "^RC_${ipcf_IFS}" | cut -d"${ipcf_IFS}" -f2,3 | xargs | sed "s/\([0-9]*\)|\([0-9]*\)/_cmd_rc_a[\1]=\2\;/g" ) ;
		
		#debug "wait_cmd: \$_cmd_id_list='$_cmd_id_list' ; \${_cmd_rc_a[@]}=${_cmd_rc_a[@]}; \${!_cmd_rc_a[@]}=${!_cmd_rc_a[@]};"
		
		for __cmd_id in ${_cmd_id_list}; do
			#_tmp_rc="$(ipcf_load_rc ${__cmd_id} 2>/dev/null)"
			if [[ "${_cmd_rc_a[$__cmd_id]}" ]]; then
				_cmd_id_list=${_cmd_id_list/"${__cmd_id} "}
				_cmd_id_check+="${__cmd_id} "
				[[ "${_cmd_rc_a[$__cmd_id]}" -ne 0 ]] && _cmd_id_fail+="${__cmd_id} "
			fi
		done
		
		_num_run_jobs="$( jobs -l | grep -i "Running.*${_tmp_grep_bash}" | wc -l )"
		[[ $((_num_timer%5)) -eq 0 ]] && info "wait_cmd: Waiting for ${_num_run_jobs} bg jobs to finish: $( echo ${_cmd_id_list} | sed -e "s/\([0-9]*\)/[\1]/g" ) (elapsed: ${_num_timer}s)"
		((++_num_timer))
		if [[ $((_num_timer%_num_timeout)) -eq 0 ]]; then
			[[ "$_flag_nokill" -eq 0 ]] \
				&& kill $( jobs -l | grep -i "Running.*${_tmp_grep_bash}" | tr -d '+-' | tr -s ' ' | cut -d" " -f2 | xargs ) 1>/dev/null 2>&1 \
				&& _tmp_txt="- killed ${_num_run_jobs} bg job(s)" || _tmp_txt=""
			warning "wait_cmd: Time out reached (${_num_timer}s) ${_tmp_txt} - exit function"
			return 255
		fi
		
		[[ "$( echo "${_cmd_id_list}" | wc -w )" -eq 0 ]] && break
		
		[[ "${_num_run_jobs}" -eq 0 ]] \
			&& warning "wait_cmd: No more running jobs but there is still cmd_id left: ${_cmd_id_list}" \
			&& _cmd_id_fail+="${_cmd_id_list} " && break
		sleep 1;
	done
	
	_num_run_jobs="$( jobs -l | grep -i "Running.*${_tmp_grep_bash}" | wc -l )"
	[[ ${_num_run_jobs} -gt 1 ]] \
		&& warning "wait_cmd: No more cmd but Still have running jobs: $( jobs -p | xargs echo )"
	
	_num_fail_cmd="$( echo ${_cmd_id_fail} | wc -w )"
	[[ ${_num_fail_cmd} -eq 0 ]] && info "wait_cmd: All cmd_id succeeded" \
		|| warning "wait_cmd: ${_num_fail_cmd} cmd_id failed: $( echo ${_cmd_id_fail} | sed -e "s/\([0-9]*\)/[\1]/g" )"
	
	ipcf_save "CHK" "0" "${_cmd_id_check}"
	
	return $_num_fail_cmd
}

assert_rc() { [[ $rc -ne 0 ]] && error "${*} (RC=$rc)"; return $rc; }

print_message_with_date() {
	TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
	echo -n "${TSTAMP} ${1}"
}

print_message_with_date_and_newline() {
	TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
	echo "${TSTAMP} ${1}"
}

# display error if the script is run as root user
check_user_not_root() {
	if [[ $USER == "root" ]]; then
		error "This script must not be run as root!"
		exit 1;
	fi
}

get_number_of_NUMA_nodes() {
	NUMACTL_OUT=$(numactl --hardware)

	TEMP=${NUMACTL_OUT##available: }
	NUM_NUMA_NODES=${TEMP::1}

	if [[ $NUM_NUMA_NODES -le 1 ]]; then
		error 'You need a multisocket system to run this benchmark:'
		error 'Number of NUMA nodes: 1'
		exit 1
	fi

	NUMACORES=$(grep ^cpu\\scores /proc/cpuinfo | uniq |  awk '{print $4}')

	TOTAL_CORES=$(($NUMACORES*$NUM_NUMA_NODES))

	create_numactl_array

	if [[ $CORES_PER_WORKER -eq 0 ]]; then
		if [[ $MODE == "WIN" || ${MODE} == 'SPMWIN' ]]; then 
			CORES_PER_WORKER=$NUMACORES
		elif [[ $MODE == "WIM" ]]; then
			CORES_PER_WORKER=$TOTAL_CORES
		else
			CORES_PER_WORKER=1
		fi
	fi
}

get_jvm_and_nodes_mem() {
	PHYMEM=$(awk -F":" '$1~/MemTotal/{print $2}' /proc/meminfo )
	PHYMEM=${PHYMEM% kB}
	# Change amount of memory for JVM (JVM_MEM) or memory per Presto nodes (PRESTO_TOTAL_MEM)
	JVM_MEM=$(echo "scale=0; ${PHYMEM} / 1.17" | bc)
	#PRESTO_TOTAL_MEM=$(echo "scale=0; ${JVM_MEM} / 1500" | bc)
	PRESTO_TOTAL_MEM=$(echo "scale=0; ${JVM_MEM} / 1500" | bc)
	# Set amount of memory for each node based on:
	#  Domain type and
	#  Number of workers per domain type  
	if [[ ${MODE} == 'WIN' || ${MODE} == 'SPMWIN' ]]; then
		PRESTO_NODE_MEM=$(echo "scale=0; ${PRESTO_TOTAL_MEM} / ${NUM_NUMA_NODES}" | bc)
		PRESTO_NODE_MEM=$(echo "scale=0; ${PRESTO_NODE_MEM} / ${WORKERS_PER_DOMAIN}" | bc)
	elif [[ $MODE == 'WIM' ]]; then
		PRESTO_NODE_MEM=$PRESTO_TOTAL_MEM
		PRESTO_NODE_MEM=$(echo "scale=0; ${PRESTO_NODE_MEM} / ${WORKERS_PER_DOMAIN}" | bc)
	elif [[ $MODE == 'WIC' ]]; then
		PRESTO_NODE_MEM=$(echo "scale=0; ${PRESTO_TOTAL_MEM} / ${NUM_NUMA_NODES}" | bc)
		PRESTO_NODE_MEM=$(echo "scale=0; ${PRESTO_NODE_MEM} / ${NUMACORES}" | bc)
		PRESTO_NODE_MEM=$(echo "scale=0; ${PRESTO_NODE_MEM} / ${WORKERS_PER_DOMAIN}" | bc)
		fi
}

get_total_workers() {
	if [[ ${MODE} == 'WIM' ]]; then
		TOTAL_WORKERS=${WORKERS_PER_DOMAIN}
	elif [[ $MODE == 'WIN' ]]; then
		TOTAL_WORKERS=$(( ${WORKERS_PER_DOMAIN}*${NUM_NUMA_NODES} ))
	elif [[ $MODE == 'WIC' ]]; then
		TOTAL_WORKERS=$(( ${WORKERS_PER_DOMAIN}*${NUM_NUMA_NODES}*${NUMACORES} ))
	fi
}

create_workers_directory() {
	if [[ $COORDINATOR_FLAG == 'yes' ]]; then
		for ((i = 1; i < $TOTAL_WORKERS; i += 1)) ; do
			exec_cmd "cp -r ../presto-worker-1 presto-worker-${i};"
		done
	else
		for ((i = 1; i <= $TOTAL_WORKERS; i += 1)) ; do
			exec_cmd "cp -r ../presto-worker-1 presto-worker-${i};"
		done
	fi
} 

remove_workers_directory() {

	echo ''
	echo 'REMOVING DIRECTORIES!'
	echo ''
	
	exec_cmd "rm -rf presto-worker-*;"

	if [[ $COORDINATOR_FLAG == 'yes' ]]; then
		rm -rf ${SCRIPT_DIR}/presto-worker-coordinator/data/java_pid*
	fi
} 

get_port() {

		CANDIDATE=$(comm -23 <(seq 49152 65535 | sort) <(ss -tan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1)
}

set_worker_config_files() {

	if [[ $COORDINATOR_FLAG == 'yes' ]]; then

		for ((i = 1; i < $TOTAL_WORKERS; i += 1)) ; do
			rm  -rf ${SCRIPT_DIR}/presto-worker-${i}/etc/jvm.config

			echo '-server' > "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"

			XMX=$(($JVM_MEM / $TOTAL_WORKERS))

			#XMX=$JVM_MEM

			echo "-Xmx${XMX}K" >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+UseG1GC' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:G1HeapRegionSize=32M' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+UseGCOverheadLimit' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+ExplicitGCInvokesConcurrent' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+HeapDumpOnOutOfMemoryError' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+ExitOnOutOfMemoryError' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-Djdk.attach.allowAttachSelf=true' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"

			rm  -rf ${SCRIPT_DIR}/presto-worker-${i}/etc/config.properties;
			rm  -rf ${SCRIPT_DIR}/presto-worker-${i}/etc/node.properties;

			get_port
			WORKER_PORT=$CANDIDATE

			#Add config properties
			echo "coordinator=false" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "http-server.http.port=$WORKER_PORT" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "query.max-memory=${PRESTO_TOTAL_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "query.max-memory-per-node=${PRESTO_NODE_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "query.max-total-memory-per-node=${PRESTO_NODE_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "discovery.uri=http://$COORD_IP:$COORD_PORT" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "node.internal-address=${LOCAL_IP}" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"


			#Add node properties
			echo "node.environment=demo" >> "${SCRIPT_DIR}/presto-worker-$i/etc/node.properties"
			echo "node.id=$((${i}*$MACHINE_NUMBER))" >> "${SCRIPT_DIR}/presto-worker-$i/etc/node.properties"
			echo "node.data-dir=${SCRIPT_DIR}/presto-worker-$i/data" >> "${SCRIPT_DIR}/presto-worker-$i/etc/node.properties"
		done

	else

		for ((i = 1; i <= $TOTAL_WORKERS; i += 1)) ; do
			rm  -rf ${SCRIPT_DIR}/presto-worker-${i}/etc/jvm.config

			echo '-server' > "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"

			XMX=$(($JVM_MEM / $TOTAL_WORKERS))

			#XMX=$JVM_MEM

			echo "-Xmx${XMX}K" >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+UseG1GC' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:G1HeapRegionSize=32M' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+UseGCOverheadLimit' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+ExplicitGCInvokesConcurrent' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+HeapDumpOnOutOfMemoryError' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-XX:+ExitOnOutOfMemoryError' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"
			echo '-Djdk.attach.allowAttachSelf=true' >> "${SCRIPT_DIR}/presto-worker-$i/etc/jvm.config"

			rm  -rf ${SCRIPT_DIR}/presto-worker-${i}/etc/config.properties;
			rm  -rf ${SCRIPT_DIR}/presto-worker-${i}/etc/node.properties;

			get_port
			WORKER_PORT=$CANDIDATE

			#Add config properties
			echo "coordinator=false" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "http-server.http.port=$WORKER_PORT" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "query.max-memory=${PRESTO_TOTAL_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "query.max-memory-per-node=${PRESTO_NODE_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "query.max-total-memory-per-node=${PRESTO_NODE_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "discovery.uri=http://$COORD_IP:$COORD_PORT" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"
			echo "node.internal-address=${LOCAL_IP}" >> "${SCRIPT_DIR}/presto-worker-$i/etc/config.properties"


			#Add node properties
			echo "node.environment=demo" >> "${SCRIPT_DIR}/presto-worker-$i/etc/node.properties"
			echo "node.id=$((${i}*$MACHINE_NUMBER))" >> "${SCRIPT_DIR}/presto-worker-$i/etc/node.properties"
			echo "node.data-dir=${SCRIPT_DIR}/presto-worker-$i/data" >> "${SCRIPT_DIR}/presto-worker-$i/etc/node.properties"
		done

	fi
}

set_coordinator_config_file() {

	cp -r ../presto-worker-coordinator .

	rm  -rf ${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config

	XMX=$(($JVM_MEM / $TOTAL_WORKERS))

	echo "-Xmx${XMX}K" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-XX:+UseG1GC' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-XX:G1HeapRegionSize=32M' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-XX:+UseGCOverheadLimit' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-XX:+ExplicitGCInvokesConcurrent' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-XX:+HeapDumpOnOutOfMemoryError' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-XX:+ExitOnOutOfMemoryError' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"
	echo '-Djdk.attach.allowAttachSelf=true' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/jvm.config"


	exec_cmd "rm ${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties;"

	echo "coordinator=true" > "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "node-scheduler.include-coordinator=true" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "http-server.http.port=$COORD_PORT" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "query.max-memory=${PRESTO_TOTAL_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "query.max-memory-per-node=${PRESTO_NODE_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "query.max-total-memory-per-node=${PRESTO_NODE_MEM}MB" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo 'discovery-server.enabled=true' >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "discovery.uri=http://${COORD_IP}:$COORD_PORT" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"
	echo "node.internal-address=${LOCAL_IP}" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/config.properties"

	rm  -rf ${SCRIPT_DIR}/presto-worker-coordinator/etc/node.properties;

	#Add node properties
	echo "node.environment=demo" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/node.properties"
	echo "node.id=0" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/node.properties"
	echo "node.data-dir=${SCRIPT_DIR}/presto-worker-coordinator/data" >> "${SCRIPT_DIR}/presto-worker-coordinator/etc/node.properties"
}


create_numactl_array() {
	NUMACTL_ARRAY=()
	for ((i = 0; i < $NUM_NUMA_NODES; i += 1)) ; do
		NUMACTL_OUT=$(numactl --hardware)
		NUMACTL_OUT=${NUMACTL_OUT%node ${i} size:*}
		NUMACTL_OUT=${NUMACTL_OUT##*node ${i} cpus: }
		NUMACTL_ARRAY+=("$NUMACTL_OUT")
	done
}

start_coordinator_and_workers() {
	if [[ ($MODE == 'WIN') ]]; then
		
		for ((j = 0; j < $WORKERS_PER_DOMAIN; j += 1)) ; do
			p=0
			for ((i = 0; i < $NUM_NUMA_NODES; i += 1)) ; do
				p=0
				p=$(($(($p+$j*$CORES_PER_WORKER))%NUMACORES))
				values="${NUMACTL_ARRAY[$i]}"

				core="$(cut -d' ' -f$(($p+1)) <<<"$values")"

				COMMAND="numactl --physcpubind=$core"

				p=$(($p+1))
				t=1
				while true; do
					if [[  $t -eq $CORES_PER_WORKER ]]; then
						break
					else
						values="${NUMACTL_ARRAY[$i]}"
						k=$(($(($p%NUMACORES))+1))

						core="$(cut -d' ' -f$k <<<"$values")"
						COMMAND="$COMMAND,$core"
					fi
					t=$(($t+1))
					p=$(($p+1))
				done

				if [[ $POLICY == "INT" ]]; then
					COMMAND="${COMMAND} -i 0-$(($NUM_NUMA_NODES-1))"
				elif [[ $POLICY == "MEM" ]]; then
					COMMAND="${COMMAND} -m $(($i%$NUM_NUMA_NODES))"
				fi

				if [[ $i -eq 0 ]] && [[ $j -eq 0 ]] && [[ $COORDINATOR_FLAG == 'yes' ]]; then
					COMMAND="$COMMAND ${SCRIPT_DIR}/presto-worker-coordinator/bin/launcher start"
					TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
					echo "${TSTAMP} ${COMMAND}"
					TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
					echo -n "${TSTAMP}"
					$COMMAND
				else

					t=$((i))
					t=$((t+j*$NUM_NUMA_NODES))
					if [[ $COORDINATOR_FLAG == 'no' ]]; then
						t=$(($t+1))
					fi
					COMMAND="$COMMAND ${SCRIPT_DIR}/presto-worker-$t/bin/launcher start"
					TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
					echo "${TSTAMP} ${COMMAND}"
					TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
					echo -n "${TSTAMP}"
					$COMMAND
				fi
			done
		done

	elif [[ ($MODE == 'WIM') ]]; then

		CORE_LIST=""
		#for ((i = 0; i < $TOTAL_CORES; i += 1)) ; do
		#	CORE_LIST="${CORE_LIST}${i} "
		#done
		for i in `seq 0 $((NUM_NUMA_NODES-1))`
		do
			for j in  `seq 0 $(($NUMACORES-1))`
			do
				ncore=$(($j*$NUM_NUMA_NODES+$i))
				CORE_LIST="${CORE_LIST}${ncore} "
			done
		done

		WORKER_CORE_ARRAY=()
		for ((i = 0; i < $TOTAL_WORKERS; i += 1)) ; do
			WORKER_CORE_ARRAY+=("")
		done

		c=0
		if [[ $(($TOTAL_WORKERS%2)) -eq 0 ]]; then
			for ((i = 0; i < $TOTAL_WORKERS; i += 1)) ; do
				for ((j = 0; j < $CORES_PER_WORKER; j += 1)) ; do
					core="$(cut -d' ' -f$(($(($c%$TOTAL_CORES))+1)) <<<"$CORE_LIST")"
					WORKER_CORE_ARRAY[$i]="${WORKER_CORE_ARRAY[$i]}$core,"
					c=$(($c+1))
				done
			done
		else	
			for ((j = 0; j < $CORES_PER_WORKER; j += 1)) ; do
				for ((i = 0; i < $TOTAL_WORKERS; i += 1)) ; do
					core="$(cut -d' ' -f$(($(($c%$TOTAL_CORES))+1)) <<<"$CORE_LIST")"
					WORKER_CORE_ARRAY[$i]="${WORKER_CORE_ARRAY[$i]}$core," 
					c=$(($c+1))
				done
			done
		fi

		for ((i = 0; i < $TOTAL_WORKERS; i += 1)) ; do
			if [[ $POLICY == "FT" ]]; then
				COMMAND="numactl --physcpubind=${WORKER_CORE_ARRAY[$i]}"
				COMMAND=${COMMAND::-1}
			elif [[ $POLICY == "INT" ]]; then
				COMMAND="numactl --physcpubind=${WORKER_CORE_ARRAY[$i]}"
				COMMAND=${COMMAND::-1}
				COMMAND="${COMMAND} -i 0-$(($NUM_NUMA_NODES-1))"
			else
				COMMAND="numactl --physcpubind=${WORKER_CORE_ARRAY[$i]}"
				COMMAND=${COMMAND::-1}
				COMMAND="${COMMAND} -m 0-$(($NUM_NUMA_NODES-1))"
			fi

			if [[ $i -eq 0 ]] && [[ $COORDINATOR_FLAG == 'yes' ]]; then
				COMMAND="$COMMAND ${SCRIPT_DIR}/presto-worker-coordinator/bin/launcher start"
				TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
				echo "${TSTAMP} ${COMMAND}"
				TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
				echo -n "${TSTAMP}"
				$COMMAND

			else
				t=$((i))
				if [[ $COORDINATOR_FLAG == 'no' ]]; then
					t=$(($t+1))
				fi
				COMMAND="$COMMAND ${SCRIPT_DIR}/presto-worker-$t/bin/launcher start"
				TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
				echo "${TSTAMP} ${COMMAND}"
				TSTAMP="$( date ${SCRIPT_TIMELOG_FORMAT} ) ";
				echo -n "${TSTAMP}"
				$COMMAND
			fi
		done

	fi
}


stop_coordinator_and_workers() {


        NUMACTL_OUT=$(numactl --hardware)

        TEMP=${NUMACTL_OUT##available: }
        NUM_NUMA_NODES=${TEMP::1}

        if [[ ${MODE} == 'WIM' ]]; then
                TOTAL_WORKERS=1
        elif [[ $MODE == 'WIN' ]]; then
                TOTAL_WORKERS=${NUM_NUMA_NODES}
        fi

        for ((i = 0; i < $TOTAL_WORKERS; i += 1)) ; do
                if [[ $i -eq 0 ]] && [[ $COORDINATOR_FLAG == 'yes' ]]; then
                        COMMAND="${SCRIPT_DIR}/presto-worker-coordinator/bin/launcher stop"
                        echo "$COMMAND"
                        eval "$COMMAND"
                else   
                        if [[ $COORDINATOR_FLAG == 'yes' ]]; then
                                COMMAND="${SCRIPT_DIR}/presto-worker-${i}/bin/launcher stop"
                                echo "$COMMAND"
                                eval "$COMMAND"
                        else
                                COMMAND="${SCRIPT_DIR}/presto-worker-$((${i}+1))/bin/launcher stop"
                                echo "$COMMAND"
                                eval "$COMMAND"

                        fi
                fi
        done

}

run_tpch_benchmark() {
	if [[ ($QUERY == '') ]]; then
		QUERY="1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22"
	fi

	for q in $(echo $QUERY | sed "s/,/ /g")
	do
		print_message_with_date_and_newline "Running Query $q..."
		for ((i = 0; i < 10; i += 1)) ; do
			{ time ${SCRIPT_DIR}/../presto --server $COORD_IP:$COORD_PORT --catalog tpch --schema sf$SCALE_FACTOR --file ${SCRIPT_DIR}/../sql-tpch/q$q.sql ; } &>> $OUT_DIR/Q${q}_runtime.txt
		done
	done
}

#============================
#  FILES AND VARIABLES
#============================

	#== general variables ==#
SCRIPT_NAME="$(basename ${0})" # scriptname without path
SCRIPT_DIR="$( cd $(dirname "$0") && pwd )" # script directory
SCRIPT_FULLPATH="${SCRIPT_DIR}/${SCRIPT_NAME}"

SCRIPT_ID="$(scriptinfo | grep script_id | tr -s ' ' | cut -d' ' -f3)"
SCRIPT_HEADSIZE=$(grep -sn "^# END_OF_HEADER" ${0} | head -1 | cut -f1 -d:)

SCRIPT_UNIQ="${SCRIPT_NAME%.*}.${SCRIPT_ID}.${HOSTNAME%%.*}"
SCRIPT_UNIQ_DATED="${SCRIPT_UNIQ}.$(date "+%y%m%d%H%M%S").${$}"

SCRIPT_DIR_TEMP="/tmp" # Make sure temporary folder is RW
SCRIPT_DIR_LOCK="${SCRIPT_DIR_TEMP}/${SCRIPT_UNIQ}.lock"

SCRIPT_TIMELOG_FLAG=0
SCRIPT_TIMELOG_FORMAT="+%Y/%m/%d@%H:%M:%S"
SCRIPT_TIMELOG_FORMAT_PERL="$(echo ${SCRIPT_TIMELOG_FORMAT#+} | sed 's/%y/%Y/g')"

HOSTNAME="$(hostname)"
FULL_COMMAND="${0} $*"
EXEC_DATE=$(date "+%y%m%d%H%M%S")
EXEC_ID=${$}
GNU_AWK_FLAG="$(awk --version 2>/dev/null | head -1 | grep GNU)"
PERL_FLAG="$(perl -v 1>/dev/null 2>&1 && echo 1)"

	#== Test variables ==#
MODE="WIN"
POLICY="FT"
PHYMEM=0
WORKERS_PER_DOMAIN=1
SCALE_FACTOR=100
CORES_PER_WORKER=0
TOTAL_WORKERS=0
TOTAL_CORES=0

	#== file variables ==#
filePid="${SCRIPT_DIR_LOCK}/pid"
fileLog="/dev/null"

	#== function variables ==#
ipcf_file="${SCRIPT_DIR_LOCK}/${SCRIPT_UNIQ_DATED}.tmp.ipcf";
ipcf_IFS="|" ; ipcf_return="" ;
rc=0 ; countErr=0 ; countWrn=0 ;

	#== NUMA variables ==#
NUMACTL_OUT=""
NUM_NUMA_NODES=0
NUMACORES=0

	#== PRESTO variables ==#
PRESTO_TOTAL_MEM=0
PRESTO_NODE_MEM=0
JVM_MEM=0

	#== option variables ==#
flagOptErr=0
flagOptLog=0
flagOptTimeLog=0
flagOptIgnoreLock=0

flagTmp=0
flagDbg=1
flagScriptLock=0
flagMainScriptStart=0


#============================
#  PARSE OPTIONS WITH GETOPTS
#============================

	#== set short options ==#
SCRIPT_OPTS=':o:txhv:s:q:w:d:m:n:a:c:l:-:'

	#== set long options associated with short one ==#
typeset -A ARRAY_OPTS
ARRAY_OPTS=(
	[mode]=m
	[coordinator-worker]=w
	[cluster-size]=c
	[number]=n
	[coordinator-address]=a
	[local-ip]=l
	[scale-factor]=s
	[directory]=d
	[timelog]=t
	[ignorelock]=x
	[output]=o
	[help]=h
	[man]=h
)

	#== parse options ==#
while getopts ${SCRIPT_OPTS} OPTION ; do
	#== translate long options to short ==#
	if [[ "x$OPTION" == "x-" ]]; then
		LONG_OPTION=$OPTARG
		LONG_OPTARG=$(echo $LONG_OPTION | grep "=" | cut -d'=' -f2)
		LONG_OPTIND=-1
		[[ "x$LONG_OPTARG" = "x" ]] && LONG_OPTIND=$OPTIND || LONG_OPTION=$(echo $OPTARG | cut -d'=' -f1)
		[[ $LONG_OPTIND -ne -1 ]] && eval LONG_OPTARG="\$$LONG_OPTIND"
		OPTION=${ARRAY_OPTS[$LONG_OPTION]}
		[[ "x$OPTION" = "x" ]] &&  OPTION="?" OPTARG="-$LONG_OPTION"
		
		if [[ $( echo "${SCRIPT_OPTS}" | grep -c "${OPTION}:" ) -eq 1 ]]; then
			if [[ "x${LONG_OPTARG}" = "x" ]] || [[ "${LONG_OPTARG}" = -* ]]; then 
				OPTION=":" OPTARG="-$LONG_OPTION"
			else
				OPTARG="$LONG_OPTARG";
				if [[ $LONG_OPTIND -ne -1 ]]; then
					[[ $OPTIND -le $Optnum ]] && OPTIND=$(( $OPTIND+1 ))
					shift $OPTIND
					OPTIND=1
				fi
			fi
		fi
	fi

	#== options follow by another option instead of argument ==#
	if [[ "x${OPTION}" != "x:" ]] && [[ "x${OPTION}" != "x?" ]] && [[ "${OPTARG}" = -* ]]; then 
		OPTARG="$OPTION" OPTION=":"
	fi

	#== manage options ==#
	case "$OPTION" in


		m ) MODE="${OPTARG}"
			case "$MODE" in		
				"WIM")
				;;
				"WIN")
				;;
				*)	
					error "Invalid -m option: $MODE"
					usagefull
					exit 1
					;;
				esac
		;;

		w ) COORDINATOR_FLAG=${OPTARG}
			case "$COORDINATOR_FLAG" in		
				"yes")
				;;
				"no")
				;;
				*)	
					error "Invalid -w option: $COORDINATOR_FLAG"
					usagefull
					exit 1
					;;
				esac
		;;

		n ) MACHINE_NUMBER="${OPTARG}"
			if [[ ! $MACHINE_NUMBER =~ ^[0-9]+$ ]]; then
				error "invalid -n option: $MACHINE_NUMBER"
				error "-n must to be a positive number."
				exit 1;
			fi
		;;

		c ) CLUSTER_SIZE="${OPTARG}"
			if [[ ! $CLUSTER_SIZE =~ ^[0-9]+$ ]]; then
				error "invalid -c option: $CLUSTER_SIZE"
				error "-c must to be a positive number."
				exit 1;
			fi
		;;

		a ) COORD_ADDRESS="${OPTARG}"
			
			arrIN=(${COORD_ADDRESS//:/ })
			COORD_IP=${arrIN[0]} 
			COORD_PORT=${arrIN[1]}
			if [[ "$COORD_IP" =~ (([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5])\.([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5])\.([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5])\.([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5]))$ ]]; then
			  COORD_IP=$COORD_IP
			else
			  error "Invalid Coordinator IP address: $COORD_IP"
			  exit 1;
			fi

  		;;

  		l ) LOCAL_IP="${OPTARG}"
			
			if [[ "$LOCAL_IP" =~ (([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5])\.([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5])\.([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5])\.([01]{,1}[0-9]{1,2}|2[0-4][0-9]|25[0-5]))$ ]]; then
			  LOCAL_IP=$LOCAL_IP
			else
			  error "Invalid local IP address: $LOCAL_IP"
			  exit 1;
			fi

  		;;

  		s ) SCALE_FACTOR="${OPTARG}"
			if [[ ! $SCALE_FACTOR =~ ^[0-9]+$ ]]; then
				error "invalid -s option: $SCALE_FACTOR"
				error "-s must to be a positive number."
				exit 1;
			fi
		;;


		d ) OUT_DIR=${OPTARG}
			if [ ! -d $OUT_DIR ]; then
				mkdir -p ${OUT_DIR}
			fi

		;;


		o ) fileLog="${OPTARG}"
			[[ "${OPTARG}" = *"DEFAULT" ]] && fileLog="$( echo ${OPTARG} | sed -e "s/DEFAULT/${SCRIPT_UNIQ_DATED}.log/g" )"
			flagOptLog=1
		;;
		
		t ) flagOptTimeLog=1
			SCRIPT_TIMELOG_FLAG=1
		;;
		
		x ) flagOptIgnoreLock=1
		;;
		
		h ) usagefull
			exit 0
		;;
		
		v ) scriptinfo
			exit 0
		;;
		
		: ) error "${SCRIPT_NAME}: -$OPTARG: option requires an argument"
			flagOptErr=1
		;;
		
		? ) error "${SCRIPT_NAME}: -$OPTARG: unknown option"
			flagOptErr=1
		;;
	esac
done
shift $((${OPTIND} - 1)) ## shift options

#============================
#  MAIN SCRIPT
#============================

check_user_not_root

if [ -z "$MODE" ]
then
      error "Missing mandatory argument: -m"
      exit 1
fi

if [ -z "$COORDINATOR_FLAG" ]
then
      error "Missing mandatory argument: -w"
      exit 1
fi

if [ -z "$MACHINE_NUMBER" ]
then
      error "Missing mandatory argument: -n"
      exit 1
fi

if [ -z "$COORD_ADDRESS" ]
then
      error "Missing mandatory argument: -a"
      exit 1
fi

if [ -z "$LOCAL_IP" ]
then
      error "Missing mandatory argument: -l"
      exit 1
fi

if [ -z "$CLUSTER_SIZE" ]
then
      error "Missing mandatory argument: -c"
      exit 1
fi


[ $flagOptErr -eq 1 ] && usage 1>&2 && exit 1 ## print usage if option error and exit

	#== Check/Set arguments ==#
[[ $# -gt 2 ]] && error "${SCRIPT_NAME}: Too many arguments" && usage 1>&2 && exit 2

	#== Create lock ==#
flagScriptLock=0
while [[ flagScriptLock -eq 0 ]]; do
	if mkdir ${SCRIPT_DIR_LOCK} 1>/dev/null 2>&1; then
		info "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Locking succeeded" >&2
		flagScriptLock=1
	elif [[ ${flagOptIgnoreLock} -ne 0 ]]; then
		warning "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Lock detected BUT IGNORED" >&2
		SCRIPT_DIR_LOCK="${SCRIPT_UNIQ_DATED}.lock"
		filePid="${SCRIPT_DIR_LOCK}/pid"
		ipcf_file="${SCRIPT_DIR_LOCK}/${SCRIPT_UNIQ_DATED}.tmp.ipcf";
		flagOptIgnoreLock=0
	elif [[ ! -e "${SCRIPT_DIR_LOCK}" ]]; then
		error "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Cannot create lock folder" && exit 3
	else
		[[ ! -e ${filePid} ]] && sleep 1 # In case of concurrency
		if [[ ! -e ${filePid} ]]; then
			warning "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Remove stale lock (no filePid)"
		elif [[ "x$( ps -ef | grep $(head -1 "${filePid}"))" == "x" ]]; then
			warning "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Remove stale lock (no running pid)"
		else 
			error "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Lock detected (running pid: $(head -1 "${filePid}")) - exit program" && exit 3
		fi
		rm -fr "${SCRIPT_DIR_LOCK}" 1>/dev/null 2>&1
		[[ "${?}" -ne 0 ]] && error "${SCRIPT_NAME}: ${SCRIPT_DIR_LOCK}: Cannot delete lock folder" && exit 3
	fi
done

	#== Create files ==#
check_cre_file "${filePid}" || exit 4
check_cre_file "${ipcf_file}" || exit 4
check_cre_file "${fileLog}" || exit 4

echo "${EXEC_ID}" > ${filePid}

if [[ "${fileLog}" != "/dev/null" ]]; then
	touch ${fileLog} && fileLog="$( cd $(dirname "${fileLog}") && pwd )"/"$(basename ${fileLog})"
fi

	#== Main part ==#
	#===============#
{ scriptstart ;
	#== start your program here ==#

get_number_of_NUMA_nodes

get_total_workers

get_jvm_and_nodes_mem

if [[ $COORDINATOR_FLAG == 'yes' ]]; then

	infotitle "Setting Coordinator directory..."

	set_coordinator_config_file

fi

infotitle "Creating and setting Workers directory..."

create_workers_directory

set_worker_config_files

infotitle "Start Workers and Coordinator..."

start_coordinator_and_workers

print_message_with_date "Wait for the Workers..."

for ((j = 0; j < 30; j += 1)) ; do
	sleep 2
	if [[ $j -eq 29 ]]; then
		echo "."
	else
		echo -n "."
	fi
done  

print_message_with_date "Done!"


if [[ $COORDINATOR_FLAG == 'yes' ]]; then

	cd ..
	if [[ $MODE == 'WIM' ]]; then

		OUT_DIR="${SCRIPT_DIR}/WIM+FT_with_${CLUSTER_SIZE}_machines/"
		exec_cmd "mkdir -p $OUT_DIR"
		start_coordinator_and_workers
		run_tpch_benchmark

	else

		POLICY="MEM"
		OUT_DIR="${SCRIPT_DIR}/WIN+MEM_with_${CLUSTER_SIZE}_machines/"
		exec_cmd "mkdir -p $OUT_DIR"
		start_coordinator_and_workers
		run_tpch_benchmark
	fi

	cd multiple_machines/

	infotitle "Stop Workers and Coordinator..."

	stop_coordinator_and_workers

	rm -rf presto-worker-coordinator

	infotitle "Remove Workers directory..."

	remove_workers_directory

	infotitle "Test completed! You can stop the Worker instances on the other machines!"

else

	( trap exit SIGINT ; read -r -d '' _ </dev/tty )

fi

ipcf_save_rc >/dev/null

	#== end   your program here ==#
scriptfinish ; } 2>&1 | tee ${fileLog}

	#== End ==#
	#=========#
ipcf_load_rc >/dev/null
exit $rc
