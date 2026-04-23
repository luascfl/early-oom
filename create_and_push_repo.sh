#!/usr/bin/env bash

set -euo pipefail

# Globals -------------------------------------------------------------------
export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-luascfl}
export GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-luascfl@example.com}
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-luascfl}
export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-luascfl@example.com}
declare -a __UNTRACKED_BACKUPS=()
declare -a __SUBCONTAINERS_TO_PUSH=()
declare -a __SUBCONTAINERS_TO_CLEAR=()
declare -A __SUBCONTAINER_COMMITS=()
ROOT_TOKEN_FILE=""
ALLOW_PULL=${ALLOW_PULL:-0} # Default is fetch-only; set to 1 to allow automatic pulls/rebases
AUTO_INSTALL_DEPS=${AUTO_INSTALL_DEPS:-1}
__APT_UPDATED=0
CUSTOM_IGNORED_REMOTE_REPOS=("cache" "Downloads")
CENTRAL_CONFIG_DIR="${HOME}/Downloads"
declare -a DEFAULT_INDEX_EXCLUDES=(
  "node_modules"
  ".eslintcache"
  "__pycache__"
  "pycache"
  "cache"
  "dist"
  "build"
  "whatsapp-mcp/whatsapp-bridge/store/whatsapp.db"
  "whatsapp-mcp/whatsapp-bridge/store/messages.db"
  "gcp-oauth.keys.json"
  "gemini-gcloud-key.json"
  "meus_arquivos_mcp"
  "go/"
  "env.sh"
  ".gemini"
  "venv"
  "logs"
  ".aider*"
  ".cursor*"
)
declare -a IGNORED_REMOTE_REPOS=()
add_ignored_remote_repo() {
  local name=$1
  [[ -z "$name" ]] && return
  for existing in "${IGNORED_REMOTE_REPOS[@]}"; do
    if [[ "$existing" == "$name" ]]; then
      return
    fi
  done
  IGNORED_REMOTE_REPOS+=("$name")
}

for name in "${CUSTOM_IGNORED_REMOTE_REPOS[@]}"; do
  add_ignored_remote_repo "$name"
done

for entry in "${DEFAULT_INDEX_EXCLUDES[@]}"; do
  sanitized="${entry%/}"
  if [[ -z "$sanitized" || "$sanitized" == .* || "$sanitized" == *"/"* || "$sanitized" == *"*"* ]]; then
    continue
  fi
  add_ignored_remote_repo "$sanitized"
done
declare -a SENSITIVE_PATHS=("GITHUB_TOKEN" "GITHUB_TOKEN.txt" "AMO_API_KEY.txt" "AMO_API_SECRET.txt" "gcp-oauth.keys.json" "gemini-gcloud-key.json" "AMO_API_KEY" "AMO_API_SECRET" ".env" "*.env" ".env.*")
SUBCONTAINER_STATE_FILE=".subcontainers"
SUBCONTAINER_MODE=false
ROOT_REMOTE_URL=""
GITHUB_API_URL="https://api.github.com"
ROOT_REPO_NAME=""
ROOT_REPO_DIR=""
trap '__restore_all_backups; restore_root_remote' EXIT INT TERM

# Logging --------------------------------------------------------------------
log_info() { echo -e "\033[34m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
log_success() { echo -e "\033[32m[SUCCESS]\033[0m $*" >&2; }

subcontainer_dir_has_content() {
  local dir=$1
  [[ -d "$dir" ]] || return 1
  find "$dir" -mindepth 1 -not -name .git -print -quit 2>/dev/null | grep -q . || return 1
  return 0
}

github_repo_status_code() {
  local repo=$1
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $GITHUB_TOKEN" \
    "$GITHUB_API_URL/repos/luascfl/$repo"
}

reconcile_subcontainer_state() {
  [[ -f "$SUBCONTAINER_STATE_FILE" || -f .gitmodules ]] || return 0
  [[ -n "${GITHUB_TOKEN:-}" ]] || return 0

  local -a cleaned=()
  local -a warn=()

  if [[ -f "$SUBCONTAINER_STATE_FILE" ]]; then
    while IFS='|' read -r subdir repo; do
      [[ -z "$subdir" || -z "$repo" ]] && continue
      local status
      status=$(github_repo_status_code "$repo")
      case "$status" in
        404|301)
          if subcontainer_dir_has_content "$subdir"; then
            warn+=("$subdir: remote HTTP $status mas pasta local tem conteudo; mantendo")
          else
            remove_submodule_config "$subdir"
            if [[ -d "$subdir" ]]; then
              rm -f "$subdir/.git"
              rmdir "$subdir" 2>/dev/null || true
            fi
            cleaned+=("$subdir (remote HTTP $status, local vazio)")
          fi
          ;;
        200) ;;
        *) warn+=("$subdir: HTTP $status; nao vou agir") ;;
      esac
    done < "$SUBCONTAINER_STATE_FILE"
  fi

  if [[ -f .gitmodules ]]; then
    local name path
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      path=$(git config -f .gitmodules --get "submodule.$name.path" 2>/dev/null || true)
      [[ -z "$path" ]] && continue
      if subcontainer_dir_has_content "$path"; then
        continue
      fi
      if [[ -f "$SUBCONTAINER_STATE_FILE" ]] && grep -qF "$path|" "$SUBCONTAINER_STATE_FILE"; then
        continue
      fi
      remove_submodule_config "$path"
      if [[ -d "$path" ]]; then
        rm -f "$path/.git"
        rmdir "$path" 2>/dev/null || true
      fi
      cleaned+=(".gitmodules orphan: $name")
    done < <(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null | sed -E 's/^submodule\.(.+)\.path$/\1/')
  fi

  if (( ${#cleaned[@]} > 0 )); then
    echo "Reconcile subcontainers removeu:" >&2
    printf '  - %s\n' "${cleaned[@]}" >&2
  fi
  if (( ${#warn[@]} > 0 )); then
    echo "Reconcile subcontainers aviso:" >&2
    printf '  - %s\n' "${warn[@]}" >&2
  fi
}

perform_subcontainer_push_sequence() {
  local repo_name=$1 remote_url=$2 current_branch=$3 script_rel=$4 with_releases=${5:-false}

  SUBCONTAINER_MODE=true
  reconcile_subcontainer_state
  prepare_subcontainer_plan "$repo_name"
  ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
  ensure_remote "$remote_url"
  sync_with_remote "$current_branch"

  if [[ "$with_releases" == "true" ]]; then
      ensure_subcontainers_ready_with_releases
  else
      ensure_subcontainers_ready
  fi

  perform_push "$script_rel" "$current_branch" "$remote_url"
  ensure_remote "$remote_url"
  clear_removed_subcontainers
  run_parent_topic_verifier_auto "$ROOT_REPO_DIR"

  if [[ "$with_releases" == "false" ]] && should_run_global_codex_sync; then
    run_codex_sync
  fi
}

print_usage() {
  cat <<'EOF'
----------------------------------------------------------------
Create and Push Repo Script
----------------------------------------------------------------
This script manages git repositories, handling authentication,
remote creation, and recursive operations for subfolders.

Available Actions:
  push            : Pushes the current directory as a single repo.
  push-recursive  : Scans subfolders and pushes them individually,
                    detecting special types (Codex, Firefox Ext,
                    Releases) automatically.
  reauth          : Updates GitHub/AMO credentials.
  -h, --help      : Shows this help message.
----------------------------------------------------------------
EOF
}

detect_repo_flavor() {
  local dir=$1 name
  name=$(basename "$dir")
  if [[ "$name" == releases* ]]; then
    echo "subcontainer-releases"
    return
  fi
  if [[ "$name" == codex* ]]; then
    echo "subcontainer"
    return
  fi
  if [[ -n $(find "$dir" -maxdepth 1 -name "*.xpi" -print -quit 2>/dev/null) ]]; then
    echo "firefox"
    return
  fi
  echo "plain"
}

main() {
  local repo_dir repo_name script_rel action current_branch remote_url
  ensure_dependencies

  repo_dir=$(pwd)
  repo_name=$(basename "$repo_dir")
  ROOT_REPO_NAME="$repo_name"
  ROOT_REPO_DIR="$repo_dir"
  script_rel=$(script_relative_path "$repo_dir")
  
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help|help)
        print_usage
        return 0
        ;;
    esac
    action=$1
  else
    if [[ -t 0 ]]; then
      action=$(prompt_repo_action "$repo_name")
    else
      action="push"
    fi
  fi

  case "$action" in
    push|push-recursive|reauth) ;;
    *)
      echo "Unknown action '$action'. Use push, push-recursive, or reauth." >&2
      exit 1
      ;;
  esac

  if [[ "$action" == "reauth" ]]; then
    reauth_all_recursively "$repo_dir"
    echo "Lembrete: Para carregar as variáveis no seu ambiente atual, execute com 'source' (ex: source ./create_and_push_repo.sh reauth)." >&2
    return
  fi

  ensure_token
  ensure_git_lfs

  case "$action" in
    push-recursive)
      push_recursive_all
      return
      ;;
  esac

  if ! warn_index_lock; then
    exit 1
  fi

  if ! warn_root_owned; then
    exit 1
  fi

  if remote_should_be_ignored "$repo_name"; then
    delete_remote_repo "$repo_name"
    echo "Repository '$repo_name' is configured to be ignored and will not be pushed." >&2
    return
  fi

  init_git_repo
  ensure_root_commit
  current_branch=$(ensure_main_branch)
  remote_url=$(resolve_remote_url "$repo_name")
  ROOT_REMOTE_URL="$remote_url"

  local flavor
  flavor=$(detect_repo_flavor "$repo_dir")

  case "$action" in
    push)
      case "$flavor" in
        subcontainer-releases)
          perform_subcontainer_push_sequence "$repo_name" "$remote_url" "$current_branch" "$script_rel" "true"
          ;;
        subcontainer)
          perform_subcontainer_push_sequence "$repo_name" "$remote_url" "$current_branch" "$script_rel" "false"
          ;;
        firefox)
          SUBCONTAINER_MODE=false
          ensure_amo_credentials
          if ! submit_extension_to_amo; then
            echo "Aviso: Falha na submissão ao AMO. Continuando com push para GitHub..." >&2
          fi
          ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
          ensure_remote "$remote_url"
          sync_with_remote "$current_branch"
          perform_push "$script_rel" "$current_branch" "$remote_url"
          ensure_remote "$remote_url"
          ;;
        *)
          SUBCONTAINER_MODE=false
          ensure_remote_repo_exists "$repo_name" "$(repo_visibility_from_folder "$repo_name")"
          ensure_remote "$remote_url"
          sync_with_remote "$current_branch"
          perform_push "$script_rel" "$current_branch" "$remote_url"
          ensure_remote "$remote_url"
          ;;
      esac
      ;;
    *)
      echo "Unknown action '$action'." >&2
      exit 1
      ;;
  esac
}

# Dependency / token helpers -------------------------------------------------
ensure_dependencies() {
  local dep missing=()
  for dep in git curl jq python3 git-lfs web-ext; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
    for dep in "${missing[@]}"; do
      log_error "dependency '$dep' was not found in PATH."
    done
    exit 1
  fi

  for dep in "${missing[@]}"; do
    if ! install_dependency "$dep"; then
      log_error "dependency '$dep' was not found in PATH."
      exit 1
    fi
  done

  for dep in "${missing[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log_error "dependency '$dep' was not found in PATH."
      exit 1
    fi
  done

  # Check Git version for 'git switch' support (2.23+)
  if command -v git >/dev/null 2>&1; then
      local git_ver major minor
      git_ver=$(git --version | awk '{print $3}')
      major=$(echo "$git_ver" | cut -d. -f1)
      minor=$(echo "$git_ver" | cut -d. -f2)
      
      if [[ "$major" -lt 2 ]] || [[ "$major" -eq 2 && "$minor" -lt 23 ]]; then
          log_warn "Git version $git_ver is detected. Version 2.23+ is recommended for full script functionality."
      fi
  fi
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_sudo_or_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo not available. Install missing dependencies manually." >&2
    return 1
  fi
  return 0
}

apt_update_once() {
  if [[ "${__APT_UPDATED:-0}" -eq 1 ]]; then
    return 0
  fi
  if ! run_as_root apt-get update; then
    echo "Error: apt-get update failed. Check your network or sources list." >&2
    return 1
  fi
  __APT_UPDATED=1
  return 0
}

install_apt_package() {
  local pkg=$1
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: apt-get not available. Install '$pkg' manually." >&2
    return 1
  fi
  ensure_sudo_or_root || return 1
  apt_update_once || return 1
  if ! run_as_root apt-get install -y "$pkg"; then
    echo "Error: failed to install '$pkg' via apt-get." >&2
    return 1
  fi
  return 0
}

install_web_ext() {
  if command -v apt-get >/dev/null 2>&1 && apt-cache show web-ext >/dev/null 2>&1; then
    install_apt_package web-ext
    return $?
  fi

  if ! command -v npm >/dev/null 2>&1; then
    install_apt_package nodejs || return 1
    install_apt_package npm || return 1
  fi

  ensure_sudo_or_root || return 1
  if ! run_as_root npm install -g web-ext; then
    echo "Error: failed to install 'web-ext' via npm." >&2
    return 1
  fi
  return 0
}

