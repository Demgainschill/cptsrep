#!/usr/bin/env bash
# cptsrep installer — idempotent, multi-distro, refuses non-script payloads
#   chmod +x install.sh ./cptsrep && sudo ./install.sh
#   ./install.sh --user
set -euo pipefail

PREFIX="${PREFIX:-}"
USER_INSTALL=0
SKIP_DEPS=0

usage() {
  cat <<'EOF'
install.sh [options]
  --user          install to ~/.local/bin (no root)
  --prefix DIR    install to DIR/bin (default /usr/local)
  --skip-deps     do not call apt/dnf/pacman/brew
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_INSTALL=1; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_real_script() {
  local f="$1" first n
  [[ -f "$f" && -s "$f" ]] || return 1
  first="$(head -n 1 "$f" | tr -d '\r')"
  [[ "$first" == "#!/usr/bin/env bash" || "$first" == "#!/bin/bash" ]] || return 1
  grep -q 'cptsrep' "$f" || return 1
  grep -q 'VERSION=' "$f" || return 1
  grep -qiE '<!DOCTYPE|<html' "$f" && return 1
  n="$(wc -c < "$f" | tr -d ' ')"
  [[ "$n" -ge 8000 ]] || return 1
  return 0
}

src=""
for c in "${here}/cptsrep" "${PWD}/cptsrep" "${here}/bin/cptsrep"; do
  if is_real_script "$c"; then src="$c"; break; fi
done
[[ -n "$src" ]] || die "no valid cptsrep next to install.sh
Need a bash file starting with #!/usr/bin/env bash (~21KB).
Do not save a chat message as cptsrep."

ver="$(awk -F= '/^VERSION=/{gsub(/"/,"",$2); print $2; exit}' "$src")"
log "source  $src  (VERSION=${ver:-unknown})"

if [[ "$USER_INSTALL" -eq 1 ]]; then
  PREFIX="${PREFIX:-$HOME/.local}"
elif [[ -z "$PREFIX" ]]; then
  PREFIX="/usr/local"
fi
BIN_DIR="${PREFIX}/bin"
DEST="${BIN_DIR}/cptsrep"

if [[ ! -d "$BIN_DIR" ]]; then
  mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR (try sudo or --user)"
fi
if [[ ! -w "$BIN_DIR" ]]; then
  die "cannot write $BIN_DIR — run: sudo $0   or   $0 --user"
fi

pkg_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  log "packages: ${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  if have apt-get; then
    apt-get update -qq
    apt-get install -y --no-install-recommends "${pkgs[@]}"
  elif have apt; then
    apt update -qq && apt install -y --no-install-recommends "${pkgs[@]}"
  elif have dnf; then dnf install -y "${pkgs[@]}"
  elif have yum; then yum install -y "${pkgs[@]}"
  elif have pacman; then pacman -Sy --noconfirm "${pkgs[@]}"
  elif have zypper; then zypper --non-interactive install "${pkgs[@]}"
  elif have apk; then apk add --no-cache "${pkgs[@]}"
  elif have brew; then brew install "${pkgs[@]}" || true
  else
    warn "no package manager; install manually: ${pkgs[*]}"
    return 1
  fi
}

if [[ "$SKIP_DEPS" -eq 0 ]]; then
  missing=()
  have bash || missing+=(bash)
  have awk || missing+=(gawk)
  have grep || missing+=(grep)
  have sed || missing+=(sed)
  have mktemp || missing+=(coreutils)
  have install || missing+=(coreutils)
  if ! have vim && ! have nvim; then missing+=(vim); fi
  if ! have xclip && ! have wl-copy && ! have xsel && ! have pbcopy; then
    missing+=(xclip)
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ "$(id -u)" -ne 0 ]] && have apt-get; then
      warn "need packages: ${missing[*]} — re-run with sudo, or --skip-deps"
    fi
    pkg_install "${missing[@]}" || warn "continuing without all deps"
  fi
fi

have bash && have awk && have grep || die "bash, awk and grep are required"
if ! have vim && ! have nvim && ! have nano; then
  warn "no editor found — export EDITOR=nano before cptsrep hosts"
fi

if have install; then
  install -m 0755 "$src" "$DEST"
else
  cp "$src" "$DEST" && chmod 0755 "$DEST"
fi
is_real_script "$DEST" || die "installed file failed sanity check: $DEST"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH yet (installer will append it to your rc)" ;;
esac

VAULT="${CPTSREP_VAULT:-$HOME/htbreporting/cpts}"
mkdir -p "$VAULT"
export CPTSREP_VAULT="$VAULT"
line="export CPTSREP_VAULT=\"$VAULT\""
path_line="export PATH=\"$BIN_DIR:\$PATH\""

add_rc() {
  local rc="$1" l="$2"
  [[ -e "$rc" || "$rc" == *"/.bashrc" || "$rc" == *"/.profile" ]] || return 0
  touch "$rc"
  grep -Fqx "$l" "$rc" 2>/dev/null && return 0
  printf '\n# cptsrep\n%s\n' "$l" >> "$rc"
}

for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  add_rc "$rc" "$line"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) add_rc "$rc" "$path_line" ;; esac
done

if [[ -d "$HOME/.config/fish" ]]; then
  mkdir -p "$HOME/.config/fish/conf.d"
  cat > "$HOME/.config/fish/conf.d/cptsrep.fish" <<EOF
set -gx CPTSREP_VAULT "$VAULT"
fish_add_path $BIN_DIR
EOF
fi

"$DEST" init "$VAULT" >/dev/null || warn "run: CPTSREP_VAULT=$VAULT $DEST init"

got="$("$DEST" version 2>/dev/null || true)"
log "binary  $DEST"
log "version ${got:-unknown}"
log "vault   $VAULT"
log "which   $(command -v cptsrep 2>/dev/null || echo "$DEST")"
echo
echo "done.  source ~/.bashrc"
echo "then:  cptsrep version && cptsrep list"
