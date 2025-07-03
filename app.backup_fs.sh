#!/usr/bin/env -S bash -euo pipefail
# -------------------------------------------------------------------------------------------------------------------- #
# FILE SYSTEM BACKUP
# Backup files and directories.
# -------------------------------------------------------------------------------------------------------------------- #
# @package    Bash
# @author     Kai Kimera <mail@kai.kim>
# @license    MIT
# @version    0.1.0
# @link       https://lib.onl/ru/2025/05/302e6636-dc21-5585-9bc9-b8dd757b6ee1/
# -------------------------------------------------------------------------------------------------------------------- #

(( EUID != 0 )) && { echo >&2 'This script should be run as root!'; exit 1; }

# -------------------------------------------------------------------------------------------------------------------- #
# CONFIGURATION
# -------------------------------------------------------------------------------------------------------------------- #

# Sources.
SRC_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd -P )"
SRC_NAME="$( basename "$( readlink -f "${BASH_SOURCE[0]}" )" )"
# shellcheck source=/dev/null
. "${SRC_DIR}/${SRC_NAME%.*}.conf"

# Parameters.
FS_SRC=("${FS_SRC[@]}"); readonly FS_SRC
FS_DST="${FS_DST:?}"; readonly FS_DST
FS_TPL="${FS_TPL:?}"; readonly FS_TPL
ENC_ON="${ENC_ON:?}"; readonly ENC_ON
ENC_APP="${ENC_APP:?}"; readonly ENC_APP
ENC_PASS="${ENC_PASS:?}"; readonly ENC_PASS
SSH_ON="${SSH_ON:?}"; readonly SSH_ON
SSH_HOST="${SSH_HOST:?}"; readonly SSH_HOST
SSH_USER="${SSH_USER:?}"; readonly SSH_USER
SSH_PASS="${SSH_PASS:?}"; readonly SSH_PASS
SSH_DST="${SSH_DST:?}"; readonly SSH_DST
SSH_MNT="${SSH_MNT:?}"; readonly SSH_MNT
RSYNC_ON="${RSYNC_ON:?}"; readonly RSYNC_ON
RSYNC_HOST="${RSYNC_HOST:?}"; readonly RSYNC_HOST
RSYNC_USER="${RSYNC_USER:?}"; readonly RSYNC_USER
RSYNC_PASS="${RSYNC_PASS:?}"; readonly RSYNC_PASS
RSYNC_DST="${RSYNC_DST:?}"; readonly RSYNC_DST
MAIL_ON="${MAIL_ON:?}"; readonly MAIL_ON
MAIL_FROM="${MAIL_FROM:?}"; readonly MAIL_FROM
MAIL_TO=("${MAIL_TO[@]:?}"); readonly MAIL_TO
GITLAB_ON="${GITLAB_ON:?}"; readonly GITLAB_ON
GITLAB_API="${GITLAB_API:?}"; readonly GITLAB_API
GITLAB_PROJECT="${GITLAB_PROJECT:?}"; readonly GITLAB_PROJECT
GITLAB_TOKEN="${GITLAB_TOKEN:?}"; readonly GITLAB_TOKEN

# Variables.
LOG_MOUNT="${SRC_DIR}/log.mount"
LOG_CHECK="${SRC_DIR}/log.check"
LOG_BACKUP="${SRC_DIR}/log.backup"
LOG_SYNC="${SRC_DIR}/log.sync"
LOG_CLEAN="${SRC_DIR}/log.clean"

# -------------------------------------------------------------------------------------------------------------------- #
# -----------------------------------------------------< SCRIPT >----------------------------------------------------- #
# -------------------------------------------------------------------------------------------------------------------- #

function _msg() {
  local type; type="${1}"
  local msg; msg="$( date '+%FT%T%:z' ) $( hostname -f ) ${SRC_NAME}: ${2}"

  case "${type}" in
    'error') echo "${msg}" >&2; exit 1 ;;
    'success') echo "${msg}" ;;
    *) exit 1 ;;
  esac
}

function _mail() {
  (( ! "${MAIL_ON}" )) && return 0

  local type; type="#type:backup:${1}"
  local subj; subj="[$( hostname -f )] ${SRC_NAME}: ${2}"
  local body; body="${3}"
  local id; id="#id:$( hostname -f ):$( dmidecode -s 'system-uuid' )"
  local ip; ip="#ip:$( hostname -I )"
  local date; date="#date:$( date '+%FT%T%:z' )"
  local opts; opts=('-S' 'v15-compat' '-s' "${subj}" '-r' "${MAIL_FROM}")
  [[ "${MAIL_SMTP_SERVER:-}" ]] && opts+=(
    '-S' "mta=${MAIL_SMTP_SERVER} smtp-use-starttls"
    '-S' "smtp-auth=${MAIL_SMTP_AUTH:-none}"
  )
  opts+=('-.')

  printf "%s\n\n-- \n%s\n%s\n%s\n%s" "${body}" "${id^^}" "${ip^^}" "${date^^}" "${type^^}" \
    | s-nail "${opts[@]}" "${MAIL_TO[@]}"
}

