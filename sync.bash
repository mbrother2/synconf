#!/bin/bash

TIME_EPOCH=$(date +%s)
TIME_HUMAN="$(date +"%d-%m-%Y %T")"
TIME_LOCK="${TIME_EPOCH} ${TIME_HUMAN}"
SYNCONF_DIR="/usr/local/synconf"
CONFIG_DIR="${SYNCONF_DIR}/conf"
WATCH_FILE="${CONFIG_DIR}/watch.conf"
CLUSTER_FILE="${CONFIG_DIR}/cluster.conf"
LOG_DIR="${SYNCONF_DIR}/log"
DEBUG_FILE="${LOG_DIR}/debug.log"
FILE_LOCK="${LOG_DIR}/sync.lock"
SSH_TIMEOUT=1
LOCK_TIMEOUT=10
SUCCESS="true"
ACTION=""
MESSAGE=""
WRITE_LOG=1
DATA_JSON=()
DIR_NAME=$(realpath "$1")
SED_DIR_NAME=$(echo "${DIR_NAME}" | sed 's/\//\\\//g')
GET_FILE="$2"
GET_FILE_OK="0"

# Write log & exit bash
_write_log() {
  cat <<EOF | jq -c . >>${LOG_DIR}/cluster.log
    {
      "time": "${TIME_HUMAN}",
      "file_name": "${SINGLE_FILE}",
      "action": "${ACTION}",
      "cluster": [${DATA_JSON[@]}]
    }
EOF
}

# Exit for loop
_exit_for_loop() {
  echo "${SINGLE_FILE} - ${IP_ADDRESS} - ${DEBUG_MESSAGE}" >>${DEBUG_FILE}
  WRITE_LOG=$1
  ssh root@"${IP_ADDRESS}" -p "${SSH_PORT}" rm -f ${FILE_LOCK}."${MD5SUM_FILE}"
  rm -f ${FILE_LOCK}."${MD5SUM_FILE}"
}

_watch_list() {
  jq -r ".watch[] | select(.dir == \"${DIR_NAME}\") | .$1" <${WATCH_FILE} | sort | uniq
}

