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
ENC_ON="${ENC_ON:?}"; readonly ENC_ON
ENC_APP="${ENC_APP:?}"; readonly ENC_APP
ENC_PASS="${ENC_PASS:?}"; readonly ENC_PASS
SYNC_ON="${SYNC_ON:?}"; readonly SYNC_ON
SYNC_HOST="${SYNC_HOST:?}"; readonly SYNC_HOST
SYNC_USER="${SYNC_USER:?}"; readonly SYNC_USER
SYNC_PASS="${SYNC_PASS:?}"; readonly SYNC_PASS
SYNC_DST="${SYNC_DST:?}"; readonly SYNC_DST
MAIL_ON="${MAIL_ON:?}"; readonly MAIL_ON
MAIL_FROM="${MAIL_FROM:?}"; readonly MAIL_FROM
MAIL_TO=("${MAIL_TO[@]:?}"); readonly MAIL_TO
GITLAB_ON="${GITLAB_ON:?}"; readonly GITLAB_ON
GITLAB_API="${GITLAB_API:?}"; readonly GITLAB_API
GITLAB_PROJECT="${GITLAB_PROJECT:?}"; readonly GITLAB_PROJECT
GITLAB_TOKEN="${GITLAB_TOKEN:?}"; readonly GITLAB_TOKEN

# -------------------------------------------------------------------------------------------------------------------- #
# -----------------------------------------------------< SCRIPT >----------------------------------------------------- #
# -------------------------------------------------------------------------------------------------------------------- #

function _uuid() {
  dmidecode -s 'system-uuid'
}

function _host() {
  local type; type="${1}"

  case "${type}" in
    'f') hostname -f ;;
    'i') hostname -I ;;
    *) return 1 ;;
  esac
}

function _date() {
  local type; type="${1}"

  case "${type}" in
    'd') date -u '+%d' ;;
    'm') date -u '+%m' ;;
    's') date -u '+%s' ;;
    't') date -u '+%F.%H-%M-%S' ;;
    'Y') date -u '+%Y' ;;
    'z') date '+%FT%T%:z' ;;
    *) return 1 ;;
  esac
}

function _msg() {
  local type; type="${1}"
  local msg; msg="$( _date 'z' ) $( _host 'f' ) ${SRC_NAME}: ${2:?}"

  case "${type}" in
    'error') echo "${msg}" >&2; exit 1 ;;
    'success') echo "${msg}" ;;
    *) return 1 ;;
  esac
}

function _tree() {
  echo "$( _date 'Y' )/$( _date 'm' )/$( _date 'd' )"
}

function _mail() {
  (( ! "${MAIL_ON}" )) && return 0

  local id; id="#id:$( _host 'f' ):$( _uuid )"
  local type; type="#type:backup:${1}"
  local date; date="#date:$( _date 'z' )"
  local ip; ip="#ip:$( _host 'i' )"
  local subj; subj="[$( _host 'f' )] ${SRC_NAME}: ${2}"
  local body; body="${3}"
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
  local title; title="[$( _host 'f' )] ${SRC_NAME}: ${2}"
  local description; description="${3}"
  local id; id="#id:$( _host 'f' ):$( _uuid )"
  local ip; ip="#ip:$( _host 'i' )"
  local date; date="#date:$( _date 'z' )"
  local type; type="#type:backup:${1}"

  curl "${GITLAB_API}/projects/${GITLAB_PROJECT}/issues" -X 'POST' -kfsLo '/dev/null' \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H 'Content-Type: application/json' \
    -d @- <<EOF
{
  "title": "${title}",
  "description": "${description}\n\n- \`${id^^}\`\n- \`${ip^^}\`\n- \`${date^^}\`\n- \`${type^^}\`",
  "labels": "backup,database,${label}"
}
EOF
}

function _gpg() {
  local out; out="${1}.gpg"
  local pass; pass="${2}"

  gpg --batch --passphrase "${pass}" --symmetric --output "${out}" \
    --s2k-cipher-algo "${ENC_S2K_CIPHER:-AES256}" \
    --s2k-digest-algo "${ENC_S2K_DIGEST:-SHA512}" \
    --s2k-count "${ENC_S2K_COUNT:-65536}"
}