function _gitlab() {
  (( ! "${GITLAB_ON}" )) && return 0

  local label; label="${1}"
  local title; title="[$( hostname -f )] ${SRC_NAME}: ${2}"
  local desc; desc="${3}"
  local id; id="#id:$( hostname -f ):$( dmidecode -s 'system-uuid' )"
  local ip; ip="#ip:$( hostname -I )"
  local date; date="#date:$( date '+%FT%T%:z' )"
  local type; type="#type:backup:${label}"

  curl "${GITLAB_API}/projects/${GITLAB_PROJECT}/issues" -X 'POST' -kfsLo '/dev/null' \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H 'Content-Type: application/json' \
    -d @- <<EOF
{
  "title": "${title}",
  "description": "${desc//\'/\`}\n\n---\n\n- \`${id^^}\`\n- \`${ip^^}\`\n- \`${date^^}\`\n- \`${type^^}\`",
  "labels": "backup,filesystem,${label}"
}
EOF
}

function _gpg() {
  gpg --batch --passphrase "${2}" --symmetric --output "${1}.gpg" \
    --s2k-cipher-algo "${ENC_S2K_CIPHER:-AES256}" \
    --s2k-digest-algo "${ENC_S2K_DIGEST:-SHA512}" \
    --s2k-count "${ENC_S2K_COUNT:-65536}"
}

function _ssl() {
  openssl enc "-${ENC_SSL_CIPHER:-aes-256-cfb}" -out "${1}.ssl" -pass "pass:${2}" \
    -salt -md "${ENC_SSL_DIGEST:-sha512}" -iter "${ENC_SSL_COUNT:-65536}" -pbkdf2
}

function _enc() {
  if (( "${ENC_ON}" )); then
    case "${ENC_APP}" in
      'gpg') _gpg "${1}" "${ENC_PASS}" ;;
      'ssl') _ssl "${1}" "${ENC_PASS}" ;;
      *) _msg 'error' 'ENC_APP does not exist!' ;;
    esac
  else
    cat < '/dev/stdin' > "${1}"
  fi
}

function _sum() {
  local f; f="${1}"; (( "${ENC_ON}" )) && f="${1}.${ENC_APP}"

  sha256sum "${f}" | sed 's| .*/|  |g' | tee "${f}.txt" > '/dev/null'
}

function _ssh() {
  echo "${SSH_PASS}" | sshfs "${SSH_USER:-root}@${SSH_HOST}:/${1}" "${2}" -o 'password_stdin'
}

function _rsync() {
  local opts; opts=('--archive' '--quiet')
  (( "${RSYNC_DEL:-0}" )) && opts+=('--delete')
  (( "${RSYNC_RSF:-0}" )) && opts+=('--remove-source-files')
  (( "${RSYNC_PED:-0}" )) && opts+=('--prune-empty-dirs')
  (( "${RSYNC_CVS:-0}" )) && opts+=('--cvs-exclude')

  rsync "${opts[@]}" -e "sshpass -p '${RSYNC_PASS}' ssh -p ${RSYNC_PORT:-22}" \
    "${1}/" "${RSYNC_USER:-root}@${RSYNC_HOST}:${2}/"
}

function fs_mount() {
  (( ! "${SSH_ON}" )) && return 0

  local msg; msg=(
    'error'
    'Error mounting SSH FS!'
    "Error mounting SSH FS to '${SSH_MNT}'!"
  )

  _ssh "${SSH_DST}" "${SSH_MNT}" || { _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg "${msg[0]}" "${msg[2]}"; }
}

function fs_check() {
  local file; file="${FS_DST}/.backup_fs"; [[ -f "${file}" ]] && return 0
  local msg; msg=(
    'error'
    "File '${file}' not found!"
    "File '${file}' not found! Please check the remote storage status!"
  ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg "${msg[0]}" "${msg[2]}"
}

function fs_backup() {
  local ts; ts="$( date -u '+%m.%d-%H' )"
  local dst; dst="${FS_DST}/${FS_TPL}"
  local file; file="$( hostname -f ).${ts}.tar.xz"
  local msg; msg=(
    'error'
    "Error backing up files ('${file}')"
    "Error backing up files ('${file}')! File '${dst}/${file}' not received or corrupted!"
  )

  for i in "${!FS_SRC[@]}"; do [[ -e "${FS_SRC[i]}" ]] || unset 'FS_SRC[i]'; done
  [[ ! -d "${dst}" ]] && mkdir -p "${dst}"; cd "${dst}" || _msg "${msg[0]}" "Directory '${dst}' not found!"
  { tar -cf - "${FS_SRC[@]}" | xz | _enc "${dst}/${file}" && _sum "${dst}/${file}"; } \
    || { _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg "${msg[0]}" "${msg[2]}"; }
}

function fs_sync() {
  (( ! "${RSYNC_ON}" )) && return 0

  local msg; msg=(
    'error'
    'Error synchronizing with remote storage'
    'Error synchronizing with remote storage!'
  )

  _rsync "${FS_DST}" "${RSYNC_DST}" || { _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg "${msg[0]}" "${msg[2]}"; }
}

function fs_clean() {
  [[ "${FS_DAYS:-}" ]] || find "${FS_DST}" -type 'f' -mtime "+${FS_DAYS:-30}" -print0 | xargs -0 rm -f --
  find "${FS_DST}" -mindepth 1 -type 'd' -not -name 'lost+found' -empty -delete
}

function main() {
  { fs_mount 2>&1 | tee "${LOG_MOUNT}"; } \
    && { fs_check 2>&1 | tee "${LOG_CHECK}"; } \
    && { fs_backup 2>&1 | tee "${LOG_BACKUP}"; } \
    && { fs_sync 2>&1 | tee "${LOG_SYNC}"; } \
    && { fs_clean 2>&1 | tee "${LOG_CLEAN}"; }
}; main "$@"
