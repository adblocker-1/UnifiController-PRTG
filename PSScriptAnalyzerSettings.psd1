@{
    # Regeln, die für einen PRTG-EXEXML-Sensor bewusst nicht gelten.
    # Alles andere bleibt aktiv - insbesondere echte Korrektheitsregeln.
    ExcludeRules = @(

        # Leere catch-Blöcke sind hier Absicht: Cache-Datei lesen/schreiben,
        # TLS-Setup und Zahlen-Parsing sind Best-Effort. Ein Fehler darf den
        # Sensor nicht abbrechen, er würde nur Kanäle kosten.
        'PSAvoidUsingEmptyCatchBlock',

        # PRTG übergibt Sensorparameter als Klartext an das Skript.
        # Ein SecureString wäre an dieser Schnittstelle nicht verwendbar.
        'PSAvoidUsingPlainTextForPassword',

        # Falsch-positiv: -Port, -SiteId, -TimeoutSec, -ProbeTimeoutSec und
        # -NoCache werden innerhalb der Funktionen über den Skript-Scope
        # gelesen, was der Analyzer nicht verfolgt.
        'PSReviewUnusedParameter',

        # Get-ClassicCandidates liefert bewusst eine Liste.
        'PSUseSingularNouns'
    )
}
