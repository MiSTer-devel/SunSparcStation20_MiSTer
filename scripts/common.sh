# Sourced by the other scripts: repository root, local.env, ssh helpers.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi
: "${MISTER_SSH_USER:=root}"
: "${MISTER_CORE_FOLDER:=_Unstable}"
: "${QUARTUS_BIN:=$HOME/intelFPGA_lite/17.0/quartus/bin}"
PROJECT=SunSparcStation
GAMES_DIR=SunSparcStation            # CONF_STR's first field
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -n "${MISTER_SSH_KEY:-}" ] && SSH_OPTS+=(-i "$MISTER_SSH_KEY")
DEV="$MISTER_SSH_USER@${MISTER_HOST:-}"
log() { echo "[$(date +%H:%M:%S)] $*"; }
rev_of() {   # 20 | ss20 | SunSparcStation20 -> revision name (the only one)
    case "$1" in
        20|ss20|SunSparcStation20) echo SunSparcStation20 ;;
        *) echo "unknown revision '$1' (use 20)" >&2; return 1 ;;
    esac
}
