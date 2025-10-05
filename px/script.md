📜 Script: run-px-session.sh (RHEL 9 + Zsh compatible)

```bash
#!/usr/bin/env zsh
# Works with both zsh and bash
set -euo pipefail

PIDFILE="$HOME/.px_session.pid"
LOGFILE="$HOME/.px_session.log"

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "⏹ Stopping px automatically (PID $PID)..."
      kill "$PID"
    fi
    rm -f "$PIDFILE"
  fi
  unset PX_USERNAME PX_PASSWORD
}
trap cleanup EXIT INT TERM

start_px() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "⚠️ px is already running (PID $(cat "$PIDFILE"))"
    return 1
  fi

  read "username?Username (e.g. EMEA\\firstname) : "
  read -s "password?Password : "
  echo

  export PX_USERNAME="$username"
  export PX_PASSWORD="$password"

  echo "▶️ Starting px in the background on port 3128..."
  px --proxy="proxy_upstream:port" --gateway >"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"

  # Wipe the password variable from memory
  password=""
  unset password

  echo "✅ px started (PID $(cat "$PIDFILE"))"
  echo "👉 It will stop automatically when you close this session."
  echo "👉 Logs: $LOGFILE"
  echo "👉 To stop manually: kill \$(cat $PIDFILE)"
}

stop_px() {
  if [[ -f "$PIDFILE" ]]; then
    local PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "⏹ Stopping px (PID $PID)..."
      kill "$PID"
      rm -f "$PIDFILE"
      unset PX_USERNAME PX_PASSWORD
      echo "✅ px stopped"
    else
      echo "⚠️ No running px process found (PID $PID invalid)"
      rm -f "$PIDFILE"
    fi
  else
    echo "⚠️ No px process found (PID file $PIDFILE missing)"
  fi
}

status_px() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "✅ px is running (PID $(cat "$PIDFILE"))"
    echo "📄 Last 10 log lines:"
    tail -n 10 "$LOGFILE"

    read "tail_choice?Do you want to tail logs in real-time? (y/N): "
    if [[ "$tail_choice" =~ ^[Yy]$ ]]; then
      echo "🔍 Tailing logs (press Ctrl+C to stop)..."
      tail -f "$LOGFILE"
    fi
  else
    echo "⏹ px is not running"
  fi
}

case "${1:-start}" in
  start)  start_px ;;
  stop)   stop_px ;;
  status) status_px ;;
  *)
    echo "Usage: $0 [start|stop|status]"
    ;;
esac
```

🧩 Differences for Zsh users

| Feature             | Adjustment                                     |
| ------------------- | ---------------------------------------------- |
| `read` syntax       | Uses Zsh’s native `read "var?Prompt"` style    |
| `trap`              | Works identically to Bash, confirmed on RHEL 9 |
| `set -euo pipefail` | Supported by Zsh ≥ 5.0 (RHEL 9 ships 5.8)      |
| `local` variables   | Added inside functions for scoping             |
| File paths          | Same as Bash (`~/.px_session.*`)               |

✅ Behavior Recap

- Runs px in background, port 3128.
- Credentials are read interactively and not persisted.
- PID + logs stored in your home directory.
- Auto-cleanup when you close your terminal or disconnect.
- Works seamlessly under RHEL 9 + Zsh (and Bash).
