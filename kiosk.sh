#!/bin/bash
# Track-O-Mat – Kiosk-Starter für Raspberry Pi OS (X11 und Wayland/labwc)
#
#   kiosk.sh run     Chromium im Kiosk-Modus starten und bei Absturz/Beenden neu starten
#   kiosk.sh stop    Wartung: Neustart-Schleife anhalten und Chromium beenden
#   kiosk.sh start   Kiosk wieder aktivieren (aus der grafischen Sitzung heraus)
#   kiosk.sh status  Zustand anzeigen
#   kiosk.sh places  Restaurantliste jetzt von OpenStreetMap holen (places.js)
#   kiosk.sh menu    Tagesmenü jetzt holen (menu.js)
#   kiosk.sh log     Protokoll zeigen (letzte 40 Zeilen; "kiosk.sh log 200" für mehr)

APP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROFILE="$HOME/.config/track-o-mat-chromium"       # eigenes Profil, getrennt vom normalen Browser
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STOP_FLAG="$RUN_DIR/track-o-mat.stop"              # existiert = Wartungsmodus (verschwindet beim Reboot)
PID_FILE="$RUN_DIR/track-o-mat.pid"
RESTART_DELAY=2

# Ressourcen-Monitor im Info-Fenster: misst CPU-Auslastung und belegten Arbeitsspeicher und
# legt sie als kleine Script-Datei ab, die die Seite liest (sie darf /proc nicht selbst lesen).
# Die Datei liegt in $RUN_DIR, also im Arbeitsspeicher, nicht auf der SD-Karte.
STATS_INTERVAL=5                                   # Sekunden zwischen zwei Messungen (0 = aus)
STATS_FILE="$RUN_DIR/track-o-mat-stats.js"
PROC_STAT=/proc/stat
PROC_MEMINFO=/proc/meminfo

# Die Seite erfährt über die Adresse, wo die Messwerte liegen
URL="file://$APP_DIR/track-o-mat.html"
if [ "$STATS_INTERVAL" -gt 0 ]; then URL="$URL?stats=$STATS_FILE"; fi

# Wächter: Stürzt nur der Tab ab oder friert die Seite ein, läuft Chromium weiter, und die
# Neustart-Schleife merkt nichts. Die Seite schreibt deshalb alle paar Sekunden einen Takt
# in ihren Fenstertitel ("[takt 1791830640]", heartbeatSec im CONFIG). Der Wächter liest
# den Titel über die lokale Debug-Schnittstelle von Chromium und startet Chromium neu,
# wenn sich der Takt nicht mehr ändert.
WATCH_PORT=9222                                    # Debug-Schnittstelle, nur auf 127.0.0.1 (0 = Takt nicht prüfen)
WATCH_INTERVAL=30                                  # Sekunden zwischen zwei Kontrollen
WATCH_STALL=5                                      # so viele Kontrollen ohne neuen Takt = Neustart (5 x 30 s)
DAILY_RESTART="03:35"                              # Chromium einmal pro Tag neu starten ('' = aus)

# Netzwerk-Wächter: Verliert der Pi das WLAN (etwa wenn der Router neu startet), versucht
# NetworkManager einige Male, sich neu zu verbinden, und gibt dann auf. Der Pi bliebe
# offline, bis jemand von Hand verbindet. Der Wächter fragt NetworkManager jede Minute
# nach dem Zustand und stösst nach NET_STALL Kontrollen ohne Verbindung selbst eine
# Verbindung an, danach alle NET_RETRY Kontrollen erneut (ab dem zweiten Versuch mit
# kurzem Aus- und Einschalten des WLANs). Er läuft auch in der Ruhezeit, damit der Pi am
# Morgen online ist; er fragt dabei nichts im Netz ab.
NET_INTERVAL=60                                    # Sekunden zwischen zwei Kontrollen (0 = aus)
NET_STALL=3                                        # so viele Kontrollen ohne Verbindung, bis er eingreift
NET_RETRY=5                                        # danach alle … Kontrollen ein neuer Versuch

