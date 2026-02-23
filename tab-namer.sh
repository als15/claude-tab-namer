#!/usr/bin/env bash
# ============================================================================
# claude-tab-namer — Claude Code hook that auto-names terminal tabs
#
# Uses `claude` CLI for title generation — no API key needed!
# Reuses your existing OAuth (claude.ai) login.
#
# Install:
#   1. Save to ~/.claude/hooks/tab-namer.sh
#   2. chmod +x ~/.claude/hooks/tab-namer.sh
#   3. Add hook config to ~/.claude/settings.json
# ============================================================================

set -uo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
TITLE_PREFIX="${CLAUDE_NAMED_PREFIX:-🤖}"
STATE_DIR="${TMPDIR:-/tmp}/claude-tab-namer"
REFRESH_AFTER_TURNS=5
TITLE_TIMEOUT=15

# ── Read hook input from stdin ──────────────────────────────────────────────
HOOK_INPUT=$(cat)

# ── Extract session info ────────────────────────────────────────────────────
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

if [[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# ── Check state: should we generate a title this turn? ──────────────────────
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$SESSION_ID"

TURN_COUNT=0
CURRENT_TITLE=""

if [[ -f "$STATE_FILE" ]]; then
  TURN_COUNT=$(jq -r '.turn_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  CURRENT_TITLE=$(jq -r '.title // ""' "$STATE_FILE" 2>/dev/null || echo "")
fi

TURN_COUNT=$((TURN_COUNT + 1))

SHOULD_GENERATE=false
if [[ "$TURN_COUNT" -eq 1 ]]; then
  SHOULD_GENERATE=true
elif [[ $((TURN_COUNT % REFRESH_AFTER_TURNS)) -eq 0 ]]; then
  SHOULD_GENERATE=true
fi

# Save turn count now
jq -n --argjson tc "$TURN_COUNT" --arg t "$CURRENT_TITLE" \
  '{turn_count: $tc, title: $t}' > "$STATE_FILE" 2>/dev/null

if [[ "$SHOULD_GENERATE" == false ]]; then
  exit 0
fi

# ── Preflight ───────────────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  exit 0
fi

# ── Read transcript from JSONL file ─────────────────────────────────────────
TRANSCRIPT=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '
  select(.type == "human" or .type == "assistant")
  | if .type == "human" then
      "User: " + (
        .message.content
        | if type == "array" then map(select(.type == "text") | .text) | join(" ")
          elif type == "string" then .
          else ""
        end
      )
    elif .type == "assistant" then
      "Claude: " + (
        .message.content
        | if type == "array" then map(select(.type == "text") | .text) | join(" ")
          elif type == "string" then .
          else ""
        end
      )
    else ""
    end
' 2>/dev/null | head -c 3000)

if [[ -z "$TRANSCRIPT" || ${#TRANSCRIPT} -lt 20 ]]; then
  exit 0
fi

TRANSCRIPT="${TRANSCRIPT:0:2500}"

# ── Generate title via claude CLI ───────────────────────────────────────────
PROMPT="You name terminal tabs for coding sessions. Generate a concise 2-5 word title. Examples: \"React Auth Flow\", \"Fix CSV Parser\", \"DB Migration Setup\". Reply with ONLY the title, nothing else.

Session:
$TRANSCRIPT"

if [[ -n "$CURRENT_TITLE" ]]; then
  PROMPT="You name terminal tabs. The session was titled \"$CURRENT_TITLE\". Based on the conversation below, reply with an updated 2-5 word title (or same if still accurate). ONLY the title, nothing else.

Session:
$TRANSCRIPT"
fi

TITLE=$(timeout "$TITLE_TIMEOUT" claude -p "$PROMPT" --model claude-haiku-4-5-20251001 2>/dev/null)

# Validate
if [[ -z "$TITLE" || ${#TITLE} -gt 60 || ${#TITLE} -lt 2 ]]; then
  exit 0
fi

# Clean up quotes/whitespace
TITLE=$(echo "$TITLE" | tr -d '\n' | sed 's/^["'\'']*//; s/["'\'']*$//' | xargs)

# ── Set terminal tab title ──────────────────────────────────────────────────
printf '\033]2;%s %s\033\\' "$TITLE_PREFIX" "$TITLE" > /dev/tty 2>/dev/null || true

# Persist state
jq -n --argjson tc "$TURN_COUNT" --arg t "$TITLE" \
  '{turn_count: $tc, title: $t}' > "$STATE_FILE" 2>/dev/null

exit 0
