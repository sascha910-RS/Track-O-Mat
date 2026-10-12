# Track-O-Mat auf dem Raspberry Pi 4 einrichten

Diese Anleitung richtet einen Pi 4 Model B (4 GB RAM) mit aktuellem Raspberry Pi OS
(Desktop-Variante) so ein, dass er nach dem Einschalten `track-o-mat.html` in Chromium im
Kiosk-Modus zeigt.

Besonderheiten des Pi 4:

- **64-Bit-System verwenden.** Im Raspberry Pi Imager als Gerät «Raspberry Pi 4» und als
  System «Raspberry Pi OS (64-bit)» wählen.
- **Netzteil:** USB-C mit 5 V und mindestens 3 A, am besten das offizielle. Ein zu
  schwaches Netzteil oder ein dünnes Kabel bremst den Pi stark aus und führt zu
  Abstürzen und WLAN-Abbrüchen (Kontrolle: `vcgencmd get_throttled` muss
  `throttled=0x0` zeigen).
- **Zwei Micro-HDMI-Anschlüsse.** Es braucht ein Kabel oder einen Adapter von Micro-HDMI
  auf HDMI. Das Display kommt an den Anschluss direkt neben der USB-C-Buchse (HDMI 0);
  er heisst im System `HDMI-A-1`, der zweite `HDMI-A-2`.
- **WLAN ist eingebaut** und funkt auf 2,4 und 5 GHz. Das WLAN richtest du im Raspberry
  Pi Imager oder mit `sudo raspi-config` → *System Options* → *Wireless LAN* ein.
  Schritt 8 hält die Verbindung im Dauerbetrieb stabil.
- **Kühlung.** Der Pi 4 wird im Dauerbetrieb warm und drosselt ab 80 °C. In einem
  geschlossenen Gehäuse hinter dem Display Kühlkörper oder ein Gehäuse mit Kühlung
  verwenden (Kontrolle: `vcgencmd measure_temp`).

### Umzug von einem bereits eingerichteten Pi 3

Die SD-Karte eines mit dieser Anleitung eingerichteten Pi 3 (64-Bit-System) lässt sich
direkt in den Pi 4 stecken: Autostart, Tastenkürzel, WLAN und die App-Dateien bleiben
erhalten. Danach nur `sudo apt update && sudo apt full-upgrade` ausführen und die
Kontrollen aus Schritt 9 durchgehen. Mit einem 32-Bit-System geht das ebenfalls;
empfohlen ist dann aber eine Neuinstallation mit 64 Bit.

## Platzhalter

Die Codeblöcke dieser Anleitung enthalten drei Platzhalter. Ermittle die Werte zuerst
auf dem Pi und setze sie dann beim Abtippen der Codeblöcke ein:

| Platzhalter | Bedeutung | So findest du den Wert |
|---|---|---|
| `pi` | dein Benutzername | `whoami` |
| `HDMI-A-1` / `HDMI-1` | Name des Displays | Wayland: `wlr-randr` · X11: `xrandr` |
| `TOUCH-NAME` | Name des Touch-Geräts | Wayland: `sudo libinput list-devices` · X11: `xinput list` |

Angepasst werden sie **nicht** in `track-o-mat.html` oder `kiosk.sh`, sondern in den
Konfigurationsdateien, die du in den Schritten 4, 6 und 7 auf dem Pi anlegst. Du
brauchst nur die Spalte, die zu deinem System passt (Schritt 2):

| Platzhalter | Wayland (labwc) | X11 |
|---|---|---|
| `pi` im Pfad `/home/pi/track-o-mat/kiosk.sh` | `~/.config/labwc/autostart` (1×, Schritt 6) und `~/.config/labwc/rc.xml` (2×, Schritt 7) | `~/.config/lxsession/LXDE-pi/autostart` (1×, Schritt 6) und `~/.config/openbox/lxde-pi-rc.xml` (2×, Schritt 7) |
| Displayname | `HDMI-A-1` in `~/.config/labwc/autostart` (Zeile `wlr-randr`) und in `~/.config/labwc/rc.xml` (`mapToOutput`) | `HDMI-1` in `~/.config/lxsession/LXDE-pi/autostart` (Zeile `@xrandr`) |
| `TOUCH-NAME` | `~/.config/labwc/rc.xml` (Zeile `<touch deviceName=…>`) | `~/.config/lxsession/LXDE-pi/autostart` (Zeile `@xinput set-prop`) |