# Protokoll: Starts, Abstürze, Eingriffe des Wächters und jede Restaurant-Abfrage
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/track-o-mat"
LOG_FILE="$LOG_DIR/kiosk.log"                      # ab LOG_MAX wird es zu kiosk.log.1
BROWSER_LOG="$LOG_DIR/chromium.log"                # Fehlerausgabe von Chromium (letzter Lauf: chromium.log.1)
LOG_MAX=262144                                     # Bytes pro Datei

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt "$LOG_MAX" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
  echo "$(date '+%F %T') $*" >> "$LOG_FILE" 2>/dev/null
}

# Erste Zeile einer Fehlerdatei, gekürzt (für das Protokoll)
first_line() {
  head -n 1 "$1" 2>/dev/null | cut -c1-200
}

BROWSER="$(command -v chromium || command -v chromium-browser)"

# Restaurantliste: einmal pro Tag von OpenStreetMap holen und als places.js neben die
# Seite legen. Die Seite kann das nicht selbst, weil der Dienst Anfragen aus einer lokalen
# Datei ablehnt. Ort, Umkreis und Uhrzeit stehen im CONFIG von track-o-mat.html.
PAGE="$APP_DIR/track-o-mat.html"
PLACES_FILE="$APP_DIR/places.js"
PLACES_APIS="https://overpass-api.de/api/interpreter https://overpass.private.coffee/api/interpreter"
PLACES_AGENT="Track-O-Mat/1.0 (+https://github.com/sascha910-RS/Track-O-Mat)"

page_value() {   # $1 = sed-Ausdruck, der den Wert aus dem CONFIG der Seite liefert
  sed -n "$1" "$PAGE" | head -n 1
}

# Prüft die Antwort des Dienstes und schreibt places.js neu ($1 = Antwort, $2 = Ziel).
# Die Seite lädt places.js als Script. Die Antwort wird deshalb nie unverändert
# übernommen: Sie muss gültiges JSON sein und wird aus den wenigen benötigten Feldern neu
# erzeugt, so kann sie keinen Programmcode enthalten. Gibt die Anzahl Lokale aus.
write_places() {
  python3 - "$1" "$2" <<'PY'
import json, math, sys, time

KEYS = ('name', 'amenity', 'cuisine', 'opening_hours', 'access')

def number(value):
    ok = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    return value if ok else None

try:
    with open(sys.argv[1], encoding='utf-8') as source:
        raw = json.load(source)
except (OSError, ValueError) as err:
    sys.exit('kein gültiges JSON (%s)' % err)
if not isinstance(raw, dict) or not isinstance(raw.get('elements'), list):
    sys.exit('Antwort ohne Liste "elements"')
# Bei Überlast antwortet der Dienst mit einer leeren Liste und einem "remark": nicht übernehmen
if raw.get('remark'):
    sys.exit('Dienst meldet: %s' % raw['remark'])

places = []
for element in raw['elements']:
    if not isinstance(element, dict) or not isinstance(element.get('tags'), dict):
        continue
    center = element.get('center')
    position = center if isinstance(center, dict) else element
    lat, lon = number(position.get('lat')), number(position.get('lon'))
    tags = {key: element['tags'][key] for key in KEYS if isinstance(element['tags'].get(key), str)}
    if lat is None or lon is None or 'name' not in tags:
        continue
    places.append({'lat': lat, 'lon': lon, 'tags': tags})

data = {'at': int(time.time()) * 1000, 'data': {'elements': places}}
with open(sys.argv[2], 'w', encoding='ascii') as target:
    target.write('window.TRACKOMAT_PLACES = %s;\n' % json.dumps(data))
print(len(places))
PY
}