install_dependency() {
  local dep=$1
  case "$dep" in
    web-ext)
      install_web_ext
      ;;
    git-lfs)
      install_apt_package git-lfs
      ;;
    git|curl|python3)
      install_apt_package "$dep"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_git_lfs() {
  if ! command -v git-lfs >/dev/null 2>&1; then
    echo "Error: git-lfs is required but not installed." >&2
    exit 1
  fi
  git lfs install --skip-repo >/dev/null 2>&1 || true
}

ensure_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    ROOT_TOKEN_FILE=$(pwd)/GITHUB_TOKEN.txt
    return
  fi

  local token_file
  if token_file=$(find_token_file); then
    if load_token_from_file "$token_file"; then
      export GITHUB_TOKEN
      ROOT_TOKEN_FILE="$token_file"
      return
    fi
  fi

  log_error "provide GITHUB_TOKEN via environment variable or file."
  exit 1
}

find_token_file() {
  local dir=$PWD candidate
  while true; do
    for candidate in "$dir/GITHUB_TOKEN" "$dir/GITHUB_TOKEN.txt"; do
      if [[ -f "$candidate" ]]; then
        printf "%s\n" "$candidate"
        return 0
      fi
    done
    if [[ "$dir" == "/" ]]; then
      break
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

load_token_from_file() {
  local token_file=$1 token
  token=$(python3 - "$token_file" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8")
except Exception:
    sys.exit(1)
line = text.splitlines()[0] if text else ""
print(line.lstrip("\ufeff"), end="")
PY
) || return 1

  if [[ -n "$token" ]]; then
    GITHUB_TOKEN=$token
    ROOT_TOKEN_FILE="$token_file"
    return 0
  fi
  return 1
}

propagate_credentials_to_subdir() {
  local subdir=$1

  # GitHub - Propagate to all subrepos
  local gh_target="$subdir/GITHUB_TOKEN.txt"
  if [[ -n "$ROOT_TOKEN_FILE" && -f "$ROOT_TOKEN_FILE" ]]; then
    cp "$ROOT_TOKEN_FILE" "$gh_target"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf "%s\n" "$GITHUB_TOKEN" >"$gh_target"
  fi
  chmod 600 "$gh_target" 2>/dev/null || true

  # Check if subdir is a Firefox extension project
  local is_firefox_extension=false
  if [[ -n $(find "$subdir" -maxdepth 1 -name "manifest*.json" -print -quit) ]] || \
     [[ -n $(find "$subdir" -maxdepth 1 -name "*.xpi" -print -quit) ]]; then
    is_firefox_extension=true
  fi

  if [[ "$is_firefox_extension" == "false" ]]; then
    return
  fi

  # AMO Key - Propagate only to extensions
  local amo_key_target="$subdir/AMO_API_KEY.txt"
  if [[ -f "AMO_API_KEY.txt" ]]; then
    cp "AMO_API_KEY.txt" "$amo_key_target"
    chmod 600 "$amo_key_target" 2>/dev/null || true
  elif [[ -n "${AMO_API_KEY:-}" ]]; then
     printf "%s\n" "$AMO_API_KEY" >"$amo_key_target"
     chmod 600 "$amo_key_target" 2>/dev/null || true
  fi

  # AMO Secret - Propagate only to extensions
  local amo_secret_target="$subdir/AMO_API_SECRET.txt"
  if [[ -f "AMO_API_SECRET.txt" ]]; then
    cp "AMO_API_SECRET.txt" "$amo_secret_target"
    chmod 600 "$amo_secret_target" 2>/dev/null || true
  elif [[ -n "${AMO_API_SECRET:-}" ]]; then
     printf "%s\n" "$AMO_API_SECRET" >"$amo_secret_target"
     chmod 600 "$amo_secret_target" 2>/dev/null || true
  fi
}

reauth_github_token() {
  local repo_dir=${1:-$PWD} token target login=""
  target="$repo_dir/GITHUB_TOKEN.txt"

  echo "Re-authenticating GitHub token. It will be saved to: $target" >&2
  read -rsp "Enter new GitHub PAT (input hidden, leave blank to skip): " token
  echo
  if [[ -z "$token" ]]; then
    echo "GitHub token update skipped." >&2
    return
  fi

  printf "%s\n" "$token" >"$target"
  chmod 600 "$target" 2>/dev/null || true
  
  local central_target="${CENTRAL_CONFIG_DIR}/GITHUB_TOKEN.txt"
  if [[ "$(realpath "$target")" != "$(realpath "$central_target")" ]]; then
     cp "$target" "$central_target"
     chmod 600 "$central_target" 2>/dev/null || true
     echo "Token backup updated at $central_target" >&2
  fi

  export GITHUB_TOKEN="$token"
  ROOT_TOKEN_FILE="$target"

  if validate_github_token "$token" login; then
    echo "Token validated for GitHub user '$login' and saved to $target" >&2
  else
    echo "Token saved to $target but validation failed. Check scopes/network." >&2
  fi
}

validate_github_token() {
  local token=$1 login_var=$2 tmp status login=""
  tmp=$(mktemp)
  status=$(curl -sS -w "%{http_code}" -o "$tmp" \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user)
  if [[ "$status" != "200" ]]; then
    rm -f "$tmp"
    return 1
  fi

  login=$(python3 - "$tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    print(data.get("login", ""))
except Exception:
    pass
PY
)
  rm -f "$tmp"
  if [[ -n "$login_var" ]]; then
    printf -v "$login_var" '%s' "$login"
  fi
  return 0
}

reauth_amo_credentials() {
  local repo_dir=$1 key secret
  local key_file="$repo_dir/AMO_API_KEY.txt"
  local secret_file="$repo_dir/AMO_API_SECRET.txt"
  local central_key="${CENTRAL_CONFIG_DIR}/AMO_API_KEY.txt"
  local central_secret="${CENTRAL_CONFIG_DIR}/AMO_API_SECRET.txt"

  echo "Updating AMO Credentials..." >&2
  read -rsp "Enter AMO API Key (Issuer): " key
  echo
  if [[ -n "$key" ]]; then
    printf "%s\n" "$key" >"$key_file"
    chmod 600 "$key_file" 2>/dev/null || true
    
    if [[ "$(realpath "$key_file")" != "$(realpath "$central_key")" ]]; then
      cp "$key_file" "$central_key"
      chmod 600 "$central_key" 2>/dev/null || true
      echo "AMO Key backup updated at $central_key" >&2
    fi
    
    export AMO_API_KEY="$key"
    echo "AMO API Key saved to $key_file" >&2
  fi

  read -rsp "Enter AMO API Secret: " secret
  echo
  if [[ -n "$secret" ]]; then
    printf "%s\n" "$secret" >"$secret_file"
    chmod 600 "$secret_file" 2>/dev/null || true
    
    if [[ "$(realpath "$secret_file")" != "$(realpath "$central_secret")" ]]; then
      cp "$secret_file" "$central_secret"
      chmod 600 "$central_secret" 2>/dev/null || true
      echo "AMO Secret backup updated at $central_secret" >&2
    fi

    export AMO_API_SECRET="$secret"
    echo "AMO API Secret saved to $secret_file" >&2
  fi
}

reauth_all_recursively() {
  local repo_dir=$1
  
  # 1. GitHub
  reauth_github_token "$repo_dir"

  # 2. AMO
  echo
  read -rp "Do you want to update Firefox AMO credentials? [y/N] " yesno
  if [[ "$yesno" =~ ^[Yy]$ ]]; then
    reauth_amo_credentials "$repo_dir"
  fi

  # 3. Recursion
  echo
  echo "Propagating credentials to immediate subdirectories..."
  local base_dir=$repo_dir
  local path subdir
  while IFS= read -r -d '' path; do
    subdir=${path#"$base_dir"/}
    [[ -z "$subdir" || "${subdir:0:1}" == "." ]] && continue
    
    if [[ -f "$path/create_and_push_repo.sh" ]]; then
       echo "  -> $subdir"
       propagate_credentials_to_subdir "$path"
    fi
  done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  echo "Credentials propagation complete."
}

# AMO Credentials ------------------------------------------------------------
ensure_amo_credentials() {
  local missing_creds=0

  if ! load_secret_into_var AMO_API_KEY AMO_API_KEY AMO_API_KEY.txt; then
    create_secret_placeholder AMO_API_KEY.txt "chave AMO API Key"
    log_error "Please define AMO_API_KEY or create AMO_API_KEY.txt."
    missing_creds=1
  fi

  if ! load_secret_into_var AMO_API_SECRET AMO_API_SECRET AMO_API_SECRET.txt; then
    create_secret_placeholder AMO_API_SECRET.txt "chave AMO API Secret"
    log_error "Please define AMO_API_SECRET or create AMO_API_SECRET.txt."
    missing_creds=1
  fi

  if [[ $missing_creds -ne 0 ]]; then
    log_info "Tip: generate credentials at https://addons.mozilla.org/developers/addon/api/key and paste the key/secret in the first line of each file."
    exit 1
  fi
}

create_secret_placeholder() {
  local filename=$1
  local label=$2
  local amo_url="https://addons.mozilla.org/developers/addon/api/key"

  if [[ -e "$filename" ]]; then
    return
  fi

  cat >"$filename" <<EOF

# Cole sua $label na primeira linha deste arquivo.
# Gere novas credenciais no Portal de Desenvolvedores do Firefox: $amo_url
EOF

  echo "Arquivo '$filename' criado." >&2
  echo "Acesse $amo_url para gerar a sua $label e cole o valor na primeira linha de '$filename'." >&2
}

load_secret_into_var() {
  local var_name=$1
  shift

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi

  local value candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      value=$(read_first_line "$candidate") || continue
      if [[ -n "$value" ]]; then
        printf -v "$var_name" '%s' "$value"
        declare -x "$var_name"
        return 0
      fi
    fi
  done

  return 1
}

read_first_line() {
  local path=$1
  python3 - "$path" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8")
except Exception:
    sys.exit(1)

line = text.splitlines()[0] if text else ""
print(line.lstrip("\ufeff"), end="")
PY
}

# AMO Submission -------------------------------------------------------------
submit_extension_to_amo() {
  local channel=${AMO_CHANNEL:-listed}
  ensure_webext_ignore

  local artifacts_dir=${AMO_ARTIFACTS_DIR:-.web-ext-artifacts}
  mkdir -p "$artifacts_dir"

  # Manifest Swapping Logic
  local original_manifest="manifest.json"
  local firefox_manifest=""
  local backup_manifest="manifest.json.bak_amo"
  local swapped=0

  if [[ -f "manifest-firefox-mv3.json" ]]; then
    firefox_manifest="manifest-firefox-mv3.json"
  elif [[ -f "manifest-firefox-mv2.json" ]]; then
    firefox_manifest="manifest-firefox-mv2.json"
  fi

  if [[ -n "$firefox_manifest" ]]; then
    echo "Hybrid repo detected: Swapping $firefox_manifest to manifest.json for AMO submission..." >&2
    if [[ -f "$original_manifest" ]]; then
      cp "$original_manifest" "$backup_manifest"
    fi
    cp "$firefox_manifest" "$original_manifest"
    swapped=1
  fi

  # AUTO-FIX VALIDATION ERRORS
  fix_manifest_errors "$original_manifest"

  # Check version to avoid redundant submission
  local current_version last_version
  current_version=$(python3 -c "import json, sys; print(json.load(open('$original_manifest')).get('version', ''))" 2>/dev/null || echo "")
  
  if [[ -f ".amo-last-version" ]]; then
    last_version=$(cat ".amo-last-version")
  else
    last_version=""
  fi

  if [[ -n "$current_version" && "$current_version" == "$last_version" ]]; then
    echo "AMO: Version $current_version already submitted. Skipping." >&2
    # Restore Original Manifest if swapped
    if [[ $swapped -eq 1 ]]; then
      if [[ -f "$backup_manifest" ]]; then
        mv "$backup_manifest" "$original_manifest"
      else
        rm "$original_manifest"
      fi
    fi
    return 0
  fi

  local metadata_file=${AMO_METADATA_FILE:-amo-metadata.json}
  if [[ ! -f "$metadata_file" ]]; then
    cat >"$metadata_file" <<'EOF'
{
  "version": {
    "custom_license": {
      "name": {
        "en-US": "Mozilla Public License 2.0"
      },
      "text": {
        "en-US": "Mozilla Public License 2.0. Full text: https://www.mozilla.org/MPL/2.0/"
      }
    }
  }
}
EOF
  fi

  local cmd=(web-ext sign
    --api-key "$AMO_API_KEY"
    --api-secret "$AMO_API_SECRET"
    --channel "$channel"
    --artifacts-dir "$artifacts_dir"
    --amo-metadata "$metadata_file"
    --ignore-files "AMO_API_KEY.txt" "AMO_API_SECRET.txt" "GITHUB_TOKEN.txt" "create_and_push_repo.sh" "create_firefox-amo_push_github.sh" "*.sh" ".env*" "screenshots/" ".git/" ".web-ext-artifacts/"
  )

  if [[ -n "${AMO_SOURCE_DIR:-}" ]]; then
    cmd+=(--source-dir "$AMO_SOURCE_DIR")
  fi

  echo "Enviando extensão ao Firefox AMO (canal: $channel)..." >&2
  
  local final_status=0
  
  # LOOP FOR RETRY (THROTTLING)
  while true; do
      set +e
      # Execute web-ext in background and monitor output for early success
      rm -f web-ext-output.log
      "${cmd[@]}" > web-ext-output.log 2>&1 &
      local pid=$!
      
      local start_time
      start_time=$(date +%s)
      local max_wait=600 # 10 min hard timeout
      local found_success=0
      
      echo "Monitorando submissão (PID $pid)..." >&2
      
      # Wait for log creation
      while [[ ! -f web-ext-output.log ]] && kill -0 $pid 2>/dev/null; do sleep 0.5; done

      while kill -0 $pid 2>/dev/null; do
        if (( $(date +%s) - start_time > max_wait )); then
          echo "Timeout atingido. Encerrando..." >&2
          kill $pid
          break
        fi

        if grep -Eq "Waiting for approval|Your add-on has been submitted|Validation results:" web-ext-output.log; then
           echo "Sucesso na submissão detectado! Encerrando espera..." >&2
           kill $pid 2>/dev/null || true
           found_success=1
           break
        fi
        
        sleep 2
      done
      
      wait $pid 2>/dev/null
      local exit_code=$?
      set -e
      
      if [[ $found_success -eq 1 ]]; then
        final_status=0
        break # Success!
      else
        final_status=$exit_code
      fi

      if [[ $final_status -ne 0 ]]; then
          # Check for Throttling
          local wait_seconds
          wait_seconds=$(python3 - <<'PY'
import sys, re
try:
    with open("web-ext-output.log", "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
        m = re.search(r"Expected available in (\d+) seconds", content)
        if m:
            print(m.group(1))
except:
    pass
PY
)
          if [[ -n "$wait_seconds" ]]; then
              local max_allowed_wait=300
              if (( wait_seconds > max_allowed_wait )); then
                  echo "Aviso: O tempo de espera do AMO ($wait_seconds s) excede o limite de ${max_allowed_wait}s. Pulando submissão..." >&2
                  final_status=1
                  break
              fi
              local sleep_time=$((wait_seconds + 5))
              echo "Throttling detectado. O AMO pediu para esperar $wait_seconds segundos." >&2
              echo "Aguardando $sleep_time segundos antes de tentar novamente..." >&2
              sleep "$sleep_time"
              echo "Retentando..." >&2
              continue # Retry loop
          else
              # Not a throttling error, break and fail
              cat web-ext-output.log >&2
              break
          fi
      else
          # Success (exit code 0 natural)
          echo "Log de sucesso (tail):" >&2
          tail -n 5 web-ext-output.log >&2
          
          # UPDATE LAST SUCCESSFUL VERSION
          if [[ -n "$current_version" ]]; then
             echo "$current_version" > ".amo-last-version"
          fi
          
          break
      fi
  done
  
  rm -f web-ext-output.log

  # Restore Original Manifest
  if [[ $swapped -eq 1 ]]; then
    echo "Restoring original manifest..." >&2
    if [[ -f "$backup_manifest" ]]; then
      mv "$backup_manifest" "$original_manifest"
    else
      rm "$original_manifest"
    fi
  fi

  if [[ $final_status -ne 0 ]]; then
    echo "Erro: Falha na submissão ao AMO. (Status $final_status)" >&2
    return 1
  fi

  echo "Submissão ao AMO concluída com sucesso." >&2
  return 0
}

ensure_webext_ignore() {
  local ignore_file=".web-extignore"
  local entries=(
    ".git"
    ".github"
    ".web-ext-artifacts"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET"
    "AMO_API_SECRET.txt"
    "gemini-gcloud-key.json"
    "create_and_push_repo.sh"
    "create_firefox-amo_push_github.sh"
    "install-addon-policy.sh"
    "README.md"
    "updates.json"
    "screenshots"
    ".env"
    "*.env"
    ".env.*"
    "*.sh" 
  )

  # Ensure file exists
  touch "$ignore_file"

  # Append missing entries
  for entry in "${entries[@]}"; do
    if ! grep -Fq "$entry" "$ignore_file"; then
       printf "%s\n" "$entry" >>"$ignore_file"
    fi
  done
}

fix_manifest_errors() {
  local manifest_file=$1
  local folder_name
  folder_name=$(basename "$PWD")

  echo "Running auto-fixer on $manifest_file..." >&2

  python3 - "$manifest_file" "$folder_name" <<'PY'
import sys, json, os

manifest_path = sys.argv[1]
folder_name = sys.argv[2]

try:
    with open(manifest_path, 'r', encoding="utf-8") as f:
        data = json.load(f)
    
    changed = False

    # 1. Ensure browser_specific_settings.gecko.id exists
    if "browser_specific_settings" not in data:
        data["browser_specific_settings"] = {}
        changed = True
    
    if "gecko" not in data["browser_specific_settings"]:
        data["browser_specific_settings"]["gecko"] = {}
        changed = True
        
    if "id" not in data["browser_specific_settings"]["gecko"]:
        # Generate ID based on folder name
        # Sanitize folder name for ID
        sanitized = "".join(c if c.isalnum() else "-" for c in folder_name).lower()
        generated_id = f"{sanitized}@luascfl"
        data["browser_specific_settings"]["gecko"]["id"] = generated_id
        changed = True
        print(f"Auto-Fix: Added ID {generated_id}")

    # 2. Fix Data Collection Permissions (required for Gecko)
    if "data_collection_permissions" not in data["browser_specific_settings"]["gecko"]:
         data["browser_specific_settings"]["gecko"]["data_collection_permissions"] = {
             "required": ["none"],
             "optional": [],
             "has_previous_consent": False
         }
         changed = True
         print("Auto-Fix: Added default data_collection_permissions")

    # 3. Fix MV3 Service Worker -> Background Scripts (Firefox compat)
    # Firefox MV3 uses "background": { "scripts": ["file.js"] } instead of "service_worker"
    if data.get("manifest_version") == 3:
        bg = data.get("background", {})
        if "service_worker" in bg:
            sw_file = bg["service_worker"]
            del data["background"]["service_worker"]
            data["background"]["scripts"] = [sw_file]
            # Often useful to set type: module implies strict mode, 
            # but usually just swapping key is enough for basic shim.
            changed = True
            print(f"Auto-Fix: Converted background.service_worker to background.scripts for Firefox")

    if changed:
        with open(manifest_path, 'w', encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write('\n')
except Exception as e:
    print(f"Error fixing manifest: {e}", file=sys.stderr)
    sys.exit(1)
PY
}
# Repo setup -----------------------------------------------------------------
script_relative_path() {
  local repo_dir=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath --relative-to="$repo_dir" "$0" 2>/dev/null || basename "$0"
    return
  fi

  python3 - "$repo_dir" "$0" <<'PY'
import os, sys
repo, script = map(os.path.abspath, sys.argv[1:])
try:
    print(os.path.relpath(script, repo))
except ValueError:
    print(os.path.basename(script))
PY
}

prompt_repo_action() {
  local repo_name=$1 choice
  echo "----------------------------------------------------------------" >&2
  echo "Create and Push Repo Script" >&2
  echo "----------------------------------------------------------------" >&2
  echo "This script manages git repositories, handling authentication," >&2
  echo "remote creation, and recursive operations for subfolders." >&2
  echo "" >&2
  echo "Available Actions:" >&2
  echo "  push            : Pushes the current directory as a single repo." >&2
  echo "  push-recursive  : Scans subfolders and pushes them individually," >&2
  echo "                    detecting special types (Codex, Firefox Ext," >&2
  echo "                    Releases) automatically." >&2
  echo "  reauth          : Updates GitHub/AMO credentials." >&2
  echo "----------------------------------------------------------------" >&2
  
  while true; do
    if ! read -rp "Choose action for repository '$repo_name' [push/push-recursive/reauth] (default: push): " choice; then
      choice=""
    fi
    case "${choice,,}" in
      ""|push) echo "push"; return ;;
      reauth|auth|token)
        echo "reauth"
        return
        ;;
      *) echo "Invalid input. Type 'push', 'push-recursive', or 'reauth'." >&2 ;; 
    esac
  done
}

init_git_repo() {
  if [[ ! -d .git ]]; then
    git init >/dev/null 2>&1
  fi
}

warn_root_owned() {
  local root_items
  mapfile -t root_items < <(find "$ROOT_REPO_DIR" -maxdepth 1 -user root -print 2>/dev/null)
  if [[ ${#root_items[@]} -eq 0 ]]; then
    return 0
  fi
  echo "Detecção de itens carregados por root (não há permissão para chown sozinho):" >&2
  for p in "${root_items[@]}"; do
    printf '  %s\n' "$p" >&2
  done
  printf 'Execute o sudo chown -R lucas:lucas %s\n' "${root_items[*]}" >&2
  return 1
}

warn_index_lock() {
  local locks=()
  while IFS= read -r -d '' file; do
    locks+=("$file")
  done < <(find "$ROOT_REPO_DIR" -name "index.lock" -print0 2>/dev/null)
  if [[ ${#locks[@]} -eq 0 ]]; then
    return 0
  fi
  echo "Atenção: existem arquivos index.lock ativos:" >&2
  for lock in "${locks[@]}"; do
    printf '  %s\n' "$lock" >&2
  done
  echo "Remova-os (rm <caminho>) ou encerre o processo antes de rodar novamente." >&2
  return 1
}

ensure_root_commit() {
  if git rev-parse HEAD >/dev/null 2>&1; then
    return
  fi
  git add . >/dev/null 2>&1 || true
  GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-luascfl}" \
  GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-luascfl@example.com}" \
  GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-luascfl}" \
  GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-luascfl@example.com}" \
  git commit --allow-empty -m "initial commit" >/dev/null 2>&1 || true
}

ensure_main_branch() {
  local current
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -z "$current" || "$current" == "HEAD" ]]; then
    git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || git branch -M main
    current="main"
  elif [[ "$current" != "main" ]]; then
    git branch -M "$current" main
    current="main"
  fi
  echo "$current"
}

resolve_remote_url() {
  local repo_name=$1
  case "${GITHUB_REMOTE_PROTOCOL:-https}" in
    ssh) echo "git@github.com:luascfl/$repo_name.git" ;; 
    https|*) echo "https://github.com/luascfl/$repo_name.git" ;; 
  esac
}

repo_visibility_from_folder() {
  local folder_name=$1
  if [[ "$folder_name" == tmp_* ]]; then
    echo "private"
  else
    echo "public"
  fi
}

github_repo_exists() {
  local repo_name=$1 status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "$GITHUB_API_URL/repos/luascfl/$repo_name")
  [[ "$status" == "200" ]]
}