function _ssl() {
  local out; out="${1}.ssl"
  local pass; pass="${2}"

  openssl enc "-${ENC_SSL_CIPHER:-aes-256-cfb}" -out "${out}" -pass "pass:${pass}" \
    -salt -md "${ENC_SSL_DIGEST:-sha512}" -iter "${ENC_SSL_COUNT:-65536}" -pbkdf2
}

function _enc() {
  local out; out="${1}"
  local pass; pass="${ENC_PASS}"

  if (( "${ENC_ON}" )); then
    case "${ENC_APP}" in
      'gpg') _gpg "${out}" "${pass}" ;;
      'ssl') _ssl "${out}" "${pass}" ;;
      *) _msg 'error' 'ENC_APP does not exist!' ;;
    esac
  else
    cat < '/dev/stdin' > "${out}"
  fi
}

function _sum() {
  local in; in="${1}"; (( "${ENC_ON}" )) && in="${1}.${ENC_APP}"
  local out; out="${in}.txt"

  sha256sum "${in}" | sed 's| .*/|  |g' | tee "${out}" > '/dev/null'
}

function fs_check() {
  local file; file='.backup_fs'
  local msg; msg=()

  if [[ ! -f "${DB_DST}/${file}" ]]; then
    msg=(
      'error'
      "File '${file}' not found!"
      "File '${file}' not found! Please check the remote storage status!"
    ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg 'error' "${msg[2]}"
  fi; return 0
}

function fs_backup() {
  local ts; ts="$( _date 't' )"
  local tree; tree="${FS_DST}/$( _tree )"
  local file; file="$( _host 'f' ).${ts}.tar.xz"

  for i in "${!FS_SRC[@]}"; do [[ -e "${FS_SRC[i]}" ]] || unset 'FS_SRC[i]'; done
  [[ ! -d "${tree}" ]] && mkdir -p "${tree}"; cd "${tree}" || _msg 'error' "Directory '${tree}' not found!"
  if tar -cf - "${FS_SRC[@]}" | xz | _enc "${tree}/${file}" && _sum "${tree}/${file}"; then
    msg=(
      'success'
      "Backup of files ('${file}') completed successfully"
      "Backup of files ('${file}') completed successfully. File '${tree}/${file}' received."
    ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg 'success' "${msg[2]}"
  else
    msg=(
      'error'
      "Error backing up files ('${file}')"
      "Error backing up files ('${file}')! File '${tree}/${file}' not received or corrupted!"
    ); _mail "${msg[@]}"; _gitlab "${msg[@]}"; _msg 'error' "${msg[2]}"
  fi
}

function fs_sync() {
  (( ! "${SYNC_ON}" )) && return 0

  local opts; opts=('--archive' '--quiet')
  (( "${SYNC_DEL:-0}" )) && opts+=('--delete')
  (( "${SYNC_RSF:-0}" )) && opts+=('--remove-source-files')
  (( "${SYNC_PED:-0}" )) && opts+=('--prune-empty-dirs')
  (( "${SYNC_CVS:-0}" )) && opts+=('--cvs-exclude')

  if rsync "${opts[@]}" -e "sshpass -p '${SYNC_PASS}' ssh -p ${SYNC_PORT:-22}" \
    "${FS_DST}/" "${SYNC_USER:-root}@${SYNC_HOST}:${SYNC_DST}/"; then
    msg=(
      'success'
      'Synchronization with remote storage completed successfully'
      'Synchronization with remote storage completed successfully.'
    ); _mail "${msg[@]}"; _msg 'success' "${msg[2]}"
  else
    msg=(
      'error'
      'Error synchronizing with remote storage'
      'Error synchronizing with remote storage!'
    ); _mail "${msg[@]}"; _msg 'error' "${msg[2]}"
  fi
}

function fs_clean() {
  find "${FS_DST}" -type 'f' -mtime "+${FS_DAYS:-30}" -print0 | xargs -0 rm -f --
  find "${FS_DST}" -mindepth 1 -type 'd' -not -name 'lost+found' -empty -delete
}

function main() {
  fs_check && fs_backup && fs_sync && fs_clean
}; main "$@"