update_places() {
  local lat lon radius names extra query url count tmp="$PLACES_FILE.tmp"
  lat="$(page_value 's/^ *lat: *\([0-9.]*\), *lon: *[0-9.]*,.*/\1/p')"
  lon="$(page_value 's/^ *lat: *[0-9.]*, *lon: *\([0-9.]*\),.*/\1/p')"
  radius="$(page_value 's/^ *radius: *\([0-9]*\),.*/\1/p')"
  if [ -z "$lat" ] || [ -z "$lon" ] || [ -z "$radius" ]; then
    echo "Ort oder Umkreis im CONFIG von track-o-mat.html nicht gefunden." >&2
    log "Restaurants: Ort oder Umkreis im CONFIG von track-o-mat.html nicht gefunden"
    return 1
  fi
  # include: ['A', 'B'] -> A|B; diese Lokale werden per Name bis 3 km weit gesucht
  names="$(page_value "s/^ *include: *\[\(.*\)\],.*/\1/p" | sed "s/[\"'] *, *[\"']/|/g; s/^ *[\"']//; s/[\"'] *\$//; s/\"/\\\\\"/g")"
  extra=""
  if [ -n "$names" ]; then
    extra="nwr[\"amenity\"][\"name\"~\"^($names)\$\"](around:3000,$lat,$lon);"
  fi
  # Etwas mehr Arten und 150 m mehr Umkreis holen als nötig; was erscheint, entscheiden
  # "types", "radius" und "include" in der Seite
  query="[out:json][timeout:40];(nwr[\"amenity\"~\"^(restaurant|fast_food|cafe|bar|pub|food_court)\$\"](around:$((radius + 150)),$lat,$lon);$extra);out center tags;"
  for url in $PLACES_APIS; do
    if ! curl -sS -f -m 70 -G -A "$PLACES_AGENT" --data-urlencode "data=$query" "$url" -o "$tmp" 2>"$tmp.err"; then
      log "Restaurants: $url nicht erreichbar ($(first_line "$tmp.err"))"
    elif count="$(write_places "$tmp" "$tmp.js" 2>"$tmp.err")" && mv "$tmp.js" "$PLACES_FILE"; then
      log "Restaurants: $count Lokale von $url übernommen"
      rm -f "$tmp" "$tmp.err"
      return 0
    else
      log "Restaurants: Antwort von $url verworfen ($(first_line "$tmp.err"))"
    fi
  done
  rm -f "$tmp" "$tmp.js" "$tmp.err"
  return 1
}

# Tagesmenü: Ein Lokal legt sein Tagesmenü als PDF ins Netz (menu im Block restaurants des
# CONFIG). kiosk.sh lädt es, sobald es sich geändert hat, liest die Menüs heraus und legt
# sie als menu.js neben die Seite. Das PDF enthält meist mehrere Tage im Voraus; die Seite
# zeigt nur das Menü mit dem heutigen Datum.
MENU_FILE="$APP_DIR/menu.js"
MENU_INTERVAL=3600                                 # Sekunden zwischen zwei Nachfragen (0 = aus)
MENU_STAMP="$RUN_DIR/track-o-mat-menu.stamp"       # trägt die Änderungszeit des zuletzt geladenen PDFs

menu_url() {
  page_value "s/^ *menu: *{.*url: *'\([^']*\)'.*/\1/p"
}

# Liest die Menüs aus dem PDF ($1) und schreibt menu.js ($2); gibt die gefundenen Tage aus.
# Das erledigt menu.py neben diesem Skript, nur mit der Standardbibliothek von python3.
write_menu() {
  python3 -I "$APP_DIR/menu.py" "$1" "$2"
}

