# Changelog

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
