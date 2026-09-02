# UniFi Controller Sensor für PRTG

PRTG-Sensor vom Typ **EXE/Script Advanced (EXEXML)**, der UniFi-Switches,
Access Points und Gateways überwacht – auf **allen aktuellen UniFi-Plattformen**,
von der Cloud Key Gen2 über den UniFi OS Server bis zur alten selbst gehosteten
Network Application. Ein Skript, ein Sensortyp, überall die gleichen Kanäle.

```
Site 'Hauptstandort' | 23/24 online | 8/8 switches | 14/15 APs | 2 firmware update(s) | UniFi OS (443) | Offline: AP-Lager
```

---

## Inhalt

- [Was der Sensor liefert](#was-der-sensor-liefert)
- [Unterstützte Plattformen](#unterstützte-plattformen)
- [Voraussetzungen](#voraussetzungen)
- [Schritt 1 – Zugang auf der UniFi-Seite anlegen](#schritt-1--zugang-auf-der-unifi-seite-anlegen)
- [Schritt 2 – Skript auf der PRTG-Probe installieren](#schritt-2--skript-auf-der-prtg-probe-installieren)
- [Schritt 3 – Sensor in PRTG anlegen](#schritt-3--sensor-in-prtg-anlegen)
- [Zugangsdaten sicher hinterlegen](#zugangsdaten-sicher-hinterlegen)
- [Parameterreferenz](#parameterreferenz)
- [Kanäle](#kanäle)
- [Beispiele nach Plattform](#beispiele-nach-plattform)
- [Wie das Skript den Zugang findet](#wie-das-skript-den-zugang-findet)
- [Fehlerbehebung](#fehlerbehebung)
- [Bekannte Einschränkungen](#bekannte-einschränkungen)
- [Lokal testen](#lokal-testen)

---

## Was der Sensor liefert

Ein Sensor pro Site. Er fragt alle UniFi-Geräte dieser Site ab und aggregiert sie
zu Zählern und Mittelwerten:

- Geräte gesamt / online / offline / in Übergangszuständen (Adoption, Update, Provisioning …)
- Aufgeschlüsselt nach Switches, Access Points und Gateways
- CPU-, RAM-, Uptime- und Uplink-Werte (optional abschaltbar)
- Firmware-Updates, nicht unterstützte Geräte, Switch-Ports und PoE (optional zuschaltbar)
- Namen der offline gegangenen Geräte in der Sensormeldung

Voreingestellte Limits setzen den Sensor bei einem Offline-Gerät auf **Fehler**
und bei ausstehenden Firmware-Updates oder Übergangszuständen auf **Warnung**.
Alle Limits lassen sich in PRTG pro Kanal überschreiben.

## Unterstützte Plattformen

| Plattform | Port | Authentifizierung | Pfad |
| --- | --- | --- | --- |
| UniFi OS Console (Cloud Key Gen2/2+, Cloud Key Enterprise, UDM, UDM Pro, UXG …) | 443 | API-Key (oder Login) | `/proxy/network/integration` |
| UniFi OS Server (Linux-/Windows-VM) | 11443 | API-Key (oder Login) | `/proxy/network/integration` |
| Legacy self-hosted Network Application (.deb/.exe) | 8443 | lokaler Admin (Benutzer/Passwort) | klassische `/api` – **kein API-Key möglich** |
| Site Manager Cloud-Connector (`unifi.ui.com`) | 443 | Site-Manager-Key | `api.ui.com` – kein VPN/Portfreigabe nötig |

Das Skript hat zwei Datenpfade und wählt automatisch:

1. **Integration API** (`X-API-KEY`) – bevorzugt, wird per Probe automatisch gefunden.
2. **Klassische API** (lokaler Admin) – Fallback für die alte selbst gehostete
   Network Application, die keine API-Keys kennt.

Beide Pfade münden in dieselben Kanäle. Sensoren lassen sich dadurch über
gemischte Umgebungen hinweg klonen und vergleichen.

## Voraussetzungen

- PRTG Network Monitor (lokale oder Remote-Probe unter Windows)
- PowerShell 5.1 (Windows-Standard) oder PowerShell 7+
- Netzwerkzugang von der Probe zur Konsole auf 443, 11443 oder 8443
  (beim Site-Manager-Pfad stattdessen ausgehend zu `api.ui.com:443`)
- UniFi Network Application 9.x oder neuer für den API-Key-Pfad;
  ältere Versionen laufen über den klassischen Pfad

## Schritt 1 – Zugang auf der UniFi-Seite anlegen

### Variante A: API-Key (empfohlen, UniFi OS und UniFi OS Server)

1. In der **Network**-Anwendung anmelden.
2. **Settings → Control Plane → Integrations** öffnen.
3. **Create API Key** klicken, Namen vergeben (z. B. `prtg`), Key **sofort kopieren** –
   er wird nur einmal angezeigt.

Der Key gilt genau für diese Konsole. Für mehrere Konsolen wird pro Konsole ein
eigener Key erzeugt.

### Variante B: Lokaler Admin (Legacy 8443 – und als Fallback)

1. **Settings → Admins & Users → Add New Admin**
2. **Restrict to Local Access** aktivieren (kein Ubiquiti-SSO-Konto, kein Remote-Zugriff)
3. Benutzername/Passwort setzen, Rolle **View Only** genügt
4. **Kein MFA** für dieses Konto aktivieren – ein Skript kann keinen zweiten Faktor liefern

### Variante C: Site-Manager-Key (Konsole hinter CGNAT/DS-Lite)

1. `https://unifi.ui.com` öffnen → **API** → **Create API Key**
2. Die **Console ID** der Konsole notieren (steht in der URL bzw. in der Konsolenübersicht)

Damit läuft die Abfrage über die Ubiquiti-Cloud; die Probe braucht keinen direkten
Zugang zur Konsole.

## Schritt 2 – Skript auf der PRTG-Probe installieren

`Get-UniFiNetworkDevices.ps1` auf **jede** Probe kopieren, die den Sensor ausführen soll:

```
C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\Get-UniFiNetworkDevices.ps1
```

PRTG startet die **32-Bit-PowerShell**. Deshalb die Ausführungsrichtlinie in
**beiden** Hosts setzen (PowerShell jeweils als Administrator starten):

```powershell
# 64-Bit
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Set-ExecutionPolicy RemoteSigned

# 32-Bit
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe
Set-ExecutionPolicy RemoteSigned
```

Wurde die Datei aus dem Internet geladen, zusätzlich die Zone-Markierung entfernen:

```powershell
Unblock-File 'C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\Get-UniFiNetworkDevices.ps1'
```

## Schritt 3 – Sensor in PRTG anlegen

1. Gerät auswählen (idealerweise das Gerät mit der IP/dem FQDN der Konsole) →
   **Add Sensor** → nach **EXE/Script Advanced** suchen.
2. **EXE/Script**: `Get-UniFiNetworkDevices.ps1`
3. **Parameters**: die Aufrufparameter, z. B.

   ```
   -ConsoleHost "%host" -ApiKey "abcd1234..." -IgnoreSslErrors -IncludeDetails
   ```

4. **Security Context**: „Use security context of probe service" reicht,
   solange keine PRTG-Platzhalter für Zugangsdaten genutzt werden.
5. **Scanning Interval**: 60 Sekunden oder mehr. Mit `-IncludeDetails` und ohne
   `-NoStatistics` macht der Integration-API-Pfad zwei zusätzliche Aufrufe pro
   Gerät – bei großen Sites lieber 5 Minuten wählen.
6. Speichern. Der erste Scan dauert länger (Port-Erkennung), danach greift der Cache.

> **Anführungszeichen:** Werte mit Sonderzeichen (Passwörter, Site-Namen mit
> Leerzeichen) immer in `"` setzen. Enthält ein Passwort selbst ein `"`,
> sollte es geändert werden – PRTG übergibt die Parameterzeile unverändert an die Shell.

## Zugangsdaten sicher hinterlegen

Damit Key oder Passwort nicht im Klartext im Sensorfeld stehen, lassen sich die
**Zugangsdaten am Gerät oder an der Gruppe** hinterlegen und im Parameterfeld über
PRTG-Platzhalter referenzieren:

| PRTG-Einstellung am Gerät | Platzhalter |
| --- | --- |
| Credentials for Windows Systems | `%windowsuser`, `%windowspassword`, `%windowsdomain` |
| Credentials for Linux/Solaris/macOS | `%linuxuser`, `%linuxpassword` |

Beispiel – lokaler UniFi-Admin liegt in den Linux-Zugangsdaten des Geräts:

```
-ConsoleHost "%host" -Username "%linuxuser" -Password "%linuxpassword" -IgnoreSslErrors
```

Beispiel – der API-Key liegt im Passwortfeld der Linux-Zugangsdaten:

```
-ConsoleHost "%host" -ApiKey "%linuxpassword" -IgnoreSslErrors -IncludeDetails
```

Der Vorteil: Die Zugangsdaten werden einmal an der Gruppe gepflegt und von allen
Sensoren darunter geerbt. Ein Key-Wechsel ist dann eine Änderung statt hundert.

## Parameterreferenz

| Parameter | Typ | Standard | Bedeutung |
| --- | --- | --- | --- |
| `-ConsoleHost` | string | – | IP oder FQDN der Konsole. In PRTG `"%host"` verwenden. |
| `-Port` | int | `0` (Autoprobe) | Erzwingt einen Port statt 443/11443/8443 zu probieren. |
| `-BaseUrl` | string | – | Vollständige Basis-URL, überspringt jede Erkennung. Beispiel: `https://unifi.kunde.local:11443/proxy/network/integration` |
| `-ApiKey` | string | – | API-Key der Network Application oder Site-Manager-Key bei `-AuthMode Cloud`. |
| `-Username` | string | – | Lokaler Admin für den klassischen Pfad. |
| `-Password` | string | – | Passwort dazu. |
| `-AuthMode` | `Auto`/`ApiKey`/`Classic`/`Cloud` | `Auto` | `Auto`: erst API-Key, sonst Benutzer/Passwort. `Cloud`: Site-Manager-Connector. |
| `-ConsoleId` | string | – | Console ID, Pflicht bei `-AuthMode Cloud`. |
| `-SiteName` | string | erste Site | Integration API: der Anzeigename. Klassische API: Kurzname (`default`) **oder** Beschreibung. |
| `-SiteId` | string | – | Site-UUID (nur Integration API), spart den Site-Lookup-Aufruf. |
| `-IgnoreSslErrors` | switch | aus | Akzeptiert selbst signierte Zertifikate. Lokal fast immer nötig. |
| `-NoStatistics` | switch | aus | Blendet CPU/RAM/Uptime/Uplink-Kanäle aus. Spart im Integration-API-Pfad einen Aufruf pro Online-Gerät. |
| `-IncludeDetails` | switch | aus | Ergänzt Firmware-, Port- und PoE-Kanäle. Integration API: ein Aufruf mehr pro Gerät. Klassische API: kostenlos. |
| `-TimeoutSec` | int | `30` | HTTP-Timeout für reguläre Abfragen. |
| `-ProbeTimeoutSec` | int | `8` | HTTP-Timeout für die Port-Erkennung. |
| `-NoCache` | switch | aus | Base-URL-Cache in `%TEMP%` weder lesen noch schreiben. |

## Kanäle

**Immer vorhanden**

| Kanal | Einheit | Voreingestelltes Limit |
| --- | --- | --- |
| Devices Total | Count | – |
| Devices Online | Count | – |
| Devices Offline | Count | Fehler bei > 0 |
| Devices Transitional | Count | Warnung bei > 0 |
| Switches Total / Online | Count | – |
| Switches Offline | Count | Fehler bei > 0 |
| Access Points Total / Online | Count | – |
| Access Points Offline | Count | Fehler bei > 0 |
| Gateways Total / Online | Count | – |
| API Errors | Count | Warnung bei > 0 |
| Execution Time | ms | – |

**Ohne `-NoStatistics`**

| Kanal | Einheit | Voreingestelltes Limit |
| --- | --- | --- |
| CPU Load Max | % | Warnung 75, Fehler 90 |
| CPU Load Avg | % | – |
| Memory Used Max | % | Warnung 85, Fehler 95 |
| Memory Used Avg | % | – |
| Lowest Uptime | s | Warnung unter 3600 |
| Rebooted last 24h | Count | – |
| Uplink Rx Total / Tx Total | B/s | – |

**Mit `-IncludeDetails`**

| Kanal | Einheit | Voreingestelltes Limit |
| --- | --- | --- |
| Firmware Updates Available | Count | Warnung bei > 0 |
| Unsupported Devices | Count | – |
| Switch Ports Total / Up | Count | – |
| PoE Ports Enabled / Delivering | Count | – |

Hinweise zur Zählweise:

- „Offline" bei Switches und APs meint **nicht online**, also inklusive
  Adoption, Provisioning und ausbleibendem Heartbeat.
- Ein Gateway mit eingebauten Switch-Ports (UDM, UXG) zählt als Gateway,
  nicht zusätzlich als Switch.
- `API Errors` zählt fehlgeschlagene Detail-/Statistikaufrufe einzelner Geräte.
  Der Sensor bleibt dabei grün-fähig und liefert die restlichen Werte weiter.

## Beispiele nach Plattform

```powershell
# Cloud Key Gen2+ / UDM / jede UniFi OS Console (443)
-ConsoleHost "%host" -ApiKey "<key>" -IgnoreSslErrors -IncludeDetails

# UniFi OS Server auf einer VM (Port 11443 wird automatisch gefunden)
-ConsoleHost "%host" -ApiKey "<key>" -SiteName "Default" -IgnoreSslErrors

# Legacy self-hosted Network Application auf 8443 – kein API-Key möglich
-ConsoleHost "%host" -Username "prtg-ro" -Password "<pw>" -IgnoreSslErrors -IncludeDetails

# Site Manager Cloud – Konsole hinter CGNAT/DS-Lite, kein eingehender Zugriff
-AuthMode Cloud -ConsoleId "<consoleId>" -ApiKey "<site-manager-key>"

# Große Site, schlanker Sensor: keine Statistik- und Detailaufrufe
-ConsoleHost "%host" -ApiKey "<key>" -IgnoreSslErrors -NoStatistics

# Erkennung komplett überspringen (schnellster und deterministischster Aufruf)
-BaseUrl "https://unifi.kunde.local:11443/proxy/network/integration" -ApiKey "<key>" -SiteId "<uuid>" -IgnoreSslErrors
```

Mehrere Sites auf einer Konsole: pro Site einen Sensor anlegen und über
`-SiteName` bzw. `-SiteId` unterscheiden.

## Wie das Skript den Zugang findet

Mit `-ApiKey` und ohne `-BaseUrl` wird `GET /v1/info` gegen folgende Kandidaten
probiert, bis einer antwortet:

```
https://<host>/proxy/network/integration          # UniFi OS Console
https://<host>:11443/proxy/network/integration    # UniFi OS Server
https://<host>:11443/integration
https://<host>:8443/proxy/network/integration
https://<host>:8443/integration
```

Die erfolgreiche URL wird in `%TEMP%\prtg_unifi_base_<host>_<port>.txt` gemerkt und
beim nächsten Lauf zuerst probiert – dadurch kommt ein normaler Scan mit einem
einzigen Erkennungsaufruf aus. `-NoCache` schaltet das ab, `-BaseUrl` oder
`-Port` grenzen die Kandidatenliste ein bzw. überspringen sie.

Findet sich kein Integration-Endpunkt und sind `-Username`/`-Password` gesetzt,
wechselt `Auto` auf den klassischen Pfad: Login gegen `8443/api/login`,
`443/api/auth/login` und `11443/api/auth/login`, danach ein einziger Aufruf
`/api/s/<site>/stat/device` für alle Daten.

## Fehlerbehebung

Der Sensor gibt Fehler als PRTG-Fehlertext aus, nicht als Absturz. Die Meldung
steht im Sensor unter **Last Message**.

| Meldung | Ursache und Lösung |
| --- | --- |
| `No Integration API endpoint answered on <host> (tried 443, 11443, 8443)` | Falscher Host, Firewall, oder es ist die alte self-hosted Anwendung ohne API-Key-Unterstützung. Dann `-Username`/`-Password` verwenden, oder `-Port`/`-BaseUrl` explizit setzen. |
| `A UniFi endpoint answered but rejected the API key (HTTP 401/403)` | Key falsch, abgelaufen oder auf einer anderen Konsole erzeugt. Neuen Key unter **Settings → Control Plane → Integrations** anlegen. |
| `Login rejected by <url> (HTTP 401)` | Falsche Zugangsdaten, MFA aktiv oder das Konto ist kein „Local Access"-Admin. |
| `Could not log in to any classic API endpoint` | Kein erreichbarer Port. Host, Port und Firewall prüfen, ggf. `-Port` setzen. |
| `Site '<name>' not found. Available: …` | Site-Namen aus der Liste in der Meldung übernehmen. Integration API erwartet den Anzeigenamen, die klassische API Kurznamen oder Beschreibung. |
| `HTTP 403 Forbidden` | Key oder Konto hat keine Berechtigung für diese Site. |
| `HTTP 404 Not Found` | Unerwartetes API-Layout. `-BaseUrl` oder `-AuthMode Classic` verwenden. |
| Zertifikatsfehler / „Could not establish trust relationship" | `-IgnoreSslErrors` setzen. |
| Sensor meldet, das Skript sei nicht signiert | `Set-ExecutionPolicy RemoteSigned` in **beiden** PowerShell-Hosts, siehe Schritt 2. |
| Kanal `API Errors` > 0 | Einzelne Detail-/Statistikaufrufe scheitern (Timeout, Gerät gerade neu gestartet). `-TimeoutSec` erhöhen oder `-NoStatistics` setzen. |
| Sensor läuft in den Timeout | Scanintervall erhöhen, `-NoStatistics` setzen oder `-BaseUrl`/`-SiteId` angeben, um Suchaufrufe zu sparen. |

Zum Nachstellen einfach denselben Aufruf direkt auf der Probe ausführen –
die Ausgabe ist dasselbe XML, das PRTG sieht:

```powershell
cd 'C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML'
.\Get-UniFiNetworkDevices.ps1 -ConsoleHost unifi.kunde.local -ApiKey '<key>' -IgnoreSslErrors -IncludeDetails
```

## Bekannte Einschränkungen

- **Uplink-Kanäle:** Das Integration-API-Feld heißt `rxRateBps`, die Einheit ist
  aber nicht eindeutig dokumentiert; die klassische API liefert Byte/s. Die
  Kanäle sind auf `B/s` gesetzt. Vor dem Setzen von Limits gegen eine bekannte
  Last gegenprüfen.
- **`-AuthMode Auto` mit ungültigem API-Key:** Antwortet ein Endpunkt mit
  401/403, bricht das Skript mit einem Key-Fehler ab und probiert
  `-Username`/`-Password` nicht mehr – die Meldung über den abgelehnten Key ist in
  der Praxis hilfreicher als ein stiller Fallback. Wer trotzdem den klassischen
  Pfad braucht, setzt `-AuthMode Classic`.
- **`-NoStatistics` im klassischen Pfad** blendet die Kanäle aus, spart aber keine
  Aufrufe – dort kommen alle Daten ohnehin aus einer einzigen Antwort.
- **Keine API-Keys auf der Legacy-Anwendung (8443).** Dort führt nur der
  klassische Pfad zum Ziel.
- Pro Sensor wird **eine** Site abgefragt. Mehrere Sites = mehrere Sensoren.

## Lokal testen

Ohne PRTG lässt sich das Skript direkt aufrufen; es schreibt das PRTG-XML nach
stdout und beendet sich immer mit Exit-Code 0 – auch im Fehlerfall, so wie PRTG
es für EXEXML-Sensoren erwartet.

```powershell
# Syntaxprüfung
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Get-UniFiNetworkDevices.ps1), [ref]$null, [ref]$err)
$err

# Testlauf
.\Get-UniFiNetworkDevices.ps1 -ConsoleHost 10.0.0.1 -ApiKey '<key>' -IgnoreSslErrors -NoCache
```

## Lizenz

MIT – siehe [LICENSE](LICENSE).