# Lädt das PDF, wenn es neuer ist als das zuletzt geladene ($1 = force: auf jeden Fall), und
# ersetzt menu.js, wenn sich die Menüs geändert haben. Ergebnis in MENU_RESULT. Rückgabe:
# 0 = erledigt, 1 = Server nicht erreichbar (bald noch einmal versuchen), 2 = kein
# Tagesmenü eingerichtet, 3 = PDF unbrauchbar (erst ein geändertes PDF wird wieder gelesen).
update_menu() {
  local url code rc=0 tmp="$MENU_FILE.tmp$$" since=()
  MENU_RESULT=""
  url="$(menu_url)"
  if [ -z "$url" ]; then MENU_RESULT="kein Tagesmenü eingerichtet (menu im CONFIG)"; return 2; fi
  if [ "$1" != force ] && [ -f "$MENU_STAMP" ]; then since=(-z "$MENU_STAMP"); fi
  # -R übernimmt die Änderungszeit des PDFs vom Server, -z fragt mit ihr nach: Ist das PDF
  # nicht neuer, antwortet der Server mit 304 und schickt nichts
  if ! code="$(curl -sS -f -m 30 --max-filesize 5000000 -R -A "$PLACES_AGENT" "${since[@]}" \
                 -w '%{http_code}' -o "$tmp.pdf" "$url" 2>"$tmp.err")"; then
    MENU_RESULT="$url nicht erreichbar ($(first_line "$tmp.err"))"
    log "Tagesmenü: $MENU_RESULT"
    rm -f "$tmp.pdf" "$tmp.err"
    return 1
  fi
  if [ "$code" != 200 ] || [ ! -f "$tmp.pdf" ]; then
    MENU_RESULT="unverändert"
  else
    touch -r "$tmp.pdf" "$MENU_STAMP"
    if MENU_RESULT="$(write_menu "$tmp.pdf" "$tmp.js" 2>"$tmp.err")"; then
      if cmp -s "$tmp.js" "$MENU_FILE"; then
        MENU_RESULT="$MENU_RESULT, unverändert"
      elif mv -f "$tmp.js" "$MENU_FILE"; then
        log "Tagesmenü: $MENU_RESULT von $url übernommen"
      fi
    else
      MENU_RESULT="PDF von $url verworfen ($(first_line "$tmp.err"))"
      log "Tagesmenü: $MENU_RESULT"
      rc=3
    fi
  fi
  rm -f "$tmp.pdf" "$tmp.js" "$tmp.err"
  return $rc
}

# Wert aus dem Block "rest" des CONFIG ($1 = sed-Ausdruck). Auf den Block beschränkt,
# weil "enabled", "from" und "to" auch in anderen Blöcken vorkommen.
rest_value() {
  sed -n -e '/^ *rest: *{/,/^ *}/{' -e "$1" -e '}' "$PAGE" | head -n 1
}

# Ruhezeit laut CONFIG (Ruhetage und nächtliches Zeitfenster, Europe/Zurich): 0 = jetzt ruhen
is_rest_now() {
  local enabled from to days now names=(Mo Tu We Th Fr Sa Su) day
  enabled="$(rest_value 's/^ *enabled: *\([a-z]*\).*/\1/p')"
  [ "$enabled" = "true" ] || return 1
  from="$(rest_value "s/^ *from: *'\([0-9:]*\)'.*/\1/p")"
  to="$(rest_value "s/^ *from: *'[0-9:]*', *to: *'\([0-9:]*\)'.*/\1/p")"
  days="$(rest_value "s/^ *days: *\[\(.*\)\].*/\1/p")"
  now="$(TZ=Europe/Zurich date +%H:%M)"
  day="${names[$(( $(TZ=Europe/Zurich date +%u) - 1 ))]}"     # %u: 1 = Montag … 7 = Sonntag
  case "$days" in *"'$day'"*|*"\"$day\""*) return 0 ;; esac
  if [ -z "$from" ] || [ -z "$to" ] || [ "$from" = "$to" ]; then return 1; fi
  if [ "$from" \< "$to" ]; then
    [ ! "$now" \< "$from" ] && [ "$now" \< "$to" ]
  else
    [ ! "$now" \< "$from" ] || [ "$now" \< "$to" ]
  fi
}

