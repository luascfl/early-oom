#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=false
LOGGING_ONLY=false

usage() {
  cat <<'EOF'
Usage: setup-memory-guard.sh [--dry-run] [--logging-only]

  --dry-run       Show host changes without writing them.
  --logging-only  Install freeze evidence logging without changing ZRAM,
                  EarlyOOM, sysctl, or installed packages.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --logging-only) LOGGING_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SETUP_LOG=""

log() {
  printf '[%s] %s\n' "$(date +%F' '%T)" "$*"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

backup_file_if_exists() {
  local target="$1"
  if [[ -f "$target" ]]; then
    local backup_dir="/var/backups/memory-guard"
    run install -d -m 0755 "$backup_dir"
    run cp -a "$target" "$backup_dir/$(basename "$target").${TIMESTAMP}.bak"
  fi
}

write_file_if_changed() {
  local target="$1"
  local mode="$2"
  local tmp_file="$3"

  if [[ -f "$target" ]] && cmp -s "$target" "$tmp_file"; then
    log "Sem mudanças em $target"
    return
  fi

  backup_file_if_exists "$target"
  run install -D -m "$mode" "$tmp_file" "$target"
  log "Atualizado: $target"
}

ensure_root() {
  if [[ "$DRY_RUN" == false && "$EUID" -ne 0 ]]; then
    exec sudo -E bash "$0"
  fi
}

setup_logging() {
  if [[ "$DRY_RUN" == true ]]; then
    SETUP_LOG="$(pwd)/memory-guard-setup-dry-run-${TIMESTAMP}.log"
    exec > >(tee -a "$SETUP_LOG") 2>&1
    log "Modo dry-run, log em $SETUP_LOG"
    return
  fi

  run install -d -m 0755 /var/log/memory-guard
  SETUP_LOG="/var/log/memory-guard/setup-${TIMESTAMP}.log"
  exec > >(tee -a "$SETUP_LOG") 2>&1
  log "Log de setup em $SETUP_LOG"
}

apt_install_requirements() {
  run apt-get update
  run apt-get install -y --no-install-recommends earlyoom zram-tools
}

disable_conflicting_zram_stack() {
  if dpkg-query -W -f='${Status}' zram-config 2>/dev/null | grep -q "install ok installed"; then
    log "Detectado pacote zram-config, removendo para evitar conflito com zram-tools"
    run systemctl disable --now zram-config.service || true
    run apt-get purge -y zram-config
  fi

}

reset_existing_zram_devices() {
  local had_swap=false

  if grep -q '^/dev/zram' /proc/swaps; then
    had_swap=true
    while read -r swapdev; do
      [[ -z "$swapdev" ]] && continue
      run swapoff "$swapdev" || true
    done < <(awk '$1 ~ /^\/dev\/zram/ {print $1}' /proc/swaps)
  fi

  shopt -s nullglob
  local reset_path
  for reset_path in /sys/block/zram*/reset; do
    run bash -c "echo 1 > '$reset_path'" || true
  done
  shopt -u nullglob

  if [[ "$had_swap" == true ]]; then
    log "Dispositivos zram resetados antes de subir configuração nova"
  fi
}

write_zramswap_config() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Configuração otimizada para notebook com 4 GiB RAM + HDD.
# Objetivo: usar zram cedo, preservar responsividade e reduzir travamentos.
ALGO=lz4
PERCENT=60
SIZE=512
PRIORITY=180
EOF
  write_file_if_changed "/etc/default/zramswap" "0644" "$tmp"
  rm -f "$tmp"
}

write_earlyoom_hook() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/memory-guard/earlyoom-kills.log"
install -d -m 0755 "$(dirname "$LOG_FILE")"

printf '%s pid=%s uid=%s name=%s\n' \
  "$(date --iso-8601=seconds)" \
  "${EARLYOOM_PID:-unknown}" \
  "${EARLYOOM_UID:-unknown}" \
  "${EARLYOOM_NAME:-unknown}" >> "$LOG_FILE"
EOF
  write_file_if_changed "/usr/local/bin/earlyoom-kill-log.sh" "0755" "$tmp"
  rm -f "$tmp"
}

write_earlyoom_config() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Perfil anti-freeze: preserva o desktop e encerra conteúdo web pesado antes do lockup.
# -m 20 e -s 15 só atuam com pouca RAM e pouca swap livre.
# --prefer prioriza conteúdo web pesado; --avoid protege o desktop e serviços críticos.
EARLYOOM_ARGS="-p -r 60 -m 20 -s 15 --ignore-root-user --prefer '(chrome|chromium|code|electron|Isolated Web Co|Web Content)' --avoid '(obsidian|librewolf|WebExtensions|Privileged Cont|RDD Process|Socket Process|forkserver|Utility Process|tmux|qterminal|bun|python3|rclone|systemd|systemd-logind|dbus-daemon|dbus-broker|Xorg|Xwayland|lightdm|sddm|gdm|lxqt-session|openbox)' -N /usr/local/bin/earlyoom-kill-log.sh"
EOF
  write_file_if_changed "/etc/default/earlyoom" "0644" "$tmp"
  rm -f "$tmp"
}

