#!/usr/bin/env bash
# =============================================================================
# VPS Setup — interactive server setup for beginners
# Usage:  sudo ./setup.sh [options]      (see --help)
# =============================================================================
set -uo pipefail

VERSION="0.3.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

DRY_RUN=0
ASSUME_YES=0
LANG_CODE=""
PRESET=""
declare -a SELECTED=()
declare -A PRESET_SET=()

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/os.sh
source "$ROOT_DIR/lib/os.sh"
# shellcheck source=lib/ui.sh
source "$ROOT_DIR/lib/ui.sh"
# shellcheck source=lib/i18n/en.sh
source "$ROOT_DIR/lib/i18n/en.sh"

usage() {
  cat <<EOF
VPS Setup $VERSION — set up a fresh Linux server step by step.

Usage: sudo ./setup.sh [options]

Options:
  --preset NAME     recommended | minimal | custom | domain | database (skips the first menu)
  --lang en|id      Interface language (default: en; asks if not given)
  --dry-run         Show what would happen without changing anything
  -y, --yes         Non-interactive: accept defaults (requires --preset)
  --ssh-key "KEY"   Public SSH key for the admin user (useful with --yes)
  --webserver NAME  With --yes: nginx | caddy | apache (default: nginx)
  --add-domain      Jump straight to the "add a website / domain" wizard
  --email ADDRESS   Email for Let's Encrypt (useful with --yes)
  --domain NAME     With --yes: domain to add          (needs --preset domain)
  --site-type TYPE  With --yes: static|spa|proxy|laravel|php|wordpress|redirect
  --port N          With --yes: app port for --site-type proxy (default 3000)
  --redirect-to URL With --yes: target for --site-type redirect
  --add-database    Jump straight to the "create a database / user" wizard
  --engine NAME     With --yes --preset database: postgresql | mysql (default: postgresql)
  --db NAME         With --yes --preset database: database name to create
  --db-user NAME    With --yes --preset database: database user (defaults to --db value)
  -v, --version     Print version
  -h, --help        Show this help

Examples:
  sudo ./setup.sh                          # guided, interactive
  sudo ./setup.sh --lang id                # Bahasa Indonesia
  sudo ./setup.sh --dry-run                # preview only
  sudo ./setup.sh --yes --preset recommended --ssh-key "ssh-ed25519 AAAA..."
  sudo ./setup.sh --add-domain             # add another website later
  sudo ./setup.sh --yes --preset domain --domain app.example.com --site-type proxy --port 3000
  sudo ./setup.sh --add-database           # create a database later
  sudo ./setup.sh --yes --preset database --engine postgresql --db myapp
EOF
}