# Sync file to cluster
_sync_file() {
  for SINGLE_FILE in ${LIST_FILE}; do
    WRITE_LOG=1
    DATA_JSON=()
    i=1

    MD5SUM_FILE="812f9e721a6ac301a65327e50ca4850d"
    if [ -f "${SINGLE_FILE}" ]; then
      MD5SUM_FILE=$(md5sum "${SINGLE_FILE}" | awk '{print $1}')
    fi

    IFS=$'\n'
    for SINGLE_SERVER in ${LIST_SERVER}; do
      TIME_START=$(date +%s)
      IP_ADDRESS=$(echo "${SINGLE_SERVER}" | jq -r '.ip')
      SSH_PORT=$(echo "${SINGLE_SERVER}" | jq -r '.port')

      COMMA=","
      if [ "$i" == "${SUM_SERVERS}" ]; then
        COMMA=""
      fi

      if [ -f ${FILE_LOCK}."${MD5SUM_FILE}" ]; then
        TIME_BEFORE=$(awk '{print $1}' <${FILE_LOCK}."${MD5SUM_FILE}")
        TIME_DIFF=$((TIME_START - TIME_BEFORE))
        if [[ -z "${TIME_DIFF}" ]] || [[ ${TIME_DIFF} -ge ${LOCK_TIMEOUT} ]]; then
          rm -f ${FILE_LOCK}."${MD5SUM_FILE}"
        else
          echo "${SINGLE_FILE} - Lock file exist!" >>${DEBUG_FILE}
          WRITE_LOG=0
          continue
        fi
      fi

      ssh -o ConnectTimeout=${SSH_TIMEOUT} -p "${SSH_PORT}" -q root@"${IP_ADDRESS}" exit || {
        MESSAGE="SSH error"
        SUCCESS="false"
        continue
      }
      echo "${TIME_LOCK}" >${FILE_LOCK}."${MD5SUM_FILE}"
      rsync -az -e "ssh -p ${SSH_PORT}" ${FILE_LOCK}."${MD5SUM_FILE}" "${IP_ADDRESS}":${FILE_LOCK}."${MD5SUM_FILE}"

      if [[ -d "${SINGLE_FILE}" ]] || [[ -f "${SINGLE_FILE}" ]]; then
        ACTION="MODIFY"
        CHECK_RUNNING=$(ps ax | \
          awk -v p='COMMAND' 'NR==1 {n=index($0, p); next} {print substr($0, n)}' | \
          grep -c "rsync .*${SINGLE_FILE}"
        )

        if [ "${CHECK_RUNNING}" != 1 ]; then
          DEBUG_MESSAGE="syncing..."
          _exit_for_loop 0
          continue
        else
          if [ -z "${LIST_TRACK}" ]; then
            RSYNC_OPTION=(--delete)
            for SINGLE_EXCLUDE in ${LIST_EXCLUDE}; do
              RSYNC_OPTION+=(${SINGLE_EXCLUDE})
            done

            CHECK_RSYNC=$(rsync -azPn "${RSYNC_OPTION[@]}" -e "ssh -p ${SSH_PORT}" \
              "${SINGLE_FILE}"/ "${IP_ADDRESS}":"${SINGLE_FILE}" | \
              grep -v -e "^sending incremental file list$" -e "^./$"
            )
            if [ -z "${CHECK_RSYNC}" ]; then
              DEBUG_MESSAGE="Nothing to sync!"
              _exit_for_loop 0
              continue
            else
              rsync -az "${RSYNC_OPTION[@]}" -e "ssh -p ${SSH_PORT}" "${SINGLE_FILE}"/ "${IP_ADDRESS}":"${SINGLE_FILE}"
              MESSAGE="SYNCED_DIR"
            fi
          else
            if ssh root@"${IP_ADDRESS}" -p "${SSH_PORT}" "[ ! -d ${DIR_NAME} ]"; then
              ssh root@"${IP_ADDRESS}" -p "${SSH_PORT}" mkdir "${DIR_NAME}"
            fi
            CHECK_RSYNC=$(rsync -azPn -e "ssh -p ${SSH_PORT}" \
              "${SINGLE_FILE}" "${IP_ADDRESS}":"${SINGLE_FILE}" | \
              grep -v -e "^sending incremental file list$" -e "^./$"
            )
            if [ -z "${CHECK_RSYNC}" ]; then
              DEBUG_MESSAGE="Nothing to sync!"
              _exit_for_loop 0
              continue
            else
              rsync -az -e "ssh -p ${SSH_PORT}" "${SINGLE_FILE}" "${IP_ADDRESS}":"${SINGLE_FILE}"
              MESSAGE="SYNCED_FILE"
            fi
          fi
          sleep 1
        fi
      else
        ACTION="DELETE"
        if [ "${CHECK_DELETE}" == "yes" ]; then
          ssh root@"${IP_ADDRESS}" -p "${SSH_PORT}" rm -rf "${SINGLE_FILE}"
          MESSAGE="DELETED_FILE"
        else
          MESSAGE="NO_DELETE"
        fi
      fi

      if [ -n "${LIST_COMMAND}" ]; then
        IFS=$'\n'
        for SINGLE_COMMAND in ${LIST_COMMAND}; do
          ssh root@"${IP_ADDRESS}" -p "${SSH_PORT}" "${SINGLE_COMMAND}"
        done
      fi

      DEBUG_MESSAGE="Synced"
      _exit_for_loop 1

      TIME_END=$(date +%s)
      TIME_RUN=$((TIME_END - TIME_START))
      SINGLE_RESULT=$(cat <<EOF
        {
          "ip": "${IP_ADDRESS}",
          "time_run": "${TIME_RUN}",
          "message": "${MESSAGE}",
          "success": "${SUCCESS}"
        }${COMMA}
EOF
      )
      i=$((i + 1))
      DATA_JSON+=("${SINGLE_RESULT}")
    done

    if [ "${WRITE_LOG}" == "1" ]; then
      _write_log
    fi
  done
}