Heisst dein Benutzer tatsächlich `pi`, bleibt der Pfad unverändert. Das `pi` in den
Dateinamen `LXDE-pi` und `lxde-pi-rc.xml` ist kein Benutzername und wird nie ersetzt.

Die Befehle wurden nicht auf einem echten Pi getestet. Dateinamen der Desktop-Sitzung
unterscheiden sich zwischen den OS-Versionen leicht; wo das der Fall ist, steht ein Prüfbefehl dabei.

## 1. Dateien kopieren

`track-o-mat.html` und `kiosk.sh` müssen im selben Ordner auf dem Pi liegen. Am einfachsten
holst du sie direkt auf dem Pi aus dem Repository:

```bash
git clone https://github.com/sascha910-RS/Track-O-Mat.git ~/track-o-mat
chmod +x ~/track-o-mat/kiosk.sh
```

Oder du kopierst sie von einem anderen Rechner per SSH. Diese Befehle laufen auf dem
Rechner, auf dem die Dateien liegen, nicht auf dem Pi (`HOSTNAME` ist der Name des Pi
aus dem Raspberry Pi Imager):

```bash
ssh pi@HOSTNAME.local 'mkdir -p ~/track-o-mat'
scp track-o-mat.html kiosk.sh pi@HOSTNAME.local:track-o-mat/
```

Alle weiteren Befehle dieser Anleitung laufen **auf dem Pi**: entweder direkt am Pi im
Terminal oder in einem SSH-Fenster (`ssh pi@HOSTNAME.local`). Die Eingabezeile zeigt
dann `pi@HOSTNAME`.

### Kurzer Test