# Läuft neben dem Kiosk: holt die Liste, wenn sie fehlt, sonst einmal pro Tag ab der
# refreshAt-Zeit. Nach einem Fehler folgt der nächste Versuch in 10 Minuten. In der
# Ruhezeit (Block "rest" im CONFIG) fragt es nie ab, auch nicht bei fehlender Datei.
places_loop() {
  local at
  while true; do
    if is_rest_now; then sleep 60; continue; fi
    at="$(page_value "s/^ *refreshAt: *'\([0-9:]*\)'.*/\1/p")"
    if [ ! -f "$PLACES_FILE" ] \
       || { [ "$(date -r "$PLACES_FILE" +%F)" != "$(date +%F)" ] && [ ! "$(date +%H:%M)" \< "${at:-07:00}" ]; }; then
      update_places || sleep 540
    fi
    sleep 60
  done
}

# Läuft neben dem Kiosk: fragt alle MENU_INTERVAL Sekunden nach, ob es ein neues PDF gibt.
# Beim Start wird es auf jeden Fall geladen, damit nach einem Update von menu.py die Menüs
# neu gelesen werden. War der Server nicht erreichbar, folgt der nächste Versuch nach
# 5 Minuten. In der Ruhezeit fragt es nie nach.
menu_loop() {
  local next=0 mode=force
  while true; do
    if [ "$SECONDS" -ge "$next" ] && ! is_rest_now; then
      update_menu "$mode"
      if [ $? = 1 ]; then
        next=$((SECONDS + 300))
      else
        next=$((SECONDS + MENU_INTERVAL)); mode=""
      fi
    fi
    sleep 60
  done
}

# Misst alle STATS_INTERVAL Sekunden die CPU-Auslastung seit der letzten Messung (aus
# /proc/stat) und den belegten Arbeitsspeicher (MemTotal minus MemAvailable aus
# /proc/meminfo) und schreibt beides nach STATS_FILE.
stats_loop() {
  local cpu_line user nice system idle iowait irq softirq steal total busy
  local prev_total=0 prev_busy=0 cpu mem_total mem_avail cores key value unit
  while true; do
    read -r cpu_line user nice system idle iowait irq softirq steal _ < "$PROC_STAT"
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    busy=$((total - idle - iowait))
    cpu=null
    if [ "$prev_total" -gt 0 ] && [ "$total" -gt "$prev_total" ]; then
      cpu=$(( (100 * (busy - prev_busy) + (total - prev_total) / 2) / (total - prev_total) ))
    fi
    prev_total=$total; prev_busy=$busy

    mem_total=0; mem_avail=0
    while read -r key value unit; do
      case "$key" in
        MemTotal:) mem_total=$value ;;
        MemAvailable:) mem_avail=$value ;;
      esac
    done < "$PROC_MEMINFO"
    cores="$(grep -c '^cpu[0-9]' "$PROC_STAT")"

    printf 'window.TRACKOMAT_STATS = {"at": %s000, "cpu": %s, "cores": %s, "memTotalKb": %s, "memUsedKb": %s};\n' \
      "$(date +%s)" "$cpu" "${cores:-0}" "$mem_total" "$((mem_total - mem_avail))" > "$STATS_FILE.tmp" \
      && mv -f "$STATS_FILE.tmp" "$STATS_FILE"
    sleep "$STATS_INTERVAL"
  done
}

# Zustand laut NetworkManager: "connected", "connecting", "disconnected", "asleep" …
net_state() {
  nmcli -t -f STATE general 2>/dev/null | head -n 1
}