# Get file from old server
_get_file() {
  i=1
  IFS=$'\n'
  for SINGLE_SERVER in ${LIST_SERVER}; do
    TIME_START=$(date +%s)
    IP_ADDRESS=$(echo "${SINGLE_SERVER}" | jq -r '.ip')
    SSH_PORT=$(echo "${SINGLE_SERVER}" | jq -r '.port')

    COMMA=","
    if [ "$i" == "${SUM_SERVERS}" ]; then
      COMMA=""
    fi

    if [ "${GET_FILE_OK}" == "0" ]; then
      ssh -o ConnectTimeout=${SSH_TIMEOUT} -p "${SSH_PORT}" -q root@"${IP_ADDRESS}" exit || {
        MESSAGE="SSH error"
        SUCCESS="false"
        continue
      }

      ACTION="GET"
      SINGLE_FILE="${DIR_NAME}"

      if [ -z "${LIST_TRACK}" ]; then
        RSYNC_OPTION=(--delete)
        for SINGLE_EXCLUDE in ${LIST_EXCLUDE}; do
          RSYNC_OPTION+=(${SINGLE_EXCLUDE})
        done

        rsync -az "${RSYNC_OPTION[@]}" -e "ssh -p ${SSH_PORT}" "${IP_ADDRESS}":"${SINGLE_FILE}"/ "${SINGLE_FILE}"
        MESSAGE="GET_DIR"
      else
        IFS=$'\n'
        for SINGLE_FILE in $(echo "${LIST_TRACK}" | sed "s/^/${SED_DIR_NAME}\//g"); do
          rsync -az -e "ssh -p ${SSH_PORT}" "${IP_ADDRESS}":"${SINGLE_FILE}" "${SINGLE_FILE}"
        done

        MESSAGE="GET_FILE"
        SINGLE_FILE=""
      fi

      GET_FILE_OK="1"
    else
      MESSAGE="SKIP_GET"
      SUCCESS="true"
    fi

    TIME_END=$(date +%s)
    TIME_RUN=$((TIME_END - TIME_START))
    SINGLE_RESULT=$(cat <<EOF
      {
        "ip": "${IP_ADDRESS}",
        "time_run": "${TIME_RUN}",
        "message": "${MESSAGE}",
        "success": "${SUCCESS}"
      }${COMMA}
EOF
    )
    i=$((i + 1))
    DATA_JSON+=("${SINGLE_RESULT}")
  done
  _write_log
}

# Get information
_get_info() {
  if [ ! -d "${CONFIG_DIR}" ]; then
    mkdir -p ${CONFIG_DIR}
  fi

  if [ ! -f ${WATCH_FILE} ]; then
    ACTION="NOWATCH"
    _write_log
    exit 1
  else
    LIST_SERVER=$(jq -c '.cluster[]' <${CLUSTER_FILE})
    if [ -z "${LIST_SERVER}" ]; then
      ACTION="NOCLUSTER"
      _write_log
      exit 1
    else
      SUM_SERVERS=$(echo "${LIST_SERVER}" | wc -l)
    fi

    LIST_TRACK=$(_watch_list "track_file[]")
    if [ -z "${LIST_TRACK}" ]; then
      LIST_FILE="${DIR_NAME}"
      LIST_EXCLUDE=$(_watch_list "exclude_file[]")
      if [ -n "${LIST_EXCLUDE}" ]; then
        LIST_EXCLUDE=$(echo "${LIST_EXCLUDE}" | sed "s/^/--exclude=/g")
      fi
    else
      LIST_FILE=$(grep -Fxf <(echo "${LIST_FILE}") <(echo "${LIST_TRACK}"))
      if [ -n "${LIST_FILE}" ]; then
        LIST_FILE=$(echo "${LIST_FILE}" | sed "s/^/${SED_DIR_NAME}\//g")
      fi
      CHECK_DELETE=$(_watch_list "delete_file")
    fi
    LIST_COMMAND=$(_watch_list "command[]")
  fi
}

# Main function
if [ "${GET_FILE}" == "--get-file" ]; then
  _get_info
  _get_file
else
  # Read output from watchman
  while read LINE; do
    {
      echo "---"
      date +"%d-%m-%Y %T"
      echo "${LINE}"
    } >>${DEBUG_FILE}
    LIST_FILE=$(echo "${LINE}" | jq -r '.[].name')
  done

  _get_info
  _sync_file
fi