github_rename_repo() {
  local old_name=$1 new_name=$2 response status
  response=$(mktemp)
  status=$(curl -sS -o "$response" -w "%{http_code}" \
    -X PATCH \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"$new_name\"}" \
    "$GITHUB_API_URL/repos/luascfl/$old_name")
  if [[ "$status" != "200" ]]; then
    echo "Failed to rename GitHub repo '$old_name' to '$new_name' (status $status)." >&2
    cat "$response" >&2
  else
    echo "Renamed GitHub repo '$old_name' to '$new_name'." >&2
  fi
  rm -f "$response"
}

extract_submodule_module_name_from_gitdir() {
  local subdir=$1 gitfile line raw
  gitfile="$subdir/.git"
  [[ -f "$gitfile" ]] || return
  line=$(head -n 1 "$gitfile" 2>/dev/null || true)
  [[ "$line" == gitdir:* ]] || return
  raw=${line#gitdir:}
  raw=${raw##[[:space:]]}
  raw=${raw%%$'\r'}
  printf '%s' "${raw##*/}"
}

detect_previous_subdir_from_gitdir() {
  local subdir=$1 module_name
  module_name=$(extract_submodule_module_name_from_gitdir "$subdir")
  [[ -z "$module_name" || "$module_name" == "$subdir" ]] && return
  printf '%s' "$module_name"
}

detect_previous_subdir_path() {
  local subdir=$1 rename_line
  rename_line=$(git -C "$ROOT_REPO_DIR" log --diff-filter=R --name-status --pretty=format:'' -- "$subdir" 2>/dev/null | awk '/^R/ {print $2; exit}')
  if [[ -z "$rename_line" ]]; then
    rename_line=$(detect_previous_subdir_from_gitdir "$subdir")
  fi
  printf '%s' "$rename_line"
}

handle_subcontainer_remote_rename() {
  local subdir=$1 current_repo=$2 old_path old_repo
  if [[ -z "$ROOT_REPO_DIR" ]]; then
    return
  fi
  old_path=$(detect_previous_subdir_path "$subdir")
  [[ -z "$old_path" || "$old_path" == "$subdir" ]] && return
  old_repo=$(format_subcontainer_repo_name "$ROOT_REPO_NAME" "$old_path")
  if [[ "$old_repo" == "$current_repo" ]]; then
    return
  fi
  if github_repo_exists "$current_repo"; then
    return
  fi
  if ! github_repo_exists "$old_repo"; then
    return
  fi
  echo "Detected rename: '$old_path' -> '$subdir'. Renaming remote from '$old_repo' to '$current_repo'." >&2
  github_rename_repo "$old_repo" "$current_repo"
}

remote_should_be_ignored() {
  local repo=$1 ignored
  for ignored in "${IGNORED_REMOTE_REPOS[@]}"; do
    if [[ "$repo" == "$ignored" ]]; then
      return 0
    fi
  done
  return 1
}

delete_remote_repo() {
  local repo_name=$1 response status curl_exit
  response=$(mktemp)
  set +e
  status=$(curl -sS -w "%{http_code}" -o "$response" \
    -X DELETE \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/luascfl/$repo_name")
  curl_exit=$?
  set -e

  case "$status" in
    204)
      echo "Deleted ignored remote 'luascfl/$repo_name'." >&2
      ;;
    404)
      echo "Ignored remote 'luascfl/$repo_name' not found; nothing to delete." >&2
      ;;
    *)
      echo "Failed to delete ignored remote 'luascfl/$repo_name' (HTTP $status, curl $curl_exit)." >&2
      cat "$response" >&2
      ;;
  esac
  rm -f "$response"
}