# ------------------------------------------------------------------ arguments
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "vps-setup $VERSION"; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --preset)  [[ $# -ge 2 ]] || die "--preset needs a value"; PRESET=$2; shift ;;
    --lang)    [[ $# -ge 2 ]] || die "--lang needs a value"; LANG_CODE=$2; shift ;;
    --ssh-key) [[ $# -ge 2 ]] || die "--ssh-key needs a value"; CFG[ssh_pubkey]=$2; shift ;;
    --webserver) [[ $# -ge 2 ]] || die "--webserver needs a value"
                 [[ $2 =~ ^(nginx|caddy|apache)$ ]] || die "--webserver must be nginx, caddy or apache"
                 CFG[arg_webserver]=$2; shift ;;
    --add-domain) PRESET=domain ;;
    --add-database) PRESET=database ;;
    --email)   [[ $# -ge 2 ]] || die "--email needs a value"; CFG[arg_email]=$2; shift ;;
    --domain)  [[ $# -ge 2 ]] || die "--domain needs a value"; CFG[arg_domain]=$2; shift ;;
    --site-type) [[ $# -ge 2 ]] || die "--site-type needs a value"; CFG[arg_type]=$2; shift ;;
    --port)    [[ $# -ge 2 ]] || die "--port needs a value"; CFG[arg_port]=$2; shift ;;
    --redirect-to) [[ $# -ge 2 ]] || die "--redirect-to needs a value"; CFG[arg_target]=$2; shift ;;
    --engine)  [[ $# -ge 2 ]] || die "--engine needs a value"
               [[ $2 =~ ^(postgresql|mysql)$ ]] || die "--engine must be postgresql or mysql"
               CFG[arg_engine]=$2; shift ;;
    --db)      [[ $# -ge 2 ]] || die "--db needs a value"; CFG[arg_db]=$2; shift ;;
    --db-user) [[ $# -ge 2 ]] || die "--db-user needs a value"; CFG[arg_db_user]=$2; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------ preflight
preflight_root() {
  if (( EUID != 0 && DRY_RUN == 0 )); then die "$(t err.root)"; fi
}

ensure_whiptail() {
  (( ASSUME_YES )) && return 0
  command -v whiptail >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || die "$(t err.no_apt)"
  echo "Installing whiptail (needed for the menus)..."
  if (( EUID != 0 )); then die "$(t err.root)"; fi
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail >>"$LOG_FILE" 2>&1 \
    || die "Could not install whiptail (see $LOG_FILE)"
}

choose_language() {
  if [[ -z $LANG_CODE ]]; then
    if (( ASSUME_YES )); then
      LANG_CODE=en
    else
      LANG_CODE=$(ui_menu "$(t lang.title)" "$(t lang.text)" en en "English" id "Bahasa Indonesia") || quit_cancel
    fi
  fi
  case $LANG_CODE in
    en) ;;
    id) # shellcheck source=lib/i18n/id.sh
        source "$ROOT_DIR/lib/i18n/id.sh" ;;
    *) die "$(t err.bad_lang "$LANG_CODE")" ;;
  esac
  ui_init
}

quit_cancel() { echo; log_info "$(t msg.cancelled)"; exit 130; }

check_os() {
  detect_os || die "$(t err.os_unsupported "unknown")"
  local rc=0
  os_check || rc=$?
  case $rc in
    2) die "$(t err.os_unsupported "$OS_PRETTY")" ;;
    1) ui_msg "$OS_PRETTY" "$(t warn.os_untested "$OS_PRETTY")" ;;
  esac
}

load_modules() {
  local dir="$ROOT_DIR/modules/$OS_ID" f
  [[ -d $dir ]] || die "$(t err.os_unsupported "$OS_PRETTY")"
  for f in "$dir"/*.sh; do
    # shellcheck source=/dev/null
    source "$f"
  done
}

# ------------------------------------------------------------------ menus
show_help() {
  local id text=""
  for id in "${FEATURE_IDS[@]}"; do
    text+="$(t "feat.$id.title")"$'\n'"  $(t "feat.$id.desc")"$'\n\n'
  done
  ui_scroll "$(t help.title)" "$text"
}

welcome() {
  ui_msg "$(t welcome.title)" "$(t welcome.text "$OS_PRETTY" "$MEM_MB" "$CPU_COUNT" "$LOG_FILE")"
}

select_preset() {
  local choice
  [[ -n $PRESET ]] && return 0
  while true; do
    choice=$(ui_menu "$(t menu.main.title)" "$(t menu.main.text)" recommended \
      recommended "$(t menu.recommended)" \
      minimal "$(t menu.minimal)" \
      custom "$(t menu.custom)" \
      domain "$(t menu.domain)" \
      help "$(t menu.help)" \
      quit "$(t menu.quit)") || quit_cancel
    case $choice in
      help) show_help ;;
      quit) quit_cancel ;;
      *) PRESET=$choice; return 0 ;;
    esac
  done
}

load_preset() {
  local name=$1 f="$ROOT_DIR/presets/$1.list" id
  PRESET_SET=()
  if [[ $name == custom ]]; then
    for id in "${FEATURE_IDS[@]}"; do
      [[ ${FEATURE_DEFAULT[$id]} == on ]] && PRESET_SET[$id]=1
    done
    return 0
  fi
  [[ -f $f ]] || die "$(t err.no_preset "$name")"
  while IFS= read -r id; do
    id=${id%%#*}; id=${id//[[:space:]]/}
    [[ -n $id ]] && PRESET_SET[$id]=1
  done <"$f"
}

select_features() {
  local id state chosen
  local -a args=()
  load_preset "$PRESET"
  for id in "${FEATURE_IDS[@]}"; do
    state=off
    [[ -n ${PRESET_SET[$id]:-} ]] && state=on
    args+=("$id" "$(t "feat.$id.title")" "$state")
  done
  chosen=$(ui_checklist "$(t select.title)" "$(t select.text)" "${args[@]}") || quit_cancel
  SELECTED_SET=()
  for id in $chosen; do SELECTED_SET[$id]=1; done
  if (( ${#SELECTED_SET[@]} == 0 )); then log_info "$(t select.none)"; exit 0; fi
}

prompt_features() {
  local id
  for id in "${FEATURE_IDS[@]}"; do
    feature_selected "$id" || continue
    declare -F "prompt_$id" >/dev/null || continue
    if ! "prompt_$id"; then
      log_warn "$(t prompt.skipped "$(t "feat.$id.title")")"
      unset "SELECTED_SET[$id]"
    fi
  done
  if (( ${#SELECTED_SET[@]} == 0 )); then log_info "$(t select.none)"; exit 0; fi
}

review() {
  local id text n=0 line
  text="$(t review.head)"$'\n\n'
  (( DRY_RUN )) && text+="$(t review.dry)"$'\n\n'
  for id in "${FEATURE_IDS[@]}"; do
    feature_selected "$id" || continue
    n=$((n + 1))
    text+="$n. $(t "feat.$id.title")"$'\n'
    if declare -F "summary_$id" >/dev/null; then
      line=$("summary_$id")
      text+="     $line"$'\n'
    fi
  done
  text+=$'\n'"$(t review.ask)"
  ui_yesno "$(t review.title)" "$text" yes || quit_cancel
}

# ------------------------------------------------------------------ execution
run_features() {
  local id title i=0 total=0 rc
  for id in "${FEATURE_IDS[@]}"; do feature_selected "$id" && total=$((total + 1)); done
  (( DRY_RUN )) && log_dry "no changes will be made"

  for id in "${FEATURE_IDS[@]}"; do
    feature_selected "$id" || continue
    i=$((i + 1))
    title=$(t "feat.$id.title")
    log_step "[$i/$total] $title"
    rc=0
    ( set -e; "run_$id" )
    rc=$?
    case $rc in
      0)  RESULT[$id]=ok; state_mark "$id" ok ;;
      10) RESULT[$id]=skipped; state_mark "$id" skipped ;;
      *)  RESULT[$id]=failed; state_mark "$id" failed; log_err "$title: $(t run.failed)" ;;
    esac
  done
}

summary() {
  local id status mark notes="" out
  log_step "$(t summary.title)"
  for id in "${FEATURE_IDS[@]}"; do
    feature_selected "$id" || continue
    status=${RESULT[$id]:-skipped}
    case $status in
      ok)      mark="${C_GREEN}✓${C_RESET} $(t summary.ok)" ;;
      skipped) mark="${C_YELLOW}–${C_RESET} $(t summary.skipped)" ;;
      failed)  mark="${C_RED}✗${C_RESET} $(t summary.failed)" ;;
    esac
    printf '  %s  %s\n' "$mark" "$(t "feat.$id.title")"
    if [[ $status == ok ]] && declare -F "notes_$id" >/dev/null; then
      out=$("notes_$id" 2>/dev/null || true)
      [[ -n $out ]] && notes+="$out"$'\n'
    fi
  done

  if [[ -n $notes || -f /var/run/reboot-required ]]; then
    printf '\n%s%s%s\n' "$C_BOLD" "$(t summary.next)" "$C_RESET"
    [[ -n $notes ]] && printf '%s' "$notes" | sed 's/^/  /'
    [[ -f /var/run/reboot-required ]] && printf '  %s\n' "$(t note.reboot)"
  fi
  printf '\n%s\n' "$(t summary.log "$LOG_FILE")"
  (( DRY_RUN )) && printf '%s\n' "$(t summary.dry)"

  for id in "${!RESULT[@]}"; do [[ ${RESULT[$id]} == failed ]] && return 1; done
  return 0
}

# ------------------------------------------------------------------ main
main() {
  preflight_root
  if (( ASSUME_YES )) && [[ -z $PRESET ]]; then die "$(t err.yes_preset)"; fi
  ensure_whiptail
  ui_init
  choose_language
  check_os
  load_modules
  detect_hw
  welcome
  select_preset
  select_features
  prompt_features
  review
  run_features
  summary
}

main "$@"