# Läuft neben dem Kiosk, siehe NET_INTERVAL
net_loop() {
  local state down=0 tries=0 dev out since
  while sleep "$NET_INTERVAL"; do
    state="$(net_state)"
    case "$state" in
      connected*)
        if [ "$down" -ge "$NET_STALL" ]; then
          log "Netzwerk: wieder verbunden nach $((down * NET_INTERVAL / 60)) min ohne Verbindung"
        fi
        down=0; tries=0
        continue
        ;;
    esac
    down=$((down + 1))
    if [ "$down" -lt "$NET_STALL" ] || [ $(( (down - NET_STALL) % NET_RETRY )) != 0 ]; then continue; fi
    tries=$((tries + 1))
    since="seit $((down * NET_INTERVAL / 60)) min ohne Verbindung (NetworkManager: ${state:-keine Antwort})"
    dev="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | sed -n 's/^\(.*\):wifi$/\1/p' | head -n 1)"
    if [ -z "$dev" ]; then
      log "Netzwerk: $since, kein WLAN-Gerät gefunden"
      continue
    fi
    if [ "$tries" -ge 2 ]; then
      nmcli radio wifi off >/dev/null 2>&1; sleep 5
      nmcli radio wifi on >/dev/null 2>&1; sleep 10
    fi
    # Von Hand angestossen hebt NetworkManager auch eine Sperre nach zu vielen Fehlversuchen auf
    if out="$(nmcli -w 60 device connect "$dev" 2>&1)"; then
      log "Netzwerk: $since, Versuch $tries: $dev verbunden"
    else
      log "Netzwerk: $since, Versuch $tries auf $dev gescheitert ($(printf '%s' "$out" | head -n 1 | cut -c1-160))"
    fi
  done
}

# Läuft neben jedem Chromium-Start: prüft den Takt der Seite, löst den täglichen Neustart
# aus und begrenzt die Fehlerausgabe von Chromium. Beendet Chromium nur; den Neustart
# übernimmt die Schleife in run_loop.
watch_browser() {
  local start=$SECONDS beat last="" armed=0 stalled=0 why pids
  while sleep "$WATCH_INTERVAL"; do
    why=""
    if [ -f "$BROWSER_LOG" ] && [ "$(wc -c < "$BROWSER_LOG")" -gt "$LOG_MAX" ]; then
      : > "$BROWSER_LOG"
    fi

    if [ "$WATCH_PORT" -gt 0 ]; then
      beat="$(curl -s -m 5 "http://127.0.0.1:$WATCH_PORT/json/list" 2>/dev/null | grep -o '\[takt [0-9]*\]' | head -n 1)"
      if [ -n "$beat" ] && [ "$beat" != "$last" ]; then
        if [ "$armed" = 0 ]; then log "Wächter: Takt der Seite empfangen"; fi
        armed=1; stalled=0; last="$beat"
      elif [ "$armed" = 1 ]; then
        # Gezählt wird erst, nachdem die Seite einmal einen Takt geliefert hat. Ist die
        # Schnittstelle nicht verfügbar, greift der Wächter also nie fälschlich ein.
        stalled=$((stalled + 1))
      fi
      if [ "$stalled" -ge "$WATCH_STALL" ]; then
        why="Seite liefert seit $((stalled * WATCH_INTERVAL)) s keinen Takt mehr"
      fi
    fi

    # Frühestens 10 Minuten nach dem Start, damit in der Minute des Neustarts keine Schleife entsteht
    if [ -z "$why" ] && [ -n "$DAILY_RESTART" ] && [ "$(date +%H:%M)" = "$DAILY_RESTART" ] \
       && [ $((SECONDS - start)) -gt 600 ]; then
      why="täglicher Neustart"
    fi

    if [ -n "$why" ]; then
      log "Wächter: $why, Chromium wird neu gestartet"
      # PIDs vorher merken: das harte Beenden darf nie einen bereits neu gestarteten Chromium treffen
      pids="$(pgrep -f -- "--user-data-dir=$PROFILE")"
      # shellcheck disable=SC2086
      kill $pids 2>/dev/null
      sleep 5
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null
      return
    fi
  done
}

