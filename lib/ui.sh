#!/usr/bin/env bash
# shellcheck shell=bash
# whiptail wrappers. With --yes every call returns its default (no prompts).

UI_W=76
BACKTITLE="VPS Setup"

# Palet warna eksplisit. Tanpa ini whiptail memakai palet bawaan newt (tombol, judul dan
# item terpilih berwarna "red") yang di banyak tema terminal tampil pink/magenta.
# Hormati NEWT_COLORS / NEWT_COLORS_FILE bila user sudah mengatur sendiri.
ui_colors() {
  [[ -n ${NEWT_COLORS:-} || -n ${NEWT_COLORS_FILE:-} ]] && return 0
  [[ ${VPS_SETUP_COLORS:-} == default ]] && return 0
  export NEWT_COLORS='
    root=white,black
    roottext=cyan,black
    border=cyan,black
    window=white,black
    shadow=black,black
    title=cyan,black
    label=white,black
    textbox=white,black
    acttextbox=black,cyan
    button=black,white
    actbutton=black,cyan
    compactbutton=white,black
    checkbox=white,black
    actcheckbox=black,cyan
    entry=white,black
    disentry=gray,black
    listbox=white,black
    actlistbox=white,black
    sellistbox=cyan,black
    actsellistbox=black,cyan
    helpline=black,cyan
    emptyscale=,gray
    fullscale=,cyan
  '
}

ui_init() {
  ui_colors
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  UI_W=$(( cols - 6 ))
  (( UI_W > 78 )) && UI_W=78
  (( UI_W < 56 )) && UI_W=56
  BACKTITLE=$(t app.backtitle "$VERSION")
}

_wt() {
  whiptail --backtitle "$BACKTITLE" \
    --ok-button "$(t btn.ok)" --cancel-button "$(t btn.cancel)" \
    --yes-button "$(t btn.yes)" --no-button "$(t btn.no)" "$@"
}
_wt_cap() { _wt "$@" 3>&1 1>&2 2>&3; }
_lh() { local n=$1; (( n > 10 )) && n=10; printf '%s' "$n"; }

# ui_msg <title> <text>
ui_msg() {
  if (( ASSUME_YES )); then log_info "$2"; return 0; fi
  _wt --title "$1" --msgbox "$2" 0 "$UI_W"
}

# ui_scroll <title> <text>
ui_scroll() {
  if (( ASSUME_YES )); then return 0; fi
  _wt --title "$1" --scrolltext --msgbox "$2" 22 "$UI_W"
}

# ui_yesno <title> <text> [yes|no]   → exit status 0 = yes
ui_yesno() {
  local def=${3:-yes}
  if (( ASSUME_YES )); then [[ $def == yes ]]; return; fi
  local -a extra=()
  [[ $def == no ]] && extra=(--defaultno)
  _wt --title "$1" "${extra[@]}" --yesno "$2" 0 "$UI_W"
}

# ui_input <title> <text> <default>   → prints value
ui_input() {
  if (( ASSUME_YES )); then printf '%s' "$3"; return 0; fi
  _wt_cap --title "$1" --inputbox "$2" 0 "$UI_W" "$3"
}

# ui_password <title> <text>          → prints value
ui_password() {
  if (( ASSUME_YES )); then return 1; fi
  _wt_cap --title "$1" --passwordbox "$2" 0 "$UI_W"
}

# ui_menu <title> <text> <default> <tag> <label> ...   → prints tag
ui_menu() {
  local title=$1 text=$2 default=$3
  shift 3
  if (( ASSUME_YES )); then printf '%s' "$default"; return 0; fi
  _wt_cap --title "$title" --default-item "$default" \
    --menu "$text" 0 "$UI_W" "$(_lh $(( $# / 2 )))" "$@"
}

# ui_checklist <title> <text> <tag> <label> <on|off> ...  → prints tags, one per line
ui_checklist() {
  local title=$1 text=$2
  shift 2
  if (( ASSUME_YES )); then
    while (( $# >= 3 )); do
      [[ $3 == on ]] && printf '%s\n' "$1"
      shift 3
    done
    return 0
  fi
  _wt_cap --title "$title" --separate-output \
    --checklist "$text" 0 "$UI_W" "$(_lh $(( $# / 3 )))" "$@"
}