write_sysctl_tuning() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Os valores abaixo são os vencedores do benchmark deste notebook com ZRAM.
vm.swappiness=89
vm.page-cluster=2
# evita picos longos de escrita suja em HDD sob pressão.
vm.dirty_background_ratio=3
vm.dirty_ratio=10
EOF
  if [[ -f "/etc/sysctl.d/99-memory-guard.conf" ]]; then
    backup_file_if_exists "/etc/sysctl.d/99-memory-guard.conf"
    run rm -f "/etc/sysctl.d/99-memory-guard.conf"
  fi
  write_file_if_changed "/etc/sysctl.d/zz-memory-guard.conf" "0644" "$tmp"
  rm -f "$tmp"
}

write_monitoring_units() {
  local script_tmp service_tmp timer_tmp session_script_tmp session_service_tmp journald_tmp logrotate_tmp

  script_tmp="$(mktemp)"
  cat > "$script_tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="/var/log/memory-guard"
LOG_FILE="$LOG_DIR/memory-pressure.log"
INCIDENT_FILE="$LOG_DIR/memory-pressure-incidents.log"

install -d -m 0755 "$LOG_DIR"

mem_available_kib="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
swap_total_kib="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
swap_free_kib="$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"
swap_used_kib="$((swap_total_kib - swap_free_kib))"
pressure_some_avg10="$(awk '$1 == "some" {sub("avg10=", "", $2); print $2}' /proc/pressure/memory)"
pressure_full_avg10="$(awk '$1 == "full" {sub("avg10=", "", $2); print $2}' /proc/pressure/memory)"

mem_available_mib="$((mem_available_kib / 1024))"
swap_used_mib="$((swap_used_kib / 1024))"

alerts=()
if (( mem_available_mib < 700 )); then
  alerts+=("mem_available=${mem_available_mib}MiB")
fi
if (( swap_used_mib > 2048 )); then
  alerts+=("swap_used=${swap_used_mib}MiB")
fi
if awk -v value="$pressure_some_avg10" 'BEGIN { exit !(value >= 10) }'; then
  alerts+=("pressure_some_avg10=${pressure_some_avg10}")
fi
if awk -v value="$pressure_full_avg10" 'BEGIN { exit !(value >= 5) }'; then
  alerts+=("pressure_full_avg10=${pressure_full_avg10}")
fi

{
  printf -- '--- %s\n' "$(date --iso-8601=seconds)"
  printf '[load average]\n'
  cat /proc/loadavg
  printf '\n[memory pressure]\n'
  cat /proc/pressure/memory
  printf '\n[free -m]\n'
  free -m
  printf '\n[swapon --show]\n'
  swapon --show
  printf '\n[zramctl]\n'
  zramctl || true
  printf '\n[alerts]\n'
  if (( ${#alerts[@]} > 0 )); then
    printf '%s\n' "${alerts[*]}"
  else
    printf 'none\n'
  fi
  if (( ${#alerts[@]} > 0 )); then
    printf '\n[largest resident processes]\n'
    ps -eo pid,ppid,comm,rss,%mem,args --sort=-rss | sed -n '1,13p'
  fi
  printf '\n'
} >> "$LOG_FILE"

if (( ${#alerts[@]} > 0 )); then
  printf '%s ALERT %s\n' "$(date --iso-8601=seconds)" "${alerts[*]}" >> "$INCIDENT_FILE"
fi
EOF
  write_file_if_changed "/usr/local/bin/memory-pressure-log.sh" "0755" "$script_tmp"
  rm -f "$script_tmp"

  session_script_tmp="$(mktemp)"
  cat > "$session_script_tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="/var/log/memory-guard"
STATE_DIR="/var/lib/memory-guard"
EVENT_LOG="$LOG_DIR/session-events.log"
PREVIOUS_BOOT_LOG="$LOG_DIR/previous-boot-evidence.log"
ACTIVE_SESSION="$STATE_DIR/active-session"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id)"

install -d -m 0755 "$LOG_DIR" "$STATE_DIR"

event() {
  printf '%s boot_id=%s %s\n' "$(date --iso-8601=seconds)" "$BOOT_ID" "$*" >> "$EVENT_LOG"
}

capture_previous_boot_evidence() {
  {
    printf -- '--- %s unclean_session=%s\n' "$(date --iso-8601=seconds)" "$1"
    printf '[previous earlyoom events]\n'
    journalctl -b -1 -u earlyoom --no-pager -n 120 2>&1 || true
    printf '\n[previous kernel warnings]\n'
    journalctl -b -1 -k -p warning --no-pager -n 120 2>&1 || true
    printf '\n'
  } >> "$PREVIOUS_BOOT_LOG"
}

case "${1:-}" in
  start)
    if [[ -s "$ACTIVE_SESSION" ]]; then
      previous_session="$(tr '\n' ' ' < "$ACTIVE_SESSION")"
      event "UNCLEAN_SHUTDOWN previous_session=${previous_session}"
      capture_previous_boot_evidence "$previous_session"
    fi
    printf 'boot_id=%s started_at=%s\n' "$BOOT_ID" "$(date --iso-8601=seconds)" > "$ACTIVE_SESSION"
    event "SESSION_STARTED"
    ;;
  stop)
    if [[ -s "$ACTIVE_SESSION" ]] && grep -q "boot_id=${BOOT_ID}" "$ACTIVE_SESSION"; then
      event "SESSION_STOPPED_CLEANLY"
      rm -f "$ACTIVE_SESSION"
    else
      event "SESSION_STOPPED_WITHOUT_ACTIVE_MARKER"
    fi
    ;;
  *)
    printf 'Usage: %s start|stop\n' "$0" >&2
    exit 64
    ;;
esac
EOF
  write_file_if_changed "/usr/local/bin/memory-guard-session-log.sh" "0755" "$session_script_tmp"
  rm -f "$session_script_tmp"

  service_tmp="$(mktemp)"
  cat > "$service_tmp" <<'EOF'
[Unit]
Description=Snapshot de memória/zram para diagnóstico de travamentos
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/memory-pressure-log.sh
EOF
  write_file_if_changed "/etc/systemd/system/memory-pressure-log.service" "0644" "$service_tmp"
  rm -f "$service_tmp"

  timer_tmp="$(mktemp)"
  cat > "$timer_tmp" <<'EOF'
[Unit]
Description=Timer de snapshots de memória/zram

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  write_file_if_changed "/etc/systemd/system/memory-pressure-log.timer" "0644" "$timer_tmp"
  rm -f "$timer_tmp"

  session_service_tmp="$(mktemp)"
  cat > "$session_service_tmp" <<'EOF'
[Unit]
Description=Registro de sessões e desligamentos anormais do memory guard
After=local-fs.target systemd-journald.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/memory-guard-session-log.sh start
ExecStop=/usr/local/bin/memory-guard-session-log.sh stop
TimeoutStartSec=30s
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
EOF
  write_file_if_changed "/etc/systemd/system/memory-guard-session-log.service" "0644" "$session_service_tmp"
  rm -f "$session_service_tmp"

  journald_tmp="$(mktemp)"
  cat > "$journald_tmp" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=128M
RuntimeMaxUse=64M
EOF
  write_file_if_changed "/etc/systemd/journald.conf.d/90-memory-guard.conf" "0644" "$journald_tmp"
  rm -f "$journald_tmp"

  logrotate_tmp="$(mktemp)"
  cat > "$logrotate_tmp" <<'EOF'
/var/log/memory-guard/*.log {
    rotate 30
    daily
    maxsize 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  write_file_if_changed "/etc/logrotate.d/memory-guard" "0644" "$logrotate_tmp"
  rm -f "$logrotate_tmp"
}

apply_monitoring_services() {
  run systemctl daemon-reload
  run systemctl kill -s HUP systemd-journald.service
  run systemctl enable --now memory-pressure-log.timer
  run systemctl start memory-pressure-log.service
  run systemctl enable memory-guard-session-log.service
  run systemctl restart memory-guard-session-log.service
}

apply_services() {
  run sysctl --system

  run systemctl enable --now zramswap.service
  run systemctl restart zramswap.service

  run systemctl enable --now earlyoom.service
  run systemctl restart earlyoom.service

  apply_monitoring_services
}

show_postcheck() {
  log "Resumo pós-aplicação"
  run swapon --show
  run zramctl
  run systemctl --no-pager --full status earlyoom.service
  run systemctl --no-pager --full status zramswap.service
  run systemctl --no-pager --full status memory-pressure-log.timer
  run systemctl --no-pager --full status memory-guard-session-log.service

  cat <<EOF

Setup concluído.
Logs principais:
- $SETUP_LOG
- /var/log/memory-guard/earlyoom-kills.log
- /var/log/memory-guard/memory-pressure.log
- /var/log/memory-guard/memory-pressure-incidents.log
- /var/log/memory-guard/session-events.log
- /var/log/memory-guard/previous-boot-evidence.log

Verificação rápida:
  sudo journalctl -u earlyoom -n 50 --no-pager
  sudo journalctl --list-boots --no-pager
  sudo systemctl status memory-guard-session-log --no-pager
  sudo tail -n 50 /var/log/memory-guard/session-events.log
EOF
}

main() {
  ensure_root
  setup_logging

  if [[ "$LOGGING_ONLY" == true ]]; then
    log "Instalando somente a evidência de congelamentos"
    write_earlyoom_hook
    write_monitoring_units
    apply_monitoring_services
    show_postcheck
    return
  fi

  log "Iniciando setup unificado de earlyoom + zram"
  apt_install_requirements
  disable_conflicting_zram_stack
  reset_existing_zram_devices

  write_zramswap_config
  write_earlyoom_hook
  write_earlyoom_config
  write_sysctl_tuning
  write_monitoring_units

  apply_services
  show_postcheck
}

main "$@"