loop_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

run_loop() {
  if loop_running; then echo "Track-O-Mat-Kiosk läuft bereits."; exit 0; fi
  if [ -z "$BROWSER" ]; then echo "Chromium nicht gefunden." >&2; log "Start abgebrochen: Chromium nicht gefunden"; exit 1; fi
  echo $$ > "$PID_FILE"
  places_loop >/dev/null 2>&1 &
  PLACES_PID=$!
  STATS_PID=""
  if [ "$STATS_INTERVAL" -gt 0 ] && [ -r "$PROC_STAT" ] && [ -r "$PROC_MEMINFO" ]; then
    stats_loop >/dev/null 2>&1 &
    STATS_PID=$!
  fi
  MENU_PID=""
  if [ "$MENU_INTERVAL" -gt 0 ] && [ -n "$(menu_url)" ]; then
    menu_loop >/dev/null 2>&1 &
    MENU_PID=$!
  fi
  NET_PID=""
  if [ "$NET_INTERVAL" -gt 0 ]; then
    if command -v nmcli >/dev/null 2>&1; then
      net_loop >/dev/null 2>&1 &
      NET_PID=$!
    else
      log "Netzwerk-Wächter aus: nmcli (NetworkManager) nicht gefunden"
    fi
  fi
  WATCH_PID=""
  trap 'kill "$PLACES_PID" $STATS_PID $MENU_PID $NET_PID $WATCH_PID 2>/dev/null; rm -f "$PID_FILE" "$STATS_FILE" "$STATS_FILE.tmp" "$MENU_STAMP"; log "Kiosk-Schleife beendet"' EXIT
  rm -f "$STOP_FLAG"
  if [ -n "$WAYLAND_DISPLAY" ]; then SESSION="Wayland"; else SESSION="X11"; fi
  log "Kiosk-Schleife gestartet (PID $$, $BROWSER, $SESSION)"

  # Mehrere --disable-features überschreiben sich gegenseitig -> alles in EINER Liste
  FLAGS=(
    --kiosk                                   # Vollbild ohne Adressleiste, Tabs und Menüs
    --user-data-dir="$PROFILE"
    --no-first-run                            # kein Willkommens-Assistent
    --no-default-browser-check
    --noerrdialogs                            # keine Fehlerdialoge
    --disable-infobars
    --disable-session-crashed-bubble          # kein "Wiederherstellen"-Hinweis
    --hide-crash-restore-bubble
    --disable-features=Translate,TranslateUI,OverscrollHistoryNavigation,TouchpadOverscrollHistoryNavigation,MediaRouter,InfiniteSessionRestore
    --overscroll-history-navigation=0         # kein Zurück/Vorwärts per Wischen
    --disable-pinch                           # kein Pinch-Zoom
    --disable-pull-to-refresh-effect
    --check-for-update-interval=31536000      # keine Update-Meldungen (1 Jahr)
    --disable-component-update
    --disable-notifications
    --deny-permission-prompts
    --password-store=basic                    # keine Schlüsselbund-Abfrage
    --hide-scrollbars
    --force-device-scale-factor=1             # 1 CSS-Pixel = 1 Display-Pixel; die Seite skaliert sich selbst
    --window-position=0,0
    --disk-cache-size=10485760                # Cache auf 10 MB begrenzen (SD-Karte, RAM)
  )

  if [ "$WATCH_PORT" -gt 0 ]; then
    FLAGS+=(--remote-debugging-port="$WATCH_PORT")   # für den Wächter; Chromium bindet sie an 127.0.0.1
  fi

  if [ -n "$WAYLAND_DISPLAY" ]; then
    FLAGS+=(--ozone-platform=wayland)
  else
    # X11: Bildschirmschoner und Energiesparen des Displays abschalten
    xset s off; xset s noblank; xset -dpms
  fi

  while [ ! -f "$STOP_FLAG" ]; do
    # Nach einem Absturz als "sauber beendet" markieren, damit kein Wiederherstellen-Dialog erscheint
    PREFS="$PROFILE/Default/Preferences"
    if [ -f "$PREFS" ]; then
      sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$PREFS"
    fi

    # Fehlerausgabe des letzten Laufs aufbewahren: sie zeigt, warum Chromium beendet wurde
    mkdir -p "$LOG_DIR" 2>/dev/null
    if [ -s "$BROWSER_LOG" ]; then mv -f "$BROWSER_LOG" "$BROWSER_LOG.1"; fi
    # Lässt sich die Datei nicht anlegen (Karte voll, Ordner fehlt), darf das den Start nicht verhindern
    if ! : >> "$BROWSER_LOG"; then BROWSER_LOG=/dev/null; fi 2>/dev/null

    watch_browser >/dev/null 2>&1 &
    WATCH_PID=$!
    STARTED=$SECONDS
    log "Chromium gestartet"
    "$BROWSER" "${FLAGS[@]}" "$URL" >/dev/null 2>>"$BROWSER_LOG"
    CODE=$?
    kill "$WATCH_PID" 2>/dev/null
    WATCH_PID=""
    log "Chromium beendet (Code $CODE, lief $((SECONDS - STARTED)) s)"

    [ -f "$STOP_FLAG" ] && break
    sleep "$RESTART_DELAY"
  done
}

