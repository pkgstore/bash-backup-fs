# Backup: File system

A file system backup script.

## Install

```bash
export SET_DIR='/root/apps/backup'; export GH_NAME='bash-backup-fs'; export GH_URL="https://github.com/pkgstore/${GH_NAME}/archive/refs/heads/main.tar.gz"; curl -Lo "${GH_NAME}-main.tar.gz" "${GH_URL}" && tar -xzf "${GH_NAME}-main.tar.gz" && { cd "${GH_NAME}-main" || exit; } && { for i in app_*; do install -m '0644' -Dt "${SET_DIR}" "${i}"; done; } && { for i in cron_*; do install -m '0644' -Dt '/etc/cron.d' "${i}"; done; } && chmod +x "${SET_DIR}"/*.sh
```

## Resources

- [Documentation (RU)](https://lib.onl/ru/2025/05/302e6636-dc21-5585-9bc9-b8dd757b6ee1/)