ensure_remote_repo_exists() {
  local repo_name=$1 visibility=${2:-public} private_flag
  case "$visibility" in
    private|true|1) private_flag=true ;; 
    *) private_flag=false ;; 
  esac

  # OPTIMIZATION: Check if repo exists to avoid Rate Limit on Creation (POST)
  local check_status
  check_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/luascfl/$repo_name")
  
  if [[ "$check_status" == "200" ]]; then
     # Repository exists, skip creation
     return
  fi

  local response http_status
  response=$(mktemp)
  http_status=$(curl -sS -w "%{http_code}" -o "$response" \
    -X POST "https://api.github.com/user/repos" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"$repo_name\",\"private\":$private_flag}")

  case "$http_status" in
    201) ;; 
    422) echo "Warning: repository '$repo_name' already exists in luascfl. Continuing." >&2 ;; 
    *) echo "Error creating repository (status $http_status):" >&2
       cat "$response" >&2
       rm -f "$response"
       exit 1 ;; 
  esac
  rm -f "$response"
}

sanitize_topic_segment() {
  local value=$1
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  value=${value//[^a-z0-9]/-}
  while [[ "$value" == *--* ]]; do
    value=${value//--/-}
  done
  value=${value##-}
  value=${value%%-}
  if [[ -z "$value" ]]; then
    value="repo"
  fi
  printf "%s" "$value"
}

build_parent_repo_topic() {
  local root_repo=$1 sanitized
  sanitized=$(sanitize_topic_segment "$root_repo")
  printf "parent-%s" "$sanitized"
}

ensure_repo_contains_topic() {
  local repo_name=$1 topic=$2 get_response put_response get_status put_status payload
  [[ -z "$topic" ]] && return
  get_response=$(mktemp)
  get_status=$(curl -sS -w "%{http_code}" -o "$get_response" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/luascfl/$repo_name/topics")

  case "$get_status" in
    200)
      payload=$(python3 - "$get_response" "$topic" <<'PY'
import json
import sys

path, topic = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
existing = data.get("names") or []
merged = []
seen = set()
for item in [*existing, topic]:
    if not isinstance(item, str):
        continue
    normalized = item.strip().lower()
    if not normalized or normalized in seen:
        continue
    seen.add(normalized)
    merged.append(normalized)
print(json.dumps({"names": merged}, separators=(",", ":")))
PY
      )
      ;;
    404)
      echo "Topic sync skipped for '$repo_name' because repository was not found." >&2
      rm -f "$get_response"
      return
      ;;
    *)
      echo "Failed to read topics for '$repo_name' (HTTP $get_status)." >&2
      cat "$get_response" >&2
      rm -f "$get_response"
      return
      ;;
  esac
  rm -f "$get_response"

  put_response=$(mktemp)
  put_status=$(curl -sS -w "%{http_code}" -o "$put_response" \
    -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/luascfl/$repo_name/topics" \
    -d "$payload")

  case "$put_status" in
    200) ;;
    *)
      echo "Failed to update topics for '$repo_name' (HTTP $put_status)." >&2
      cat "$put_response" >&2
      ;;
  esac
  rm -f "$put_response"
}

ensure_subcontainer_parent_topic() {
  local repo_name=$1 parent_topic
  if [[ -z "${ROOT_REPO_NAME:-}" || "$ROOT_REPO_NAME" != codex* ]]; then
    return
  fi
  parent_topic=$(build_parent_repo_topic "$ROOT_REPO_NAME")
  ensure_repo_contains_topic "$repo_name" "$parent_topic"
}

verify_api_get_topics_status() {
  local owner=$1 repo=$2 token=$3 output_file=$4
  curl -sS -o "$output_file" -w "%{http_code}" \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$owner/$repo/topics"
}

VERIFY_LAST_TOPICS_PUT_STATUS=""

verify_api_apply_expected_topic() {
  local owner=$1 repo=$2 token=$3 expected=$4 current_topics_file=$5 output_file=$6 payload_file
  payload_file=$(mktemp)
  jq --arg topic "$expected" '{names: ((.names // []) + [$topic] | map(ascii_downcase) | unique)}' \
    "$current_topics_file" > "$payload_file"

  VERIFY_LAST_TOPICS_PUT_STATUS=$(curl -sS -o "$output_file" -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    --data-binary @"$payload_file" \
    "https://api.github.com/repos/$owner/$repo/topics")
  rm -f "$payload_file"

  [[ "$VERIFY_LAST_TOPICS_PUT_STATUS" == "200" ]]
}

