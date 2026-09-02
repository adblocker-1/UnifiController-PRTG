# Changelog

## 2.1

- `-AuthMode Auto` fällt jetzt auch dann auf `-Username`/`-Password` zurück, wenn
  der API-Key mit HTTP 401/403 abgelehnt wurde. Bisher brach der Sensor in dem
  Fall ab, obwohl eine funktionierende Rückfallebene konfiguriert war. Die
  Sensormeldung weist den abgelehnten Key mit
  `API key rejected - using the classic API` aus, damit das nicht unbemerkt
  bleibt. `-AuthMode ApiKey` bricht weiterhin bewusst ab.
- Jedes Gerät zählt in genau einer Kategorie. Ein UDM/UXG meldet neben `gateway`
  auch `switching` und teils `accessPoint` und wurde dadurch im
  Integration-API-Pfad zusätzlich als Access Point gezählt – die Zahlen wichen
  vom klassischen Pfad ab. Beide Pfade liefern jetzt dieselben Werte.
- Die Endpunkt-Erkennung akzeptiert nur noch JSON-Objekte als Integration API.
  Die Legacy-Anwendung liefert auf unbekannte Pfade ihre Weboberfläche mit
  HTTP 200 aus und wurde dadurch als gültiger Endpunkt akzeptiert, was später zu
  der irreführenden Meldung „The Integration API returned no sites" führte.
- Scheitern beide Wege, nennt die Fehlermeldung jetzt beide statt nur den letzten.
- Cache-Verzeichnis fällt auf `[System.IO.Path]::GetTempPath()` zurück, wenn
  weder `%TEMP%` noch `%TMP%` gesetzt sind, statt ins Arbeitsverzeichnis zu schreiben.
- Null-Vergleiche im klassischen Pfad in der kanonischen Reihenfolge
  (`$null -ne $x`).

## 2.0

- Automatische Erkennung der Integration-API-Basis-URL über 443, 11443 und 8443,
  mit und ohne `/proxy/network`-Präfix; die gefundene URL wird in `%TEMP%` gecacht.
- Klassischer API-Pfad (lokaler Admin) als Fallback für die selbst gehostete
  Legacy Network Application, die keine API-Keys unterstützt.
- Site-Manager-Connector über `api.ui.com` (`-AuthMode Cloud`) für Konsolen
  hinter CGNAT/DS-Lite.
- Beide Pfade liefern denselben Kanalsatz, Sensoren sind dadurch plattformübergreifend
  klonbar.
- Optionale Kanäle: `-NoStatistics` blendet CPU/RAM/Uptime/Uplink aus,
  `-IncludeDetails` ergänzt Firmware-, Port- und PoE-Kanäle.
- Sprechende PRTG-Fehlertexte statt Skriptabbrüchen, plus `API Errors`-Kanal für
  einzelne fehlgeschlagene Geräteaufrufe.
