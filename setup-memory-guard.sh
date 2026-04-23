#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

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

  run systemctl disable --now zram-monitor.timer zram-monitor.service || true
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
# Perfil de preservação: mantém apps de estudo/trabalho, só atua em pressão realmente crítica.
# -m 8: só considera memória crítica abaixo de 8% disponível
# -s 55: só considera swap crítica abaixo de 55% livre
# --prefer: prioriza encerrar apps pesados não essenciais
# --avoid: protege Librewolf, Obsidian, terminal, tmux, rclone e processos do OMP
EARLYOOM_ARGS="-p -r 60 -m 8 -s 55 --ignore-root-user --prefer '^(chrome|chromium|code|electron)$' --avoid '^(obsidian|librewolf|Web Content|Isolated Web Co|WebExtensions|Privileged Cont|RDD Process|Socket Process|forkserver|Utility Process|tmux|qterminal|bun|python3|rclone|systemd|systemd-logind|dbus-daemon|dbus-broker|Xorg|Xwayland|lightdm|sddm|gdm|lxqt-session|openbox)$' -N /usr/local/bin/earlyoom-kill-log.sh"
EOF
  write_file_if_changed "/etc/default/earlyoom" "0644" "$tmp"
  rm -f "$tmp"
}

write_sysctl_tuning() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# memory-guard: ajustes conservadores para desktop com baixa RAM + HDD.
# swappiness moderado, ainda favorece zram sem empurrar cedo demais para swap em HDD.
vm.swappiness=110
vm.page-cluster=0
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
  local script_tmp service_tmp timer_tmp logrotate_tmp

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

mem_available_mib="$((mem_available_kib / 1024))"
swap_used_mib="$((swap_used_kib / 1024))"

alerts=()
if (( mem_available_mib < 700 )); then
  alerts+=("mem_available=${mem_available_mib}MiB")
fi
if (( swap_used_mib > 2048 )); then
  alerts+=("swap_used=${swap_used_mib}MiB")
fi

{
  printf -- '--- %s\n' "$(date --iso-8601=seconds)"
  printf '[free -m]\n'
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
  printf '\n'
} >> "$LOG_FILE"

if (( ${#alerts[@]} > 0 )); then
  printf '%s ALERT %s\n' "$(date --iso-8601=seconds)" "${alerts[*]}" >> "$INCIDENT_FILE"
fi
EOF
  write_file_if_changed "/usr/local/bin/memory-pressure-log.sh" "0755" "$script_tmp"
  rm -f "$script_tmp"

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
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  write_file_if_changed "/etc/systemd/system/memory-pressure-log.timer" "0644" "$timer_tmp"
  rm -f "$timer_tmp"

  logrotate_tmp="$(mktemp)"
  cat > "$logrotate_tmp" <<'EOF'
/var/log/memory-guard/*.log {
    rotate 14
    daily
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

apply_services() {
  run sysctl --system
  run systemctl daemon-reload

  run systemctl enable --now zramswap.service
  run systemctl restart zramswap.service

  run systemctl enable --now earlyoom.service
  run systemctl restart earlyoom.service

  run systemctl enable --now memory-pressure-log.timer
  run systemctl start memory-pressure-log.service
}

show_postcheck() {
  log "Resumo pós-aplicação"
  run swapon --show
  run zramctl
  run systemctl --no-pager --full status earlyoom.service
  run systemctl --no-pager --full status zramswap.service
  run systemctl --no-pager --full status memory-pressure-log.timer

  cat <<EOF

Setup concluído.
Logs principais:
- $SETUP_LOG
- /var/log/memory-guard/earlyoom-kills.log
- /var/log/memory-guard/memory-pressure.log
- /var/log/memory-guard/memory-pressure-incidents.log

Verificação rápida:
  sudo journalctl -u earlyoom -n 50 --no-pager
  sudo systemctl status zramswap --no-pager
  sudo tail -n 50 /var/log/memory-guard/memory-pressure.log
EOF
}

main() {
  ensure_root
  setup_logging

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