run_parent_topic_verifier_auto() {
  local base_dir=${1:-${ROOT_REPO_DIR:-$(pwd)}}
  local owner="${GITHUB_OWNER:-luascfl}"
  local token="${GITHUB_TOKEN:-}"

  declare -a codex_roots=()
  declare -A codex_seen=()

  if [[ "$(basename "$base_dir")" == codex* ]]; then
    codex_roots+=("$base_dir")
    codex_seen["$base_dir"]=1
  fi

  local root
  while IFS= read -r -d '' root; do
    [[ -n "${codex_seen[$root]:-}" ]] && continue
    codex_roots+=("$root")
    codex_seen["$root"]=1
  done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -name 'codex*' -print0)

  if [[ ${#codex_roots[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ -z "$token" && -f "$base_dir/GITHUB_TOKEN.txt" ]]; then
    token=$(tr -d '\r\n' < "$base_dir/GITHUB_TOKEN.txt")
  fi
  if [[ -z "$token" && -f "$HOME/Downloads/GITHUB_TOKEN.txt" ]]; then
    token=$(tr -d '\r\n' < "$HOME/Downloads/GITHUB_TOKEN.txt")
  fi
  if [[ -z "$token" ]]; then
    echo "Aviso: sem GITHUB_TOKEN, etapa automática de parent topics foi pulada." >&2
    return 0
  fi

  declare -A expected_topic_by_repo=()
  declare -A source_by_repo=()
  declare -a expected_repos=()

  local root_name parent_topic state_file state_dir subdir repo
  for root in "${codex_roots[@]}"; do
    root_name=$(basename "$root")
    parent_topic=$(build_parent_repo_topic "$root_name")

    while IFS= read -r -d '' state_file; do
      state_dir=$(dirname "$state_file")
      if [[ "$state_dir" == *"/."* ]]; then
        continue
      fi

      while IFS='|' read -r subdir repo; do
        [[ -z "${subdir:-}" ]] && continue
        if [[ -z "${repo:-}" ]]; then
          repo=$(sanitize_repo_segment "$subdir")
        fi
        [[ -z "$repo" ]] && continue

        if [[ -n "${expected_topic_by_repo[$repo]:-}" && "${expected_topic_by_repo[$repo]}" != "$parent_topic" ]]; then
          echo "Conflito: repo '$repo' aparece com parent topics diferentes: '${expected_topic_by_repo[$repo]}' e '$parent_topic'" >&2
        fi

        if [[ -z "${expected_topic_by_repo[$repo]:-}" ]]; then
          expected_repos+=("$repo")
        fi

        expected_topic_by_repo["$repo"]="$parent_topic"
        source_by_repo["$repo"]="$state_file:$subdir"
      done < "$state_file"
    done < <(find "$root" \
      \( -type d \( -name '.git' -o -name '.git_disabled' -o -name '.aligntrue' -o -name '.cache' -o -name 'node_modules' -o -name 'venv' \) -prune \) -o \
      -type f -name '.subcontainers' -print0)
  done

  if [[ ${#expected_repos[@]} -eq 0 ]]; then
    echo "Nenhum repo esperado encontrado em arquivos .subcontainers para verificação." >&2
    return 0
  fi

  printf 'TOPIC_STAGE_BASE_DIR\t%s\n' "$base_dir"
  printf 'TOPIC_STAGE_OWNER\t%s\n' "$owner"
  printf 'TOPIC_STAGE_AUTO_FIX\t1\n'
  printf 'TOPIC_STAGE_CODEX_ROOTS\t%s\n' "${#codex_roots[@]}"
  printf 'TOPIC_STAGE_EXPECTED_REPOS\t%s\n\n' "${#expected_repos[@]}"
  printf 'status\trepo\texpected_topic\tcurrent_topics\tsource\n'

  local tmp_expected_file tmp_topics_response tmp_topics_put_response tmp_repos_page tmp_api_file
  tmp_expected_file=$(mktemp)
  tmp_topics_response=$(mktemp)
  tmp_topics_put_response=$(mktemp)
  tmp_repos_page=$(mktemp)
  tmp_api_file=$(mktemp)

  printf '%s\n' "${expected_repos[@]}" | sort -u > "$tmp_expected_file"

  local ok=0 fixed=0 missing_topic=0 missing_repo=0 api_error=0 fix_error=0
  local expected source status topics fixed_topics body page code count

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    expected=${expected_topic_by_repo[$repo]}
    source=${source_by_repo[$repo]}

    status=$(verify_api_get_topics_status "$owner" "$repo" "$token" "$tmp_topics_response")
    case "$status" in
      200)
        topics=$(jq -r '(.names // []) | join(",")' "$tmp_topics_response")
        if jq -e --arg t "$expected" '(.names // []) | index($t) != null' "$tmp_topics_response" >/dev/null; then
          printf 'ok\t%s\t%s\t%s\t%s\n' "$repo" "$expected" "$topics" "$source"
          ok=$((ok + 1))
        else
          if verify_api_apply_expected_topic "$owner" "$repo" "$token" "$expected" "$tmp_topics_response" "$tmp_topics_put_response"; then
            fixed_topics=$(jq -r '(.names // []) | join(",")' "$tmp_topics_put_response")
            printf 'fixed\t%s\t%s\t%s\t%s\n' "$repo" "$expected" "$fixed_topics" "$source"
            fixed=$((fixed + 1))
          else
            body=$(tr '\n' ' ' < "$tmp_topics_put_response")
            printf 'fix_error\t%s\t%s\tHTTP_%s %s\t%s\n' "$repo" "$expected" "$VERIFY_LAST_TOPICS_PUT_STATUS" "$body" "$source"
            missing_topic=$((missing_topic + 1))
            fix_error=$((fix_error + 1))
          fi
        fi
        ;;
      404)
        printf 'missing_repo\t%s\t%s\t-\t%s\n' "$repo" "$expected" "$source"
        missing_repo=$((missing_repo + 1))
        ;;
      *)
        body=$(tr '\n' ' ' < "$tmp_topics_response")
        printf 'api_error\t%s\t%s\tHTTP_%s %s\t%s\n' "$repo" "$expected" "$status" "$body" "$source"
        api_error=$((api_error + 1))
        ;;
    esac
  done < "$tmp_expected_file"

  printf '\nTOPIC_STAGE_SUMMARY\n'
  printf 'ok\t%s\n' "$ok"
  printf 'fixed\t%s\n' "$fixed"
  printf 'missing_topic\t%s\n' "$missing_topic"
  printf 'missing_repo\t%s\n' "$missing_repo"
  printf 'api_error\t%s\n' "$api_error"
  printf 'fix_error\t%s\n' "$fix_error"

  printf '\nORPHAN_TMP_REPOS_WITHOUT_PARENT_EXPECTATION\n'
  : > "$tmp_api_file"

  for page in 1 2 3 4 5 6; do
    code=$(curl -sS -o "$tmp_repos_page" -w '%{http_code}' \
      -H "Authorization: token $token" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/user/repos?per_page=100&page=$page&affiliation=owner")

    if [[ "$code" != "200" ]]; then
      echo "Falha ao listar repos page=$page HTTP=$code" >&2
      break
    fi

    count=$(jq 'length' "$tmp_repos_page")
    if [[ "$count" -eq 0 ]]; then
      break
    fi

    jq -r '.[] | .name' "$tmp_repos_page" >> "$tmp_api_file"
  done

  while IFS= read -r repo; do
    [[ "$repo" != tmp* ]] && continue
    if [[ -z "${expected_topic_by_repo[$repo]:-}" ]]; then
      status=$(verify_api_get_topics_status "$owner" "$repo" "$token" "$tmp_topics_response")
      if [[ "$status" == "200" ]]; then
        topics=$(jq -r '(.names // []) | join(",")' "$tmp_topics_response")
        printf '%s\t%s\n' "$repo" "$topics"
      else
        printf '%s\tHTTP_%s\n' "$repo" "$status"
      fi
    fi
  done < <(sort -u "$tmp_api_file")

  rm -f "$tmp_expected_file" "$tmp_topics_response" "$tmp_topics_put_response" "$tmp_repos_page" "$tmp_api_file"
}


ensure_remote() {
  local expected=$1 repo_path=${ROOT_REPO_DIR:-.}
  if git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
    local current
    current=$(git -C "$repo_path" remote get-url origin)
    if [[ "$current" != "$expected" ]]; then
      echo "Remote 'origin' pointed to $current. Updating to $expected." >&2
      git -C "$repo_path" remote set-url origin "$expected"
    fi
  else
    git -C "$repo_path" remote add origin "$expected"
  fi
}

restore_root_remote() {
  if [[ -z "${ROOT_REMOTE_URL:-}" ]]; then
    return
  fi
  ensure_remote "$ROOT_REMOTE_URL"
}

# Sync -----------------------------------------------------------------------
sync_with_remote() {
  local branch=$1 allow_pull=${2:-$ALLOW_PULL}
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "Remote branch '$branch' found. Fetching (no pull by default)..." >&2
    if ! git fetch --prune --no-tags origin "$branch"; then
      echo "Warning: fetch failed; skipping sync." >&2
      return 1
    fi

    local local_rev remote_rev base
    local_rev=$(git rev-parse HEAD)
    remote_rev=$(git rev-parse "origin/$branch")
    base=$(git merge-base HEAD "origin/$branch" 2>/dev/null || true)

    if [[ "$local_rev" == "$remote_rev" ]]; then
      echo "Already in sync with origin/$branch." >&2
      return 0
    fi

    if [[ "$local_rev" == "$base" ]]; then
      echo "Local is behind origin/$branch. Pull required." >&2
      if [[ "$allow_pull" == "1" ]]; then
        pull_with_credentials "$branch" && return 0
        echo "Pull failed; please resolve manually." >&2
        return 1
      fi
      echo "Skipping pull to protect local work. Set ALLOW_PULL=1 or run the 'pull' action to enable." >&2
      exit 1
    fi

    if [[ "$remote_rev" == "$base" ]]; then
      echo "Local is ahead of origin/$branch; proceeding without pull." >&2
      return 0
    fi

    echo "Local and origin/$branch have diverged. Pull/rebase required." >&2
    if [[ "$allow_pull" == "1" ]]; then
      pull_with_credentials "$branch" && return 0
      echo "Pull failed; please resolve manually." >&2
      return 1
    fi
    echo "Skipping pull to protect local work. Set ALLOW_PULL=1 or run the 'pull' action to enable." >&2
    exit 1
  else
    echo "Remote branch '$branch' not found. Assuming first push/pull." >&2
  fi
}

# Push -----------------------------------------------------------------------
perform_push() {
  local script_rel=$1 branch=$2 remote_url=$3
  stage_files_excluding_script "$script_rel"
  if commit_changes; then
    echo "Commit created." >&2
  else
    echo "No changes to commit." >&2
  fi

  if push_with_credentials "$branch"; then
    echo "Push completed successfully: $remote_url"
  else
    echo "Push failed." >&2
    exit 1
  fi
}

sync_management_scripts_to_dir() {
  local source_dir=$1 target_dir=$2
  cp "$source_dir/create_and_push_repo.sh" "$target_dir/create_and_push_repo.sh"
  chmod +x "$target_dir/create_and_push_repo.sh" >/dev/null 2>&1 || true
}


push_recursive_all() {
  local base_dir
  local -a pushed=()
  local -a failed=()
  local -a ignored=()
  local path subdir flavor

  base_dir=$(pwd)
  # When invoked inside a single-repo flavor (codex, releases, firefox), delegate to push.
  local cwd_flavor
  cwd_flavor=$(detect_repo_flavor "$base_dir")
  case "$cwd_flavor" in
    subcontainer|subcontainer-releases|firefox)
      echo "Delegating to 'push' for $cwd_flavor flavor at $base_dir" >&2
      ROOT_REPO_NAME=$(basename "$base_dir")
      ROOT_REPO_DIR=$base_dir
      local script_rel
      script_rel=$(script_relative_path "$base_dir")
      init_git_repo
      ensure_root_commit
      local current_branch remote_url
      current_branch=$(ensure_main_branch)
      remote_url=$(resolve_remote_url "$ROOT_REPO_NAME")
      ROOT_REMOTE_URL=$remote_url
      if [[ "$cwd_flavor" == "firefox" ]]; then
        SUBCONTAINER_MODE=false
        ensure_amo_credentials
        if ! submit_extension_to_amo; then
          echo "Aviso: Falha na submissao ao AMO. Continuando com push para GitHub..." >&2
        fi
        ensure_remote_repo_exists "$ROOT_REPO_NAME" "$(repo_visibility_from_folder "$ROOT_REPO_NAME")"
        ensure_remote "$remote_url"
        sync_with_remote "$current_branch"
        perform_push "$script_rel" "$current_branch" "$remote_url"
        ensure_remote "$remote_url"
      else
        local with_releases=false
        [[ "$cwd_flavor" == "subcontainer-releases" ]] && with_releases=true
        perform_subcontainer_push_sequence "$ROOT_REPO_NAME" "$remote_url" "$current_branch" "$script_rel" "$with_releases"
      fi
      return
      ;;
  esac


  echo "==> Starting recursive push for all known types..." >&2

  while IFS= read -r -d '' path; do
    subdir=${path#"$base_dir"/}
    [[ -z "$subdir" ]] && continue
    if [[ "${subdir:0:1}" == "." ]]; then
      continue
    fi
    if remote_should_be_ignored "$subdir"; then
      ignored+=("$subdir (ignored by policy)")
      continue
    fi
    
    # Classify subfolder type; skip dirs without any managed marker
    flavor=$(detect_repo_flavor "$path")
    if [[ "$flavor" == "plain" && ! -f "$path/create_and_push_repo.sh" ]]; then
      ignored+=("$subdir (not a managed repo)")
      continue
    fi
    
    propagate_credentials_to_subdir "$path"
    
    # Update/Install management scripts
    sync_management_scripts_to_dir "$base_dir" "$path"

    echo "==> Recursive processing: '$subdir' (flavor: $flavor)..." >&2
    if (
      cd "$path" && \
      export AMO_API_KEY="${AMO_API_KEY:-}" && \
      export AMO_API_SECRET="${AMO_API_SECRET:-}" && \
      ./create_and_push_repo.sh push < /dev/null
    ); then
      pushed+=("$subdir ($flavor)")
    else
      failed+=("$subdir ($flavor)")
    fi
    sleep 2 # Prevent rate-limiting
  done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  printf '\npush-recursive-all summary:\n' >&2
  printf '  processed:\n' >&2
  if [[ ${#pushed[@]} -gt 0 ]]; then
    for entry in "${pushed[@]}"; do printf '    - %s\n' "$entry" >&2; done
  else
    printf '    (none)\n' >&2
  fi
  printf '  failures:\n' >&2
  if [[ ${#failed[@]} -gt 0 ]]; then
    for entry in "${failed[@]}"; do printf '    - %s\n' "$entry" >&2; done
  else
    printf '    (none)\n' >&2
  fi
  printf '  ignored:\n' >&2
  if [[ ${#ignored[@]} -gt 0 ]]; then
    for entry in "${ignored[@]}"; do printf '    - %s\n' "$entry" >&2; done
  else
    printf '    (none)\n' >&2
  fi
  # Aggregate root-owned items across processed/failed dirs and emit copy-paste chown.
  local -a root_owned=()
  local entry name
  for entry in "${pushed[@]}" "${failed[@]}"; do
    name=${entry%% *}
    while IFS= read -r -d '' p; do
      root_owned+=("$p")
    done < <(find "$base_dir/$name" -maxdepth 1 -user root -print0 2>/dev/null)
  done

  if [[ ${#root_owned[@]} -gt 0 ]]; then
    printf '\nROOT_OWNED_ITEMS detected. Copie e cole para desbloquear:\n' >&2
    printf 'sudo chown -R "$USER:$USER"' >&2
    for p in "${root_owned[@]}"; do
      printf ' \\\n  %q' "$p" >&2
    done
    printf '\n\n' >&2
  fi

  run_parent_topic_verifier_auto "$base_dir"
}

prepare_subcontainer_plan() {
  local root_repo_name=$1
  __SUBCONTAINERS_TO_PUSH=()
  __SUBCONTAINERS_TO_CLEAR=()
  __SUBCONTAINER_COMMITS=()

  declare -A previous=()
  if [[ -f "$SUBCONTAINER_STATE_FILE" ]]; then
    while IFS="|" read -r prev_dir prev_repo; do
      [[ -z "$prev_dir" || -z "$prev_repo" ]] && continue
      previous["$prev_dir"]="$prev_repo"
    done <"$SUBCONTAINER_STATE_FILE"
  fi

  declare -A current=()
  declare -A renamed_previous=()
  local -a subdirs=()
  while IFS= read -r -d '' path; do
    path=${path#./}
    [[ "$path" == ".git" ]] && continue
    [[ "$path" == .* ]] && continue
    [[ "$path" == "venv" ]] && continue
    [[ "$path" == "logs" ]] && continue
    
    # Skip excluded items from DEFAULT_INDEX_EXCLUDES
    local excluded=false
    for skip in "${DEFAULT_INDEX_EXCLUDES[@]}"; do
      if [[ "$path" == "$skip" ]]; then
        excluded=true
        break
      fi
    done
    [[ "$excluded" == "true" ]] && continue

    subdirs+=("$path")
  done < <(find . -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  local subdir repo_name visibility old_hint
  for subdir in "${subdirs[@]}"; do
    repo_name=$(format_subcontainer_repo_name "$root_repo_name" "$subdir")
    visibility=$(repo_visibility_from_folder "$subdir")
    current["$subdir"]="$repo_name"
    __SUBCONTAINERS_TO_PUSH+=("$subdir|$repo_name|$visibility")

    old_hint=$(detect_previous_subdir_from_gitdir "$subdir")
    if [[ -n "$old_hint" && -n "${previous[$old_hint]+_}" ]]; then
      renamed_previous["$old_hint"]="$subdir"
    fi
  done

  local prev_dir
  for prev_dir in "${!previous[@]}"; do
    if [[ -n "${renamed_previous[$prev_dir]+_}" ]]; then
      continue
    fi
    if [[ -z "${current[$prev_dir]+_}" ]]; then
      __SUBCONTAINERS_TO_CLEAR+=("$prev_dir|${previous[$prev_dir]}")
      remove_submodule_config "$prev_dir"
    fi
  done

  {
    for subdir in "${!current[@]}"; do
      printf "%s|%s\n" "$subdir" "${current[$subdir]}"
    done | sort
  } >"$SUBCONTAINER_STATE_FILE"
}

ensure_subcontainers_ready() {
  if [[ ${#__SUBCONTAINERS_TO_PUSH[@]} -eq 0 ]]; then
    echo "No subfolders detected to manage as submodules." >&2
    return
  fi

  local entry subdir repo visibility
  for entry in "${__SUBCONTAINERS_TO_PUSH[@]}"; do
    IFS="|" read -r subdir repo visibility <<<"$entry"
    ensure_single_subcontainer_ready "$subdir" "$repo" "$visibility"
  done
}

ensure_subcontainers_ready_with_releases() {
  if [[ ${#__SUBCONTAINERS_TO_PUSH[@]} -eq 0 ]]; then
    echo "No subfolders detected to manage as submodules." >&2
    return
  fi

  local entry subdir repo visibility
  for entry in "${__SUBCONTAINERS_TO_PUSH[@]}"; do
    IFS="|" read -r subdir repo visibility <<<"$entry"
    ensure_single_subcontainer_ready "$subdir" "$repo" "$visibility"
    create_release_for_subdir "$subdir" "$repo"
  done
}

create_release_for_subdir() {
  local subdir=$1 repo_name=$2
  
  # Find APK file
  local apk_file
  apk_file=$(find "$subdir" -maxdepth 1 -name "*.apk" -print -quit)
  
  if [[ -z "$apk_file" ]]; then
    echo "No APK found in $subdir, skipping release creation." >&2
    return
  fi
  
  local filename
  filename=$(basename "$apk_file")
  
  # Extract version from filename (e.g., AppName_v1.2.3.apk -> v1.2.3)
  local version
  if [[ "$filename" =~ v([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    version="v${BASH_REMATCH[1]}"
  else
    # Fallback to timestamp if no version found
    version="release-$(date +%Y%m%d-%H%M%S)"
  fi
  
  echo "Verifying release $version for $repo_name..." >&2
  
  # Create tag
  git -C "$subdir" tag -a "$version" -m "Release $version" 2>/dev/null || true
  
  # Push tag
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    run_with_https_credentials git -C "$subdir" push origin "$version" >/dev/null 2>&1 || true
  else
    git -C "$subdir" push origin "$version" >/dev/null 2>&1 || true
  fi
  
  # Create Release via API using Python
  python3 - "$repo_name" "$version" "$apk_file" "$GITHUB_TOKEN" <<'PY'
import sys, requests, os

repo, tag, apk_path, token = sys.argv[1:]
filename = os.path.basename(apk_path)
headers = {'Authorization': f'token {token}', 'Accept': 'application/vnd.github.v3+json'}

# 1. Get or Create Release
url = f'https://api.github.com/repos/luascfl/{repo}/releases/tags/{tag}'
r = requests.get(url, headers=headers)

if r.status_code == 404:
    print(f"Creating new release for {tag}...")
    url_create = f'https://api.github.com/repos/luascfl/{repo}/releases'
    data = {'tag_name': tag, 'name': f'Release {tag}', 'body': 'Automated release', 'draft': False, 'prerelease': False}
    r = requests.post(url_create, headers=headers, json=data)
    if r.status_code != 201:
        print(f"Error creating release: {r.text}")
        sys.exit(1)
    release = r.json()
else:
    # Release exists, silently proceed
    release = r.json()

# 2. Upload Asset
upload_url = release['upload_url'].replace('{?name,label}', '')
existing_assets = [a['name'] for a in release.get('assets', [])]

if filename in existing_assets:
    print(f"Asset {filename} already present.")
elif os.path.exists(apk_path):
    print(f"Uploading {filename}...")
    with open(apk_path, 'rb') as f:
        data = f.read()
    
    headers_upload = headers.copy()
    headers_upload['Content-Type'] = 'application/vnd.android.package-archive'
    
    r_up = requests.post(f'{upload_url}?name={filename}', headers=headers_upload, data=data)
    if r_up.status_code == 201:
        print(f"Success! Download link: {r_up.json().get('browser_download_url')}")
    elif r_up.status_code == 422:
        print("Asset already uploaded.")
    else:
        print(f"Upload failed: {r_up.text}")
else:
    print(f"File not found: {apk_path}")
PY
}

is_subcontainer_git_repo_ready() {
  local subdir=$1 toplevel subdir_real top_real
  toplevel=$(git -C "$subdir" rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n "$toplevel" ]] || return 1
  subdir_real=$(cd "$subdir" && pwd -P)
  top_real=$(cd "$toplevel" && pwd -P)
  [[ "$top_real" == "$subdir_real" ]]
}

repair_submodule_gitdir_if_needed() {
  local subdir=$1 gitfile line raw module_name old_module_path new_module_path
  gitfile="$subdir/.git"
  [[ -f "$gitfile" ]] || return

  if is_subcontainer_git_repo_ready "$subdir"; then
    return
  fi

  line=$(head -n 1 "$gitfile" 2>/dev/null || true)
  [[ "$line" == gitdir:* ]] || return
  raw=${line#gitdir:}
  raw=${raw##[[:space:]]}
  raw=${raw%%$'\r'}
  module_name=${raw##*/}
  [[ -z "$module_name" ]] && return

  old_module_path=".git/modules/$module_name"
  new_module_path=".git/modules/$subdir"

  if [[ "$module_name" != "$subdir" && -d "$old_module_path" && ! -e "$new_module_path" ]]; then
    mkdir -p "$(dirname "$new_module_path")"
    mv "$old_module_path" "$new_module_path"
    printf 'gitdir: ../.git/modules/%s\n' "$subdir" > "$gitfile"
    if is_subcontainer_git_repo_ready "$subdir"; then
      echo "Recovered subcontainer gitdir for '$subdir' from legacy module '$module_name'." >&2
      return
    fi
  fi

  echo "Subcontainer '$subdir' has stale git metadata ('$module_name'). Reinitializing local git metadata." >&2
  rm -f "$gitfile"
}

ensure_single_subcontainer_ready() {
  local subdir=$1 repo_name=$2 visibility=$3 remote_url

  if [[ ! -d "$subdir" ]]; then
    echo "Skipping '$subdir' because it no longer exists locally." >&2
    return
  fi

  handle_subcontainer_remote_rename "$subdir" "$repo_name"
  repair_submodule_gitdir_if_needed "$subdir"
  ensure_remote_repo_exists "$repo_name" "$visibility"
  ensure_subcontainer_parent_topic "$repo_name"
  remote_url=$(resolve_remote_url "$repo_name")

  ensure_submodule_repo_initialized "$subdir"
  ensure_submodule_branch "$subdir"
  ensure_submodule_remote "$subdir" "$remote_url"
  commit_and_push_submodule "$subdir"
  record_subcontainer_commit "$subdir"
  register_submodule_reference "$subdir" "$remote_url"
}

ensure_submodule_repo_initialized() {
  local subdir=$1
  repair_submodule_gitdir_if_needed "$subdir"
  if is_subcontainer_git_repo_ready "$subdir"; then
    return
  fi
  rm -rf "$subdir/.git"
  git -C "$subdir" init >/dev/null
  if ! is_subcontainer_git_repo_ready "$subdir"; then
    echo "Failed to initialize isolated git repo for '$subdir'." >&2
    return 1
  fi

}

ensure_submodule_branch() {
  local subdir=$1 current
  current=$(git -C "$subdir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -z "$current" || "$current" == "HEAD" ]]; then
    git -C "$subdir" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || git -C "$subdir" branch -M main
    current="main"
  elif [[ "$current" != "main" ]]; then
    git -C "$subdir" branch -M "$current" main >/dev/null 2>&1 || git -C "$subdir" switch -C main >/dev/null 2>&1
    current="main"
  fi
}

ensure_submodule_remote() {
  local subdir=$1 remote_url=$2 current_remote
  if current_remote=$(git -C "$subdir" remote get-url origin 2>/dev/null); then
    if [[ "$current_remote" != "$remote_url" ]]; then
      git -C "$subdir" remote set-url origin "$remote_url"
    fi
  else
    git -C "$subdir" remote add origin "$remote_url"
  fi
}

stage_submodule_changes() {
  local subdir=$1
  (
    cd "$subdir" || return
    ensure_token_gitignore
    cleanup_local_backup_artifacts
    
    # --- NEW: Auto-ignore problematic files for submodules ---
    # We call the function from the parent script context, but we are inside the subdir subshell
    # so we pass "." as the path.
    auto_ignore_problematic_files "."
    # ---------------------------------------------------------

    remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
    git add --all
    remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
    purge_sensitive_paths_from_index "."
    if [[ "$(basename "$subdir")" != "send_folder_to_github" ]]; then
      protect_path "create_and_push_repo.sh"
      remove_tracked_path "create_and_push_repo.sh"
    fi
    protect_path "GITHUB_TOKEN"
    protect_path "GITHUB_TOKEN.txt"
    protect_path "AMO_API_KEY.txt"
    protect_path "AMO_API_SECRET.txt"
  )
}

commit_and_push_submodule() {
  local subdir=$1
  stage_submodule_changes "$subdir"
  ensure_lfs_for_large_files "$subdir"
  if git -C "$subdir" diff --staged --quiet; then
    : 
  else
    commit_submodule_safely "$subdir"
  fi
  ensure_submodule_initial_commit "$subdir"

  # Sync before push to avoid non-fast-forward errors
  if git -C "$subdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      # Only pull if remote is configured
      run_git_pull_command_submodule "$subdir" "main" >/dev/null 2>&1 || true
  fi

  push_submodule_with_credentials "$subdir"
}

commit_submodule_safely() {
  local subdir=$1 has_upstream=1
  if ! git -C "$subdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    has_upstream=0
  fi

  if git -C "$subdir" rev-parse --verify HEAD >/dev/null 2>&1 && [[ $has_upstream -eq 0 ]]; then
    git -C "$subdir" commit --amend --no-edit
  else
    git -C "$subdir" commit -m "push"
  fi
}

ensure_submodule_initial_commit() {
  local subdir=$1
  if git -C "$subdir" rev-parse --verify HEAD >/dev/null 2>&1; then
    return
  fi
  git -C "$subdir" commit --allow-empty -m "Initial subcontainer commit" >/dev/null
}

run_git_pull_command_submodule() {
  local subdir=$1 branch=$2 output status
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials git -C "$subdir" pull --rebase origin "$branch" 2>&1)
  else
    output=$(git -C "$subdir" pull --rebase origin "$branch" 2>&1)
  fi
  status=$?
  printf "%s\n" "$output"
  return $status
}

record_subcontainer_commit() {
  local subdir=$1 commit
  commit=$(git -C "$subdir" rev-parse HEAD 2>/dev/null || true)
  if [[ -n "$commit" ]]; then
    __SUBCONTAINER_COMMITS["$subdir"]="$commit"
  else
    unset "__SUBCONTAINER_COMMITS[$subdir]"
  fi
}

push_submodule_with_credentials() {
  local subdir=$1 branch=${2:-main} force_flag=${3:-} output status
  
  # Define push command execution
  local -a push_cmd=(git -C "$subdir" push -u origin "$branch")
  if [[ -n "$force_flag" ]]; then
    push_cmd+=("$force_flag")
  fi

  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials "${push_cmd[@]}" 2>&1)
  else
    output=$("${push_cmd[@]}" 2>&1)
  fi
  status=$?
  
  printf "%s\n" "$output"
  
  # Handle non-fast-forward (fetch first)
  if [[ $status -ne 0 ]] && [[ "$output" == *"fetch first"* || "$output" == *"non-fast-forward"* ]]; then
     # If we are forcing, we expect non-fast-forward, so we shouldn't fail/pull here if it was intentional
     if [[ -n "$force_flag" ]]; then
         echo "Force push failed even with --force." >&2
         return $status
     fi
     
     echo "Submodule push rejected (non-fast-forward)." >&2
     if [[ "${ALLOW_PULL:-0}" == "1" ]]; then
       echo "ALLOW_PULL=1: attempting pull --rebase for '$subdir' then retrying push..." >&2
       if run_git_pull_command_submodule "$subdir" "$branch"; then
          echo "Pull successful. Retrying push..." >&2
          if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
              output=$(run_with_https_credentials "${push_cmd[@]}" 2>&1)
          else
              output=$("${push_cmd[@]}" 2>&1)
          fi
          status=$?
          printf "%s\n" "$output"
       fi
     else
       echo "Skipping automatic pull for submodule (ALLOW_PULL=0). Please pull/rebase manually or rerun with ALLOW_PULL=1." >&2
     fi
  fi

  if [[ $status -ne 0 ]]; then
    handle_push_secrets_rejection "$subdir" "$output"
    local secret_status=$?
    
    if [[ $secret_status -eq 0 ]]; then
      echo "Retrying submodule push after removing secrets..." >&2
      push_submodule_with_credentials "$subdir" "$branch"
      return $?
    elif [[ $secret_status -eq 2 ]]; then
      echo "Deep history cleaned. Retrying submodule push with --force..." >&2
      push_submodule_with_credentials "$subdir" "$branch" "--force"
      return $?
    fi

    if handle_large_file_push_rejection "$subdir" "$output"; then
      echo "Retrying submodule push for '$subdir' after enabling Git LFS..." >&2
      push_submodule_with_credentials "$subdir" "$branch"
      return $?
    fi
  fi
  return $status
}

handle_large_file_push_rejection() {
  local repo_path=$1 push_output=$2
  local -a files=()
  mapfile -t files < <(extract_large_file_paths "$push_output")
  if [[ ${#files[@]} -eq 0 ]]; then
    return 1
  fi
  echo "Push rejected: files exceed GitHub's 100 MB limit. Configuring Git LFS for: ${files[*]}" >&2
  apply_lfs_tracking_for_paths "$repo_path" "${files[@]}"
  if amend_last_commit_with_lfs "$repo_path"; then
    return 0
  fi
  return 1
}

apply_lfs_tracking_for_paths() {
  local repo_path=$1
  shift
  if [[ $# -eq 0 ]]; then
    return
  fi
  git -C "$repo_path" lfs install >/dev/null 2>&1 || true
  local file
  declare -A seen=()
  local -a unique=()
  for file in "$@"; do
    [[ -z "$file" ]] && continue
    if [[ -n "${seen[$file]+_}" ]]; then
      continue
    fi
    seen["$file"]=1
    unique+=("$file")
  done
  for file in "${unique[@]}"; do
    git -C "$repo_path" lfs track -- "$file" >/dev/null 2>&1 || true
  done
  git -C "$repo_path" add .gitattributes >/dev/null 2>&1 || true
  git -C "$repo_path" add -- "${unique[@]}" >/dev/null 2>&1 || true
}

amend_last_commit_with_lfs() {
  local repo_path=$1
  if ! git -C "$repo_path" rev-parse HEAD >/dev/null 2>&1; then
    return 1
  fi
  if git -C "$repo_path" diff --cached --quiet; then
    return 1
  fi
  git -C "$repo_path" commit --amend --no-edit >/dev/null 2>&1 || return 1
  return 0
}

extract_large_file_paths() {
  python3 - "$1" <<'PY'
import sys
import re
text = sys.argv[1]
patterns = [
    re.compile(r'File (.+?) is .*?exceeds GitHub', re.IGNORECASE),
    re.compile(r'File (.+?) exceeds GitHub', re.IGNORECASE),
]
found = []
for line in text.splitlines():
    for pat in patterns:
        m = pat.search(line)
        if m:
            path = m.group(1).strip()
            if path and path not in found:
                found.append(path)
            break
print("\n".join(found))
PY
}

handle_push_secrets_rejection() {
  local repo_path=$1 push_output=$2
  if [[ "$push_output" != *"GH013"* ]] && [[ "$push_output" != *"Push cannot contain secrets"* ]]; then
    return 1
  fi
  
  echo "Security violation detected! Attempting automatic fix..." >&2
  
  # Extract file paths using Python
  local files
  files=$(python3 - "$push_output" <<'PY'
import sys, re
text = sys.argv[1]
found = []
# Look for "path: filename:line"
patterns = [r'path:\s*([^:\n]+)(:\d+)?']
for line in text.splitlines():
    for pat in patterns:
        m = re.search(pat, line)
        if m:
            path = m.group(1).strip()
            if path and path not in found:
                found.append(path)
print("\n".join(found))
PY
)

  if [[ -z "$files" ]]; then
    echo "Could not parse secret file paths from error message." >&2
    return 1
  fi

  local secrets_found_in_head=0
  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    
    # Check if file exists in HEAD
    if git -C "$repo_path" ls-tree -r HEAD --name-only | grep -Fqx "$file"; then
       echo "Removing secret file from commit (HEAD): $file" >&2
       secrets_found_in_head=1
       
       # Remove from index
       git -C "$repo_path" rm --cached --ignore-unmatch "$file" >/dev/null 2>&1
       
       # Add to .gitignore if not present
       if [[ -f "$repo_path/.gitignore" ]]; then
          if ! grep -Fq "$file" "$repo_path/.gitignore"; then
             echo "$file" >> "$repo_path/.gitignore"
             git -C "$repo_path" add .gitignore
          fi
       else
          echo "$file" > "$repo_path/.gitignore"
          git -C "$repo_path" add .gitignore
       fi
    fi
  done <<< "$files"
  
  if [[ $secrets_found_in_head -eq 1 ]]; then
      # Amend the last commit (Standard Fix)
      if git -C "$repo_path" commit --amend --no-edit >/dev/null 2>&1; then
         echo "Commit amended (secrets removed from HEAD). Retrying push..." >&2
         return 0
      else
         echo "Failed to amend commit." >&2
         return 1
      fi
  else
      # Advanced Fix: Deep History Cleanup
      echo "Secrets detected in deep history (not in HEAD). Initiating advanced cleanup..." >&2
      local git_rm_args=""
      local file_count=0
      
      while IFS= read -r file; do
          [[ -z "$file" ]] && continue
          git_rm_args="$git_rm_args '$file'"
          
          # Add to .gitignore if not present
          if ! grep -Fq "$file" "$repo_path/.gitignore" 2>/dev/null; then
               [[ -s "$repo_path/.gitignore" && "$(tail -c 1 "$repo_path/.gitignore" | wc -l)" -eq 0 ]] && echo "" >> "$repo_path/.gitignore"
               echo "$file" >> "$repo_path/.gitignore"
          fi
          ((file_count++))
      done <<< "$files"

      if [[ $file_count -eq 0 ]]; then
         echo "No files identified for deep cleanup." >&2
         return 1
      fi

      echo "Rewriting history to remove: $git_rm_args" >&2
      echo "Warning: This operation rewrites commit history (git filter-branch)." >&2

      if git -C "$repo_path" filter-branch --force --index-filter \
         "git rm --cached --ignore-unmatch $git_rm_args" \
         --prune-empty --tag-name-filter cat -- --all >/dev/null 2>&1; then

         # Cleanup backup refs
         rm -rf "$repo_path/.git/refs/original/"
         git -C "$repo_path" reflog expire --expire=now --all
         git -C "$repo_path" gc --prune=now >/dev/null 2>&1

         # Ensure .gitignore changes are committed
         if [[ -n $(git -C "$repo_path" status --porcelain .gitignore) ]]; then
             git -C "$repo_path" add .gitignore
             git -C "$repo_path" commit -m "chore: ignore sensitive keys (post-cleanup)" >/dev/null 2>&1 || true
         fi

         echo "History rewritten. Force push required." >&2
         return 2 # Signal FORCE PUSH
      else
         echo "Failed to rewrite history with filter-branch." >&2
         return 1
      fi
  fi
}

register_submodule_reference() {
  local subdir=$1 remote_url=$2
  git config -f .gitmodules "submodule.$subdir.path" "$subdir"
  git config -f .gitmodules "submodule.$subdir.url" "$remote_url"
  git config "submodule.$subdir.path" "$subdir"
  git config "submodule.$subdir.url" "$remote_url"
  git config "submodule.$subdir.update" "checkout"
  git submodule absorbgitdirs "$subdir" >/dev/null 2>&1 || true
}

remove_submodule_config() {
  local subdir=$1
  git config -f .gitmodules --remove-section "submodule.$subdir" >/dev/null 2>&1 || true
  git config --remove-section "submodule.$subdir" >/dev/null 2>&1 || true
  git rm --cached --ignore-unmatch "$subdir" >/dev/null 2>&1 || true
  if [[ -d ".git/modules/$subdir" ]]; then
    rm -rf ".git/modules/$subdir"
  fi
}

clear_removed_subcontainers() {
  if [[ ${#__SUBCONTAINERS_TO_CLEAR[@]} -eq 0 ]]; then
    return
  fi
  local entry subdir repo
  for entry in "${__SUBCONTAINERS_TO_CLEAR[@]}"; do
    IFS="|" read -r subdir repo <<<"$entry"
    clear_subcontainer_repo "$repo" "$subdir"
  done
}

format_subcontainer_repo_name() {
  local _root_repo=$1 subdir=$2 segment
  segment=$(sanitize_repo_segment "$subdir")
  printf "%s" "$segment"
}

sanitize_repo_segment() {
  local value=$1
  value=${value//\//-}
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  value=${value//[^a-z0-9_-]/-}
  while [[ "$value" == *--* ]]; do
    value=${value//--/-}
  done
  while [[ "$value" == *__* ]]; do
    value=${value//__/_}
  done
  value=${value##-}
  value=${value%%-}
  value=${value##_}
  value=${value%%_}
  if [[ -z "$value" ]]; then
    value="subfolder"
  fi
  printf "%s" "$value"
}

push_commit_to_remote() {
  local remote_url=$1 refspec=$2 force_flag=${3:-} output status
  local -a args=("git" "push")
  if [[ -n "$force_flag" ]]; then
    args+=("$force_flag")
  fi
  args+=("$remote_url" "$refspec")
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    if output=$(run_with_https_credentials "${args[@]}" 2>&1); then
      status=0
    else
      status=$?
    fi
  else
    if output=$("${args[@]}" 2>&1); then
      status=0
    else
      status=$?
    fi
  fi
  printf "%s\n" "$output"
  return $status
}

fetch_remote_head_into_ref() {
  local remote_url=$1 target_ref=$2 output status
  output=$(run_git_with_credentials git fetch --no-tags "$remote_url" "refs/heads/main:$target_ref" 2>&1)
  status=$?
  if [[ $status -ne 0 ]]; then
    printf "%s\n" "$output"
    return $status
  fi
  return 0
}

clear_subcontainer_repo() {
  local repo_name=$1 subdir=$2 remote_url tmp_ref parent empty_tree empty_commit fetch_output
  remote_url=$(resolve_remote_url "$repo_name")
  echo "Clearing subcontainer for removed folder '$subdir' (repo '$repo_name')." >&2
  tmp_ref="refs/tmp/subcontainer-${RANDOM}-${RANDOM}"
  parent=""
  if fetch_output=$(fetch_remote_head_into_ref "$remote_url" "$tmp_ref"); then
    parent=$(git rev-parse "$tmp_ref" 2>/dev/null || true)
  else
    if [[ "$fetch_output" == *"couldn't find remote ref"* || "$fetch_output" == *"could not find remote ref"* ]]; then
      parent=""
    else
      printf "%s\n" "$fetch_output" >&2
    fi
  fi
  git update-ref -d "$tmp_ref" >/dev/null 2>&1 || true

  empty_tree=$(git hash-object -t tree /dev/null)
  if [[ -n "$parent" ]]; then
    empty_commit=$(git commit-tree "$empty_tree" -p "$parent" -m "Remove folder '$subdir' after deletion")
  else
    empty_commit=$(git commit-tree "$empty_tree" -m "Remove folder '$subdir' after deletion")
  fi

  if push_commit_to_remote "$remote_url" "$empty_commit:refs/heads/main"; then
    echo "Subcontainer '$repo_name' cleared successfully." >&2
  else
    echo "Failed to clear subcontainer '$repo_name'." >&2
  fi
}

remove_paths_from_index() {
  local path
  for path in "$@"; do
    [[ -z "$path" ]] && continue
    git rm -rf --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  done
}

purge_sensitive_paths_from_index() {
  local repo_path=${1:-.}
  (
    cd "$repo_path" || return 0
    local pattern
    for pattern in "${SENSITIVE_PATHS[@]}"; do
      [[ -z "$pattern" ]] && continue
      # Use find to locate files matching the pattern recursively and remove them from index
      find . -name "$pattern" -exec git rm --cached --ignore-unmatch -- {} + >/dev/null 2>&1 || true
    done
  )
}

stage_files_excluding_script() {
  local script_rel=$1
  ensure_token_gitignore
  cleanup_local_backup_artifacts
  
  # Only populate submodules if NOT in subcontainer mode (managed manually there)
  if [[ "${SUBCONTAINER_MODE:-false}" != "true" ]]; then
      ensure_submodules_populated
  fi
  
  # --- NEW: Auto-ignore problematic files before adding ---
  auto_ignore_problematic_files "."
  # --------------------------------------------------------

  remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
  git add --all
  remove_paths_from_index "${DEFAULT_INDEX_EXCLUDES[@]}"
  purge_sensitive_paths_from_index "."
  if [[ "${ROOT_REPO_NAME:-}" != "send_folder_to_github" && -n "$script_rel" ]]; then
    protect_path "$script_rel"
    remove_tracked_path "$script_rel"
  fi
  if [[ "$SUBCONTAINER_MODE" == "true" ]]; then
    enforce_subcontainer_gitlinks
  fi
  ensure_lfs_for_large_files "."
  protect_path "GITHUB_TOKEN"
  protect_path "GITHUB_TOKEN.txt"
  protect_path "AMO_API_KEY.txt"
  protect_path "AMO_API_SECRET.txt"
}

# --- NEW FUNCTION: Auto-detect and ignore sensitive/problematic files ---
auto_ignore_problematic_files() {
  local repo_path=$1
  (
    cd "$repo_path" || return
    
    # 1. Handle GitHub Workflows (fixes 'refusing to allow... workflow scope' error)
    if [[ -d ".github/workflows" ]]; then
       if ! grep -q "^\.github/workflows/" .gitignore 2>/dev/null; then
           [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
           echo ".github/workflows/" >> .gitignore
           echo "   [Auto-Fix] Ignored .github/workflows/ to prevent permission errors." >&2
       fi
       # Remove from index if present
       git rm -r --cached --ignore-unmatch .github/workflows/ >/dev/null 2>&1 || true
    fi

    # 2. Handle Sensitive Files (fixes 'Repository rule violations... secrets' error)
    local -a sensitive_patterns=(
        "GITHUB_TOKEN"
        "GITHUB_TOKEN.txt"
        "AMO_API_KEY"
        "AMO_API_KEY.txt"
        "AMO_API_SECRET"
        "AMO_API_SECRET.txt"
        "*key.json"
        "*credential*.json"
        "client_secret*.json"
        "*.pem"
        "*.p12"
        "id_rsa"
        "id_dsa"
        "*.keystore"
        "*.jks"
    )

    local pattern found_files
    for pattern in "${sensitive_patterns[@]}"; do
        # Find files matching pattern (exclude .git)
        found_files=$(find . -maxdepth 4 -name "$pattern" -not -path "./.git/*" 2>/dev/null)
        
        if [[ -n "$found_files" ]]; then
            # Check if pattern is already in gitignore
            if ! grep -Fq "$pattern" .gitignore 2>/dev/null; then
                [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
                echo "$pattern" >> .gitignore
                echo "   [Auto-Fix] Ignored sensitive pattern '$pattern' found in repo." >&2
            fi
            
            # Remove specific files from index
            for file in $found_files; do
                git rm --cached --ignore-unmatch "$file" >/dev/null 2>&1 || true
            done
        fi
    done
    
    # 3. Handle System Junk & Default Excludes
    local -a all_excludes=("${DEFAULT_INDEX_EXCLUDES[@]}")
    # Add common junk that might not be in the global list
    all_excludes+=("__pycache__" ".DS_Store" "Thumbs.db")

    for item in "${all_excludes[@]}"; do
         # Remove trailing slashes for directory check
         local clean_item=${item%/}
         
         if [[ -e "$clean_item" ]]; then
             if ! grep -Fxq "$clean_item" .gitignore 2>/dev/null && ! grep -Fxq "$clean_item/" .gitignore 2>/dev/null; then
                 [[ -s .gitignore && "$(tail -c 1 .gitignore | wc -l)" -eq 0 ]] && echo "" >> .gitignore
                 # If it's a directory, add trailing slash to gitignore
                 if [[ -d "$clean_item" ]]; then
                    echo "$clean_item/" >> .gitignore
                 else
                    echo "$clean_item" >> .gitignore
                 fi
                 echo "   [Auto-Fix] Ignored excluded item '$clean_item'." >&2
             fi
             git rm -r --cached --ignore-unmatch "$clean_item" >/dev/null 2>&1 || true
         fi
    done
  )
}
# ------------------------------------------------------------------------

ensure_submodules_populated() {
  if [[ ! -f .gitmodules ]]; then
    return
  fi
  
  # Sanitize common ignored directories that might accidentally contain .git
  local -a cleanup_targets=("node_modules" "__pycache__" "venv" "env" ".mypy_cache" ".pytest_cache" "cache")
  local target
  for target in "${cleanup_targets[@]}"; do
      if [[ -e "$target/.git" ]]; then
          echo "Removing invalid git metadata from ignored directory '$target'..." >&2
          rm -rf "$target/.git"
      fi
  done

  if ! git config -f .gitmodules --get-regexp '^submodule\.' >/dev/null 2>&1; then
    return
  fi
  if run_git_with_credentials git submodule update --init --recursive >/dev/null 2>&1; then
    return
  fi
  echo "Warning: failed to populate existing submodules automatically. Run 'git submodule update --init --recursive' and retry if issues persist." >&2
}

enforce_subcontainer_gitlinks() {
  local entry subdir repo visibility commit
  if [[ ${#__SUBCONTAINERS_TO_PUSH[@]} -eq 0 ]]; then
    return
  fi
  for entry in "${__SUBCONTAINERS_TO_PUSH[@]}"; do
    IFS="|" read -r subdir repo visibility <<<"$entry"
    [[ -d "$subdir" ]] || continue
    commit=${__SUBCONTAINER_COMMITS[$subdir]:-}
    if [[ -z "$commit" ]]; then
      commit=$(git -C "$subdir" rev-parse HEAD 2>/dev/null || true)
    fi
    if [[ -z "$commit" ]]; then
      echo "Warning: subcontainer '$subdir' has no commits to reference; keeping it as a normal folder in this push." >&2
      continue
    fi
    stage_subcontainer_gitlink "$subdir" "$commit"
  done
}

stage_subcontainer_gitlink() {
  local subdir=$1 commit=$2
  git rm -r --cached --ignore-unmatch -- "$subdir" >/dev/null 2>&1 || true
  git update-index --add --cacheinfo 160000 "$commit" "$subdir" >/dev/null
}

ensure_lfs_for_large_files() {
  local repo_path=$1
  local threshold=${GIT_LFS_THRESHOLD_BYTES:-104857600}
  local -a to_track=()
  local path full size attr
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    full="$repo_path/$path"
    [[ ! -f "$full" ]] && continue
    size=$(stat -c%s -- "$full" 2>/dev/null || echo 0)
    if (( size < threshold )); then
      continue
    fi
    attr=$(git -C "$repo_path" check-attr filter -- "$path" 2>/dev/null || true)
    if [[ "$attr" == *"filter: lfs"* ]]; then
      continue
    fi
    to_track+=("$path")
  done < <(git -C "$repo_path" diff --cached --name-only --diff-filter=AM 2>/dev/null || true)

  if [[ ${#to_track[@]} -eq 0 ]]; then
    return
  fi

  git -C "$repo_path" lfs install >/dev/null 2>&1 || true
  local target
  for target in "${to_track[@]}"; do
    git -C "$repo_path" lfs track -- "$target" >/dev/null 2>&1 || true
  done
  git -C "$repo_path" add .gitattributes >/dev/null 2>&1 || true
  git -C "$repo_path" add -- "${to_track[@]}" >/dev/null 2>&1 || true
  echo "Large files routed through Git LFS in '$repo_path': ${to_track[*]}" >&2
}

cleanup_local_backup_artifacts() {
  local -a backups=()
  while IFS= read -r -d '' path; do
    path=${path#./}
    backups+=("$path")
  done < <(find . -path ./.git -prune -o -name "*.local-backup-*" -print0 2>/dev/null || true)

  if [[ ${#backups[@]} -eq 0 ]]; then
    return
  fi

  local path
  for path in "${backups[@]}"; do
    git rm -rf --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
    rm -rf -- "$path"
  done
  echo "Temporary backups removed: ${backups[*]}" >&2
}

ensure_token_gitignore() {
  local gitignore=.gitignore
  local entries=(
    ".env"
    "*.env.local"
    "*.env.development"
    "*.env.production"
    "__pycache__/"
    "pycache"
    ".gemini"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET.txt"
    "gemini-gcloud-key.json"
    "gcp-oauth.keys.json"
    "*API*"
    ".eslintcache/"
    "node_modules/"
    "dist/"
    "build/"
    "*.zip"
  )
  if [[ ! -f $gitignore ]]; then
    printf "%s\n" "${entries[@]}" > "$gitignore"
    return
  fi

  # Ensure the file ends with a newline before appending
  if [[ -s "$gitignore" && "$(tail -c 1 "$gitignore" | wc -l)" -eq 0 ]]; then
      echo "" >> "$gitignore"
  fi

  local entry
  for entry in "${entries[@]}"; do
    if ! grep -Fxq "$entry" "$gitignore"; then
      printf "%s\n" "$entry" >> "$gitignore"
    fi
  
  done
}

protect_path() {
  local path=$1
  [[ -z "$path" ]] && return
  git restore --staged -- "$path" >/dev/null 2>&1 || git reset HEAD -- "$path" >/dev/null 2>&1 || true
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    return
  fi
  git rm --cached -- "$path" >/dev/null 2>&1 || true
}

remove_tracked_path() {
  local path=$1
  [[ -z "$path" ]] && return
  git rm --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
}

commit_changes() {
  if git diff --staged --quiet; then
    return 1
  fi
  git commit -m "push"
  return 0
}

# Credentials helpers --------------------------------------------------------
run_with_https_credentials() {
  local askpass status
  askpass=$(mktemp)
  cat >"$askpass" <<'ASKPASS'
#!/usr/bin/env bash
if [[ "$1" == *Username* ]]; then
  printf '%s\n' "luascfl"
else
  printf '%s\n' "${GITHUB_TOKEN}"
fi
ASKPASS
  chmod +x "$askpass"
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" "$@"
  status=$?
  rm -f "$askpass"
  return $status
}

run_git_with_credentials() {
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    run_with_https_credentials "$@"
  else
    "$@"
  fi
}

list_codex_dirs() {
  find "$ROOT_REPO_DIR" -maxdepth 2 -type d -name "codex_*" -print0
}

should_run_global_codex_sync() {
  local base
  base=$(basename "$ROOT_REPO_DIR")
  if [[ "$base" == codex_* ]]; then
    return 1
  fi
  if [[ -n $(find "$ROOT_REPO_DIR" -maxdepth 1 -type d -name "codex_*" -print -quit) ]]; then
    return 0
  fi
  return 1
}

log_codex_sync() {
  local status=$1 dir=$2 log_file="$ROOT_REPO_DIR/codex_sync.log"
  local msg
  if [[ "$status" -eq 0 ]]; then
    msg="SUCCESS"
  else
    msg="FAIL"
  fi
  printf '%s %s %s\n' "$(date -Iseconds)" "$msg" "$dir" >>"$log_file"
}

run_codex_sync() {
  local dir
  local -a failed=()
  local ok=0
  while IFS= read -r -d '' dir; do
    echo "=== Syncing $dir ==="
    if (
      cd "$dir" || exit 1
      ./create_and_push_repo.sh push
    ); then
      ((ok++))
      log_codex_sync 0 "$dir"
    else
      failed+=("$dir")
      log_codex_sync 1 "$dir"
    fi
  done < <(list_codex_dirs)
  echo "Codex sync summary: success=$ok failed=${#failed[@]}"
  if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'Failed directories:\n'
    for dir in "${failed[@]}"; do
      printf '  - %s\n' "$dir"
    done
    return 1
  fi
  return 0
}

push_with_credentials() {
  local branch=$1 force_flag=${2:-} output status
  
  local -a push_cmd=(git push -u origin "$branch")
  if [[ -n "$force_flag" ]]; then
    push_cmd+=("$force_flag")
  fi

  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    if output=$(run_with_https_credentials "${push_cmd[@]}" 2>&1); then
      status=0
    else
      status=$?
    fi
  else
    if output=$("${push_cmd[@]}" 2>&1); then
      status=0
    else
      status=$?
    fi
  fi
  printf "%s\n" "$output"
  if [[ $status -ne 0 && "$output" =~ non-fast-forward ]]; then
    if [[ -n "$force_flag" ]]; then
        echo "Force push failed even with --force." >&2
        return $status
    fi
    echo "Push rejected (non-fast-forward)." >&2
    if [[ "${ALLOW_PULL:-0}" == "1" ]]; then
      echo "ALLOW_PULL=1: attempting pull --rebase then retrying push..." >&2
      if pull_with_credentials "$branch" && push_with_credentials "$branch"; then
        return 0
      fi
    else
      echo "Skipping automatic pull (ALLOW_PULL=0). Please pull/rebase manually or rerun with ALLOW_PULL=1." >&2
      return $status
    fi
  fi
  if [[ $status -ne 0 ]]; then
    handle_push_secrets_rejection "." "$output"
    local secret_status=$?
    
    if [[ $secret_status -eq 0 ]]; then
      echo "Retrying push after removing secrets..." >&2
      push_with_credentials "$branch"
      return $?
    elif [[ $secret_status -eq 2 ]]; then
      echo "Deep history cleaned. Retrying push with --force..." >&2
      push_with_credentials "$branch" "--force"
      return $?
    fi

    if handle_large_file_push_rejection "." "$output"; then
      echo "Retrying push after enabling Git LFS for large files..." >&2
      push_with_credentials "$branch"
      return $?
    fi
  fi
  return $status
}

# Pull / rebase --------------------------------------------------------------
pull_with_credentials() {
  local branch=$1 output
  if output=$(run_git_pull_command "$branch"); then
    printf "%s\n" "$output"
    return 0
  fi

  printf "%s\n" "$output" >&2
  echo "Warning: 'pull --rebase' failed. Working tree left untouched; resolve conflicts/stash/clean manually." >&2
  return 1
}

run_git_pull_command() {
  local branch=$1 output status
  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    output=$(run_with_https_credentials git pull --rebase origin "$branch" 2>&1)
  else
    output=$(git pull --rebase origin "$branch" 2>&1)
  fi
  status=$?
  printf "%s" "$output"
  return $status
}

is_untracked_overwrite_error() {
  grep -q "untracked working tree files would be overwritten" <<<"$1"
}

resolve_untracked_overwrite_conflicts() {
  local branch=$1 message=$2 path backup timestamp
  timestamp=$(date +%s)

  while read -r path; do
    [[ -z "$path" ]] && continue
    [[ ! -e "$path" ]] && continue

    backup="${path}.local-backup-${timestamp}"
    while [[ -e "$backup" ]]; do
      backup="${backup}-${RANDOM}"
    done

    cp -a -- "$path" "$backup"
    rm -rf -- "$path"
    __register_backup "$path" "$backup"
    echo "Local file '$path' was temporarily saved in '$backup' to allow pull to continue." >&2
  done < <(extract_untracked_conflict_paths "$message")

  local retry
  if retry=$(run_git_pull_command "$branch"); then
    printf "%s\n" "$retry"
    return 0
  fi

  printf "%s\n" "$retry" >&2
  return 1
}

extract_untracked_conflict_paths() {
  awk '
    /untracked working tree files would be overwritten by checkout:/ {collect=1; next}
    /Please move or remove them before you switch branches/ {collect=0}
    collect && NF { gsub(/^[[:space:]]+/, "", $0); print }
  ' <<<"$1"
}

__register_backup() {
  __UNTRACKED_BACKUPS+=("$1|$2")
}

__restore_all_backups() {
  local entry original backup
  if [[ ${#__UNTRACKED_BACKUPS[@]} -eq 0 ]]; then
    return
  fi

  for entry in "${__UNTRACKED_BACKUPS[@]}"; do
    original=${entry%%|*}
    backup=${entry#*|}
    [[ -z "$original" || -z "$backup" ]] && continue
    if [[ -e "$backup" ]]; then
      rm -rf -- "$original"
      mv -- "$backup" "$original"
      echo "Restored local version: $original" >&2
    fi
  done
  __UNTRACKED_BACKUPS=()
}

rebase_in_progress() {
  [[ -d .git/rebase-apply || -d .git/rebase-merge ]]
}

auto_resolve_rebase_conflicts() {
  local branch=$1
  local -a conflicts
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)

  if [[ ${#conflicts[@]} -eq 0 ]]; then
    abort_rebase_with_warning "Rebase in progress, but no conflicted files were detected automatically."
    return 1
  fi

  local file
  for file in "${conflicts[@]}"; do
    if ! resolve_conflict_for_file "$file"; then
      abort_rebase_with_warning "Conflict in '$file' requires manual resolution."
      return 1
    fi
  done

  if git rebase --continue >/tmp/rebase-continue.log 2>&1; then
    cat /tmp/rebase-continue.log
    rm -f /tmp/rebase-continue.log
    return 0
  fi

  abort_rebase_with_warning "Unable to complete the rebase automatically."
  return 1
}

resolve_conflict_for_file() {
  local file=$1
  case "$file" in
    .gitignore)
      git checkout --theirs -- .gitignore >/dev/null 2>&1 || return 1
      ensure_token_gitignore
      git add .gitignore
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

abort_rebase_with_warning() {
  local message=$1
  local status_output
  status_output=$(git status --short 2>/dev/null || true)
  git rebase --abort >/dev/null 2>&1 || true
  echo "$message" >&2
  if [[ -n "$status_output" ]]; then
    echo "Files in conflict:" >&2
    echo "$status_output" >&2
  fi
}

main "$@"
