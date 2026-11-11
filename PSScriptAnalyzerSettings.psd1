# Règles d'analyse statique du projet (Invoke-ScriptAnalyzer -Settings .\PSScriptAnalyzerSettings.psd1)
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Les scripts de démonstration affichent volontairement des messages colorés en console
        'PSAvoidUsingWriteHost'
    )
}