Bevor du den Autostart einrichtest, prüfe, ob die Anzeige überhaupt läuft. Am Pi im
Terminal der Desktop-Sitzung genügt `~/track-o-mat/kiosk.sh run`. In einem SSH-Fenster
weiss das Skript nicht, auf welchem Bildschirm es anzeigen soll; dort sind es drei
Zeilen mehr:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
if [ -e "$XDG_RUNTIME_DIR/wayland-0" ]; then export WAYLAND_DISPLAY=wayland-0; else export DISPLAY=:0; fi
~/track-o-mat/kiosk.sh run
```

Track-O-Mat erscheint im Vollbild auf dem Bildschirm des Pi. Beenden mit `Ctrl+C` (auf dem
Mac die Taste **control**, nicht **command**) oder aus einem zweiten Fenster mit
`~/track-o-mat/kiosk.sh stop`.

Der Pi muss beim Booten automatisch in den Desktop einloggen:
`sudo raspi-config` → *System Options* → *Boot / Auto Login* → *Desktop Autologin*.

## 2. X11 oder Wayland?

```bash
echo $XDG_SESSION_TYPE
```

- Ausgabe `wayland` → Abschnitte mit **Wayland (labwc)** befolgen.
- Ausgabe `x11` → Abschnitte mit **X11** befolgen.

Wechseln kannst du unter `sudo raspi-config` → *Advanced Options* → *Wayland*.
Auf dem Pi 4 ist Wayland (labwc) die Voreinstellung und die empfohlene Variante. Die
X11-Abschnitte gelten, falls dein System damit läuft.

## 3. Bildschirmschoner und Energiesparmodus abschalten

Für beide Varianten:

`sudo raspi-config` → *Display Options* → *Screen Blanking* → **No**

Unter X11 schaltet `kiosk.sh` zusätzlich bei jedem Start `xset s off`, `xset s noblank`
und `xset -dpms`.

## 4. Display und Touch um 90° drehen

Ob `90` oder `270` (bzw. `left` oder `right`) richtig ist, hängt davon ab, wie das Display
montiert ist. Steht das Bild auf dem Kopf, nimm den jeweils anderen Wert.

### Wayland (labwc)

Drehung beim Start setzen: in `~/.config/labwc/autostart` (Datei anlegen, falls sie fehlt)
diese Zeile **vor** dem Kiosk-Start aus Schritt 6 eintragen:

```bash
wlr-randr --output HDMI-A-1 --transform 90
```

Touch mitdrehen: Das Touch-Gerät wird dem Display zugeordnet, dann folgt es dessen Drehung.
Das geschieht in `~/.config/labwc/rc.xml` (vollständige Datei siehe Schritt 7):

```xml
<touch deviceName="TOUCH-NAME" mapToOutput="HDMI-A-1" />
```

### X11

In die Autostart-Datei aus Schritt 6 **vor** dem Kiosk-Start eintragen:

```
@xrandr --output HDMI-1 --rotate left
@xinput set-prop "TOUCH-NAME" "Coordinate Transformation Matrix" 0 -1 1 1 0 0 0 0 1
```

Matrix je nach Drehrichtung:

| Drehung | Matrix |
|---|---|
| `left` (90° gegen den Uhrzeigersinn) | `0 -1 1 1 0 0 0 0 1` |
| `right` (90° im Uhrzeigersinn) | `0 1 0 -1 0 1 0 0 1` |

Kontrolle: Tippe in jede Ecke. Der Tipp muss dort ankommen, wo der Finger ist.

## 5. Mauszeiger ausblenden

Die App blendet den Zeiger bei Touch-Bedienung aus. Wird eine Maus angeschlossen und
bewegt, erscheint er und die App lässt sich mit der Maus bedienen; nach 5 Sekunden ohne
Mausbewegung oder beim nächsten Antippen verschwindet er wieder
(`mouseCursorHideSec` im `CONFIG`). Zusätzlich systemweit:

### Wayland (labwc)

labwc kann den Zeiger per Aktion verstecken; sie wird beim Start über einen simulierten
Tastendruck ausgelöst.

```bash
sudo apt install wtype
```

Das Tastenkürzel `Super+H` dafür steht in der `rc.xml` aus Schritt 7. In
`~/.config/labwc/autostart` kommt diese Zeile dazu:

```bash
(sleep 5 && wtype -M logo -k h -m logo) &
```

Braucht labwc ab Version 0.8.2 (`labwc --version`). Solange keine Maus bewegt wird,
bleibt der Zeiger danach unsichtbar; mit einer Maus erscheint er wieder.

### X11

```bash
sudo apt install unclutter
```

In die Autostart-Datei aus Schritt 6 eintragen:

```
@unclutter -idle 3 -root
```

`-idle 3` blendet den Zeiger nach 3 Sekunden Stillstand aus und lässt ihn bei
Mausbewegung wieder erscheinen. Mit `-idle 0` wäre eine Maus kaum benutzbar.

## 6. Chromium beim Booten im Kiosk-Modus starten

`kiosk.sh run` startet Chromium und startet ihn nach 2 Sekunden neu, wenn er abstürzt
oder geschlossen wird.

Auf dem Pi 4 zeigt Chromium die Seite direkt beim ersten Start. Auf einem Pi 3 blieb das
Fenster beim ersten Start nach dem Booten leer; erst der zweite Start zeigte die Seite.
Dafür gibt es in `kiosk.sh` die Einstellung `WARMUP_SEC` (voreingestellt `0` = aus): Mit
`WARMUP_SEC=30` beendet das Skript Chromium einmal pro Boot nach 30 Sekunden und startet
ihn neu.

### Wayland (labwc)

`~/.config/labwc/autostart`, vollständig:

```bash
wlr-randr --output HDMI-A-1 --transform 90
(sleep 5 && wtype -M logo -k h -m logo) &
/home/pi/track-o-mat/kiosk.sh run &
```

Taskleiste und Desktop abschalten, damit sie auch in den 2 Sekunden eines Neustarts
nicht per Touch erreichbar sind: In `/etc/xdg/labwc/autostart` die Zeilen mit
`pcmanfm` und `wf-panel-pi` mit `#` auskommentieren.

```bash
sudo nano /etc/xdg/labwc/autostart
```

Bildschirmtastatur abschalten:
`sudo raspi-config` → *Display Options* → *Onscreen Keyboard* → **Disable**

### X11

Der Name des Sitzungsordners hängt von der OS-Version ab. Prüfen:

```bash
ls /etc/xdg/lxsession/
```

Meist heisst er `LXDE-pi` (sonst unten den angezeigten Namen einsetzen). Systemdatei
als Vorlage kopieren und bearbeiten:

```bash
mkdir -p ~/.config/lxsession/LXDE-pi
cp /etc/xdg/lxsession/LXDE-pi/autostart ~/.config/lxsession/LXDE-pi/autostart
nano ~/.config/lxsession/LXDE-pi/autostart
```