case "${1:-run}" in
  run)
    run_loop
    ;;
  stop)
    touch "$STOP_FLAG"
    log "Wartung: Kiosk gestoppt"
    pkill -f -- "--user-data-dir=$PROFILE"
    echo "Kiosk gestoppt (Wartungsmodus). Wieder aktivieren: Ctrl+Alt+Shift+K oder Neustart."
    ;;
  start)
    rm -f "$STOP_FLAG"
    if loop_running; then echo "Track-O-Mat-Kiosk läuft bereits."; exit 0; fi
    if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ]; then
      echo "Keine grafische Sitzung in dieser Konsole. Ctrl+Alt+Shift+K am Bildschirm drücken oder 'sudo reboot'." >&2
      exit 1
    fi
    nohup "$0" run >/dev/null 2>&1 &
    echo "Kiosk gestartet."
    ;;
  places)
    if update_places; then echo "Restaurantliste aktualisiert: $PLACES_FILE"
    else echo "Restaurantliste konnte nicht geladen werden. Grund: $0 log" >&2; exit 1; fi
    ;;
  menu)
    update_menu force
    case $? in
      0) echo "Tagesmenü: $MENU_RESULT ($MENU_FILE)" ;;
      1) echo "Tagesmenü konnte nicht geladen werden: $MENU_RESULT" >&2; exit 1 ;;
      *) echo "Tagesmenü: $MENU_RESULT" >&2; exit 1 ;;
    esac
    ;;
  status)
    if loop_running; then echo "Kiosk läuft (PID $(cat "$PID_FILE"))."; else echo "Kiosk läuft nicht."; fi
    if [ -f "$STOP_FLAG" ]; then echo "Wartungsmodus aktiv."; fi
    if is_rest_now; then echo "Ruhezeit: keine Abfragen."; fi
    if command -v nmcli >/dev/null 2>&1; then echo "Netzwerk: $(net_state)"; fi
    echo "Protokoll: $LOG_FILE"
    ;;
  log)
    if [ -f "$LOG_FILE" ]; then tail -n "${2:-40}" "$LOG_FILE"; else echo "Noch kein Protokoll: $LOG_FILE"; fi
    echo "Fehlerausgabe von Chromium: $BROWSER_LOG (letzter Lauf: $BROWSER_LOG.1)"
    ;;
  *)
    echo "Aufruf: $0 {run|stop|start|status|places|menu|log}" >&2
    exit 2
    ;;
esac
