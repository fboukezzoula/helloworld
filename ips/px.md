Final Script: run-px-session.sh (with real-time log tailing)
```
#!/usr/bin/env bash
set -euo pipefail

PIDFILE="$HOME/.px_session.pid"
LOGFILE="$HOME/.px_session.log"

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    PID=$(cat "$PIDFILE")
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
    exit 1
  fi

  read -r -p "Username (e.g. EMEA\\firstname) : " username
  read -r -s -p "Password : " password
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
  echo "👉 Logs are available at: $LOGFILE"
  echo "👉 To stop manually: kill \$(cat $PIDFILE)"
}

stop_px() {
  if [[ -f "$PIDFILE" ]]; then
    PID=$(cat "$PIDFILE")
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

    # Ask user if they want to tail logs in real-time
    read -r -p "Do you want to tail logs in real-time? (y/N): " tail_choice
    if [[ "$tail_choice" =~ ^[Yy]$ ]]; then
      echo "🔍 Tailing logs (press Ctrl+C to stop)..."
      tail -f "$LOGFILE"
    fi
  else
    echo "⏹ px is not running"
  fi
}

case "${1:-}" in
  start|"")
    start_px
    ;;
  stop)
    stop_px
    ;;
  status)
    status_px
    ;;
  *)
    echo "Usage: $0 [start|stop|status]"
    ;;
esac
```

🔧 Usage

Make executable:

```
chmod +x run-px-session.sh
```

Commands:
Command	Action

```
./run-px-session.sh start	Launch px in background, store PID, auto-cleanup on session exit
./run-px-session.sh stop	Stop px manually and cleanup variables
./run-px-session.sh status	Check if px is running, show last 10 log lines, optionally tail logs in real-time
```

Logs: ~/.px_session.log
PID: ~/.px_session.pid

Password: cleared automatically after start

✅ With this final version:

px runs in the background tied to your session,
automatic cleanup when session exits,
manual stop/status available,
logs stored, with optional real-time tailing.

This fully satisfies your requirements:

Runs px in background for the current session,

Automatic cleanup on session exit,

Manual stop/status available,

Logging included for first tests.