Die Zeilen `@lxpanel …` (Taskleiste) und `@pcmanfm --desktop …` (Desktop) löschen,
dann ergänzen:

```
@xrandr --output HDMI-1 --rotate left
@xinput set-prop "TOUCH-NAME" "Coordinate Transformation Matrix" 0 -1 1 1 0 0 0 0 1
@unclutter -idle 3 -root
@/home/pi/track-o-mat/kiosk.sh run
```

### Chromium-Startparameter

`kiosk.sh` setzt diese Parameter. Wichtig: Mehrere `--disable-features=…` überschreiben
sich gegenseitig, deshalb stehen alle Funktionen in einer einzigen Liste.

| Parameter | Zweck |
|---|---|
| `--kiosk` | Vollbild ohne Adressleiste, Tabs und Menüs |
| `--user-data-dir=~/.config/track-o-mat-chromium` | eigenes Profil; `localStorage` (Filterwahl) bleibt erhalten |
| `--no-first-run` | kein Willkommens-Assistent |
| `--no-default-browser-check` | keine Standardbrowser-Frage |
| `--noerrdialogs` | keine Fehlerdialoge |
| `--disable-infobars` | keine Hinweisleisten |
| `--disable-session-crashed-bubble`, `--hide-crash-restore-bubble` | kein «Wiederherstellen»-Hinweis nach Absturz |
| `--disable-features=Translate,TranslateUI,OverscrollHistoryNavigation,TouchpadOverscrollHistoryNavigation,MediaRouter,InfiniteSessionRestore` | kein Übersetzungs-Popup, kein Zurück/Vorwärts per Wischen |
| `--overscroll-history-navigation=0` | Wisch-Navigation aus (ältere Chromium-Versionen) |
| `--disable-pinch` | kein Pinch-Zoom |
| `--disable-pull-to-refresh-effect` | kein Pull-to-Refresh |
| `--check-for-update-interval=31536000` | keine Update-Meldungen |
| `--disable-component-update` | keine Komponenten-Updates im Hintergrund |
| `--disable-notifications`, `--deny-permission-prompts` | keine Benachrichtigungen und Berechtigungsfragen |
| `--password-store=basic` | keine Schlüsselbund-Abfrage |
| `--hide-scrollbars` | keine Scrollbalken |
| `--force-device-scale-factor=1` | 1 CSS-Pixel = 1 Display-Pixel; die Seite skaliert sich selbst (siehe «Einstellungen der App») |
| `--window-position=0,0` | Fenster oben links |
| `--disk-cache-size=10485760` | Cache auf 10 MB begrenzen |
| `--ozone-platform=wayland` | nur unter Wayland, wird automatisch gesetzt |

Zusätzlich setzt das Skript vor jedem Start im Profil `exited_cleanly` auf `true`,
damit Chromium nach einem Absturz nichts wiederherstellen will. `--incognito` wird
bewusst nicht verwendet, weil sonst die Filterwahl nicht gespeichert bliebe.

## 7. Tastenkürzel für die Wartung

Zwei Tastenkürzel steuern den Kiosk. Sie werden im Fenstermanager eingerichtet, nicht in
der Webseite, und wirken deshalb auch, wenn die Seite hängt. Per Touch lassen sie sich
nicht auslösen.

| Tasten | Wirkung |
|---|---|
| `Ctrl+Alt+Shift+Q` | Wartung: zuerst den automatischen Neustart stoppen, dann Chromium beenden; der Desktop ist danach zugänglich |
| `Ctrl+Alt+Shift+K` | Kiosk wieder starten (oder im Terminal: `~/track-o-mat/kiosk.sh start`) |

Den automatischen Neustart übernimmt die Schleife in `kiosk.sh run`; einen separaten
systemd-Dienst gibt es nicht. `kiosk.sh stop` legt zuerst die Stopp-Markierung an und
beendet erst danach Chromium, damit die Schleife ihn nicht sofort wieder startet.

`Ctrl+Alt+F2` (Wechsel auf die Textkonsole) bleibt als Notausgang aktiv: Diese Anleitung
schaltet den Konsolenwechsel nirgends ab. Vorgehen siehe Schritt 10.

### Wayland (labwc)

`~/.config/labwc/rc.xml`:

```xml
<?xml version="1.0"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard>
    <default />
    <keybind key="C-A-S-q">
      <action name="Execute" command="/home/pi/track-o-mat/kiosk.sh stop" />
    </keybind>
    <keybind key="C-A-S-k">
      <action name="Execute" command="/home/pi/track-o-mat/kiosk.sh start" />
    </keybind>
    <keybind key="W-h">
      <action name="HideCursor" />
      <action name="WarpCursor" x="-1" y="-1" />
    </keybind>
  </keyboard>
  <touch deviceName="TOUCH-NAME" mapToOutput="HDMI-A-1" />
</openbox_config>
```

Existiert die Datei schon, nur die `<keybind>`-Blöcke und die `<touch>`-Zeile ergänzen.
Übernehmen mit `labwc --reconfigure` oder Neustart.

### X11 (openbox)

Den Namen der Openbox-Konfiguration prüfen:

```bash
ls /etc/xdg/openbox/
```

Meist `lxde-pi-rc.xml`. Kopieren, falls im Home noch nicht vorhanden, und bearbeiten:

```bash
mkdir -p ~/.config/openbox
cp -n /etc/xdg/openbox/lxde-pi-rc.xml ~/.config/openbox/lxde-pi-rc.xml
nano ~/.config/openbox/lxde-pi-rc.xml
```

Innerhalb von `<keyboard> … </keyboard>` einfügen:

```xml
<keybind key="C-A-S-q">
  <action name="Execute"><command>/home/pi/track-o-mat/kiosk.sh stop</command></action>
</keybind>
<keybind key="C-A-S-k">
  <action name="Execute"><command>/home/pi/track-o-mat/kiosk.sh start</command></action>
</keybind>
```

Übernehmen mit `openbox --reconfigure` oder Neustart.

## 8. WLAN-Energiesparmodus abschalten

