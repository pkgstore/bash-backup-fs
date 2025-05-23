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
SYNC_DEL="${SYNC_DEL:?}"; readonly SYNC_DEL
SYNC_RSF="${SYNC_RSF:?}"; readonly SYNC_RSF
SYNC_PED="${SYNC_PED:?}"; readonly SYNC_PED
SYNC_CVS="${SYNC_CVS:?}"; readonly SYNC_CVS

# -------------------------------------------------------------------------------------------------------------------- #
# -----------------------------------------------------< SCRIPT >----------------------------------------------------- #
# -------------------------------------------------------------------------------------------------------------------- #

function _err() {
  echo >&2 "[$( date +'%Y-%m-%dT%H:%M:%S%z' )]: $*"; exit 1
}

function _timestamp() {
  date -u '+%Y-%m-%d.%H-%M-%S'
}

function _tree() {
  echo "$( date -u '+%Y' )/$( date -u '+%m' )/$( date -u '+%d' )"
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
      *) _err 'ENC_APP does not exist!' ;;
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

function backup() {
  local ts; ts="$( _timestamp )"
  local tree; tree="${FS_DST}/$( _tree )"
  local file; file="$( hostname -f ).${ts}.tar.xz"
  for i in "${!FS_SRC[@]}"; do [[ -e "${FS_SRC[i]}" ]] || unset 'FS_SRC[i]'; done
  [[ ! -d "${tree}" ]] && mkdir -p "${tree}"; cd "${tree}" || _err "Directory '${tree}' not found!"
  tar -cf - "${FS_SRC[@]}" | xz | _enc "${tree}/${file}" && _sum "${tree}/${file}"
}

function sync() {
  (( ! "${SYNC_ON}" )) && return 0
  local opts; opts=('--archive' '--quiet')
  (( "${SYNC_DEL}" )) && opts+=('--delete')
  (( "${SYNC_RSF}" )) && opts+=('--remove-source-files')
  (( "${SYNC_PED}" )) && opts+=('--prune-empty-dirs')
  (( "${SYNC_CVS}" )) && opts+=('--cvs-exclude')
  rsync "${opts[@]}" -e "sshpass -p '${SYNC_PASS}' ssh -p ${SYNC_PORT:-22}" \
    "${FS_DST}/" "${SYNC_USER:-root}@${SYNC_HOST}:${SYNC_DST}/"
}

function clean() {
  find "${FS_DST}" -type 'f' -mtime "+${FS_DAYS:-30}" -print0 | xargs -0 rm -f --
  find "${FS_DST}" -mindepth 1 -type 'd' -not -name 'lost+found' -empty -delete
}

function main() { backup && sync && clean; }; main "$@"
