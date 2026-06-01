#!/usr/bin/env bash
#
# install.sh — make loopityloop's `loop.sh` runnable from anywhere.
#
# Symlinks loop.sh into a bin directory on your PATH (default: ~/.local/bin).
# loop.sh resolves the symlink back to this repo, so its sibling scripts
# (deny-check.sh, format-stream.sh) keep working — only the one symlink is needed.
#
# Idempotent: re-running just refreshes the symlink. Safe to run after `git pull`.
#
# Usage:
#   ./install.sh               # install into ~/.local/bin
#   BIN_DIR=~/bin ./install.sh # install into a different PATH dir
#   ./install.sh --uninstall   # remove the symlink

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/loop.sh"
TARGET="$REPO_DIR/loop.sh"

# Skills loop.sh invokes at runtime. They live in the repo under skills/ and are
# linked into the Claude Code skills dir so `claude` can find them by name.
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
SKILLS=(implement-phase verify-and-fix close-phase final-verification)

if [[ "${1:-}" == "--uninstall" ]]; then
	if [[ -L "$LINK" ]]; then
		rm -f "$LINK"
		echo "Removed $LINK"
	else
		echo "Nothing to remove at $LINK"
	fi
	# Only remove skill links that point back into this repo — never touch a
	# real directory the user manages by hand.
	for s in "${SKILLS[@]}"; do
		slink="$SKILLS_DIR/$s"
		if [[ -L "$slink" && "$(readlink "$slink")" == "$REPO_DIR/skills/$s" ]]; then
			rm -f "$slink"
			echo "Removed $slink"
		fi
	done
	exit 0
fi

# Sanity: the things loop.sh needs at runtime must be present and executable.
for f in loop.sh deny-check.sh format-stream.sh; do
	if [[ ! -f "$REPO_DIR/$f" ]]; then
		echo "install.sh: missing $REPO_DIR/$f — is the repo complete?" >&2
		exit 1
	fi
done
chmod +x "$REPO_DIR/loop.sh" "$REPO_DIR/deny-check.sh" "$REPO_DIR/format-stream.sh"

mkdir -p "$BIN_DIR"
ln -sfn "$TARGET" "$LINK"
echo "Linked $LINK -> $TARGET"

# Link the skills into the Claude Code skills dir.
mkdir -p "$SKILLS_DIR"
for s in "${SKILLS[@]}"; do
	src="$REPO_DIR/skills/$s"
	dst="$SKILLS_DIR/$s"
	if [[ ! -d "$src" ]]; then
		echo "install.sh: missing $src — is the repo complete?" >&2
		exit 1
	fi
	if [[ -e "$dst" && ! -L "$dst" ]]; then
		# A real dir/file already lives here (hand-managed skill). Don't clobber it.
		echo "SKIP skill '$s': $dst already exists and is not a symlink — leaving it untouched."
		echo "     (remove it yourself and re-run if you want the bundled version.)"
		continue
	fi
	ln -sfn "$src" "$dst"
	echo "Linked $dst -> $src"
done

# Warn if the chosen bin dir is not actually on PATH.
case ":$PATH:" in
	*":$BIN_DIR:"*) ;;
	*)
		echo
		echo "NOTE: $BIN_DIR is not on your PATH. Add this to your shell rc:"
		echo "  export PATH=\"$BIN_DIR:\$PATH\""
		;;
esac

echo
echo "Done. Open a new shell (or re-source your rc), then from a feature branch:"
echo "  cd <your repo> && loop.sh plan.md"
echo
echo "Skills linked under $SKILLS_DIR — set SKILLS_DIR=... to override."
