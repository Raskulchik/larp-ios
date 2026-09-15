#!/usr/bin/env bash
# Установка larp-daemon на Arch: бинарник в ~/.local/bin, конфиг в ~/.config/larp-daemon,
# автозапуск через systemd --user. Демон отдаёт музыку только в локальной сети (без туннеля),
# лайки/плейлисты — из общей с music-player-tui базы ~/.config/music-player-tui/liked.db.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/larp-daemon"
CONF_DIR="$HOME/.config/larp-daemon"
CONF="$CONF_DIR/config.json"

echo "==> сборка release daemon"
cargo build --release -p larp-daemon

echo "==> установка бинарника"
mkdir -p "$HOME/.local/bin"
cp target/release/larp-daemon "$BIN"
chmod +x "$BIN"

echo "==> конфиг"
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
{
  "listen": "0.0.0.0",
  "port": 47110,
  "yandex_token": "",
  "download_dir": "$HOME/.local/share/larp-daemon",
  "db_path": "$HOME/.config/music-player-tui/liked.db",
  "ytdlp": "yt-dlp",
  "ytdlp_cookies": "",
  "ytdlp_cookies_browser": "firefox"
}
EOF
  # конфиг выше пишется из quoted-heredoc, поэтому разворачиваем $HOME руками
  sed -i "s|\$HOME|$HOME|g" "$CONF"
  # Подтянуть токен из music-player-tui, если он там есть.
  if [ -f "$HOME/.config/music-player-tui/config.json" ]; then
    TOKEN=$(python3 - "$HOME/.config/music-player-tui/config.json" <<'EOF' 2>/dev/null || true
import json,sys
try:
    print(json.load(open(sys.argv[1])).get("yandex_token",""))
except Exception:
    print("")
EOF
)
    if [ -n "$TOKEN" ]; then
      python3 - "$CONF" "$TOKEN" <<'EOF'
import json,sys
p,t=sys.argv[1],sys.argv[2]
c=json.load(open(p))
c["yandex_token"]=t
json.dump(c,open(p,"w"),ensure_ascii=False,indent=2)
print("токен yandex подтянут из music-player-tui")
EOF
    fi
  fi
else
  echo "конфиг уже есть — не трогаем: $CONF"
fi

echo "==> systemd user unit + автозапуск"
mkdir -p "$HOME/.config/systemd/user"
cp larp-daemon.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now larp-daemon
systemctl --user --no-pager status larp-daemon | head -12

echo
echo "Конфиг:      $CONF"
echo "Токен доступа к демону не нужен — демон доступен только в локальной сети."
PY=$(python3 -c "import json;print('yes' if json.load(open('$CONF')).get('yandex_token') else 'no')" 2>/dev/null || echo "?")
echo "Yandex token: $PY"
echo "База лайков/плейлистов (общая с music-player-tui):"
python3 -c "import json;print('  '+json.load(open('$CONF')).get('db_path',''))" 2>/dev/null || true
echo "Порт:        47110"
echo "IP компьютера (указать на телефоне):"
hostname -I 2>/dev/null | awk '{print "  " $1}' || true

echo
echo "Firewall, если включён:"
echo "  ufw:        sudo ufw allow 47110/tcp"
echo "  firewalld:  sudo firewall-cmd --permanent --add-port=47110/tcp && sudo firewall-cmd --reload"