Das eingebaute WLAN des Pi 4 heisst `wlan0`. Energiesparmodus für alle WLAN-Verbindungen
abschalten:

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager
```

Kontrolle (muss `Power save: off` zeigen):

```bash
/usr/sbin/iw dev wlan0 get power_save
```

Bricht die Verbindung trotzdem nach einiger Zeit ab, liegt es meist an einem von zwei
Dingen:

- **Zu schwaches Netzteil.** Ein USB-C-Netzteil mit 5 V und mindestens 3 A verwenden.
  `vcgencmd get_throttled` muss `throttled=0x0` zeigen; jeder andere Wert bedeutet
  Unterspannung oder Überhitzung.
- **WLAN-Land nicht gesetzt.** Ohne Land bleibt das WLAN gesperrt oder findet
  5-GHz-Netze nicht. `sudo raspi-config` → *Localisation Options* →
  *WLAN Country* → **CH**.

Die App selbst übersteht Unterbrüche: Sie zeigt die letzten Daten mit dem roten Hinweis
«Keine Verbindung» und versucht es alle 30 Sekunden erneut.

## 9. Neustart und Kontrolle

```bash
sudo reboot
```

Nach dem Booten erscheint Track-O-Mat im Vollbild und im Hochformat. Prüfen:

- `vcgencmd get_throttled` zeigt `throttled=0x0` und `vcgencmd measure_temp` bleibt
  deutlich unter 80 °C.

- Tippen trifft die richtige Kachel (Touch-Drehung stimmt).
- Kein Mauszeiger, keine Taskleiste.
- `Alt+F4` schliesst Chromium, nach 2 Sekunden ist die Anzeige wieder da.

## 10. Wartung per Tastatur

| Ziel | Vorgehen |
|---|---|
| Seite neu laden | `F5` |
| Chromium neu starten | `Alt+F4` (startet automatisch neu) |
| Kiosk beenden und Neustart-Schleife stoppen | `Ctrl+Alt+Shift+Q` |
| Terminal öffnen (nach dem Stoppen) | `Ctrl+Alt+T` |
| Kiosk wieder aktivieren | `Ctrl+Alt+Shift+K` oder `sudo reboot` |
| Zustand abfragen | `~/track-o-mat/kiosk.sh status` |

Falls die Tastenkürzel nicht greifen, geht es immer über die Textkonsole:

1. `Ctrl+Alt+F2` drücken und einloggen.
2. `~/track-o-mat/kiosk.sh stop`
3. Mit `Ctrl+Alt+F7` (X11) bzw. `Ctrl+Alt+F1` (Wayland) zurück zur grafischen Oberfläche.

Dasselbe funktioniert per SSH. Der Wartungsmodus gilt bis zum nächsten Neustart des Pi;
danach läuft der Kiosk wieder von selbst.

Hast du Taskleiste und Desktop in Schritt 6 abgeschaltet, bleibt nach `Ctrl+Alt+Shift+Q` ein
leerer Bildschirm. `Ctrl+Alt+T` öffnet dann ein Terminal.

## Einstellungen der App

Am Anfang des Scripts in `track-o-mat.html` steht das Objekt `CONFIG`: Station,
Abfrageintervall, Filter, Rückfall auf «Alle» nach Inaktivität
(`idleResetSec`, `0` = aus), nächtliches Neuladen (`nightlyReload`, `''` = aus) und Farben.

Oben rechts läuft eine Uhr im Stil der Schweizer Bahnhofsuhr: Der Sekundenzeiger braucht
für einen Umlauf 58,5 Sekunden (`clockSweepSec`), wartet dann oben und läuft weiter,
sobald der Minutenzeiger zur vollen Minute springt. Die Zeigerfarben folgen dem
Farbschema, im Nachtmodus ist das Zifferblatt dunkel.

### Restaurants

Rechts von «Info» öffnet der Knopf «Restaurants» eine Liste der Restaurants und
Take-aways rund um den Bahnhof, mit Öffnungsstatus und Luftlinien-Distanz. Offene Lokale
stehen zuerst; «Alle» zeigt auch die geschlossenen, mit «Zurück» und «Weiter» blättert
man. Nach `idleResetSec` ohne Berührung springt die Anzeige zu den Abfahrten zurück.

Die Daten stammen von OpenStreetMap. `kiosk.sh` holt sie einmal pro Tag ab 07:00 Uhr
(`refreshAt`) und legt sie als `places.js` neben die Seite; fehlt die Datei, holt es sie
sofort. War der Pi um 07:00 Uhr aus, folgt die Aktualisierung beim nächsten Start. Von
Hand geht es mit:

```bash
~/track-o-mat/kiosk.sh places
```

Im Block `restaurants` des `CONFIG` stehen Bahnhofskoordinaten, Umkreis (`radius`, in
Metern Luftlinie), die Arten (`types`) und eine Liste `exclude` für Lokale, die nicht
erscheinen sollen (exakter Name). Nach einer Änderung von Ort oder Umkreis
`kiosk.sh places` ausführen.

Der Öffnungsstatus ist so gut wie die Angaben in OpenStreetMap: Lokale ohne erfasste
Zeiten erscheinen als «unbekannt», Feiertage und Betriebsferien werden nicht
berücksichtigt. Falsche Zeiten lassen sich auf openstreetmap.org korrigieren.

### Bildschirmauflösung

Das Layout ist 768 Pixel breit und für das Hochformat gebaut. Mit `fitToScreen: true`
(Voreinstellung) skaliert die Seite es als Ganzes auf die Bildschirmbreite, ohne es zu
verzerren, und nutzt die ganze Höhe: Je höher der Bildschirm im Verhältnis zur Breite,
desto mehr Abfahrten zeigt die Liste.

| Display (hochkant betrieben) | Skalierung | Zeilen |
|---|---|---|
| 1440×900 → 900×1440 | 1,17 | 13 |
| 2048×1536 → 1536×2048 | 2 | 10 |

Die Zeilenzahl ergibt sich aus `rowHeight` (Mindesthöhe einer Zeile, voreingestellt 58).
Eine feste Anzahl erzwingst du mit `maxRows` (z. B. `10`; `0` = automatisch). Auf einem
Bildschirm im Querformat bleibt rechts ein Rand in der Hintergrundfarbe.

Die Drehung ins Hochformat geschieht im System (Schritt 4), nicht in der App. Mit
`fitToScreen: false` wird das Layout 1:1 in 768×1024 Pixeln oben links angezeigt.

Die tatsächliche Auflösung zeigt `wlr-randr` (Wayland) bzw. `xrandr` (X11).

Die API von transport.opendata.ch erlaubt eine begrenzte Zahl Abfragen pro Tag. Mit
30 Sekunden Intervall sind es 2880 pro Tag; das Intervall deshalb nicht stark verkürzen.
