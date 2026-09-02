<#
.SYNOPSIS
    PRTG "EXE/Script Advanced" (EXEXML) sensor for UniFi switches, access points
    and gateways. Works with every current UniFi platform.

.DESCRIPTION
    Supported platforms and how they are reached:

      Platform                              Port    Auth                Path
      ------------------------------------  ------  ------------------  ---------------------------
      UniFi OS console (Cloud Key Gen2/2+,
      Cloud Key Enterprise, UDM, UXG, ...)  443     API key (or login)  /proxy/network/integration
      UniFi OS Server (Linux/Windows VM)    11443   API key (or login)  /proxy/network/integration
      Legacy self-hosted Network App (.deb) 8443    local admin login   classic /api (no API key!)
      Site Manager cloud connector          443     Site Manager key    api.ui.com  (no VPN needed)

    The script has two data paths and picks one automatically:

      1. Integration API (X-API-KEY)  - preferred. The base URL is auto-discovered by
         probing GET /v1/info against 443, 11443 and 8443, with and without the
         /proxy/network prefix. The winning URL is cached so later scans do one call.
      2. Classic API (local admin username/password) - fallback for the legacy
         self-hosted Network Application, which does not support API keys.
         This path needs only a single request for all data.

    Both paths are normalised into the same set of PRTG channels, so you can mix
    platforms across customers and still compare/clone sensors.

.PARAMETER ConsoleHost
    IP or FQDN of the console / server. Use %host in the PRTG parameter field.

.PARAMETER Port
    Force a port instead of probing 443 / 11443 / 8443.

.PARAMETER BaseUrl
    Full override, e.g. "https://unifi.kunde.local:11443/proxy/network/integration".
    Skips all auto-discovery.

.PARAMETER ApiKey
    Network Application API key (Settings > Control Plane > Integrations) for local
    access, or a Site Manager key from unifi.ui.com when -AuthMode Cloud is used.
    NOTE: not available on the legacy self-hosted application.

.PARAMETER Username / .PARAMETER Password
    Local-only admin account (Remote/Cloud access disabled, "View Only" role is enough).
    Used for the classic API path.

.PARAMETER AuthMode
    Auto    (default) API key first, fall back to username/password if both are supplied
    ApiKey  force the Integration API
    Classic force the classic API
    Cloud   Site Manager connector, requires -ConsoleId and a Site Manager -ApiKey

.PARAMETER ConsoleId
    Console ID for -AuthMode Cloud.

.PARAMETER SiteName
    Site to monitor. Integration API: the display name. Classic API: matches either the
    short name ("default") or the description. Omit to use the first site.

.PARAMETER SiteId
    Site UUID (Integration API only). Saves the site lookup call.

.PARAMETER IgnoreSslErrors
    Accept self-signed / hostname-mismatch certificates. Usually needed locally.

.PARAMETER NoStatistics
    Integration API only: skip the per-device statistics calls (uptime, CPU, RAM,
    uplink rates). Removes those channels and one API call per online device.

.PARAMETER IncludeDetails
    Adds firmware-update, unsupported-device and switch-port/PoE channels.
    Integration API: costs one extra call per device. Classic API: free.

.PARAMETER TimeoutSec / .PARAMETER ProbeTimeoutSec
    HTTP timeout for normal requests (default 30) and for discovery probes (default 8).

.PARAMETER NoCache
    Do not read/write the discovered base URL cache in %TEMP%.

.EXAMPLE
    # Cloud Key Gen2+ or any UniFi OS console
    -ConsoleHost "%host" -ApiKey "<key>" -IgnoreSslErrors -IncludeDetails

.EXAMPLE
    # UniFi OS Server on a Linux VM (port 11443 is found automatically)
    -ConsoleHost "%host" -ApiKey "<key>" -SiteName "Default" -IgnoreSslErrors

.EXAMPLE
    # Legacy self-hosted Network Application on 8443 - no API key support
    -ConsoleHost "%host" -Username "prtg-ro" -Password "<pw>" -IgnoreSslErrors -IncludeDetails

.EXAMPLE
    # Mixed estate: try the key, fall back to the local admin automatically
    -ConsoleHost "%host" -ApiKey "<key>" -Username "prtg-ro" -Password "<pw>" -IgnoreSslErrors

.EXAMPLE
    # Site Manager connector - console behind CGNAT / DS-Lite, no inbound access
    -AuthMode Cloud -ConsoleId "<consoleId>" -ApiKey "<site-manager-key>"

.NOTES
    Install to:
      C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\Get-UniFiNetworkDevices.ps1

    PRTG starts the 32-bit PowerShell, so allow script execution in both hosts:
      C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -> Set-ExecutionPolicy RemoteSigned
      C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -> Set-ExecutionPolicy RemoteSigned

    Caveat on the two uplink channels: the Integration API field is called "rxRateBps"
    but the unit is not documented unambiguously, and the classic API returns bytes/s.
    Verify against a known load before you set limits on those channels.

    Version 2.0
#>

[CmdletBinding()]
param(
    [string]$ConsoleHost,
    [int]$Port = 0,
    [string]$BaseUrl,

    [string]$ApiKey,
    [string]$Username,
    [string]$Password,

    [ValidateSet('Auto', 'ApiKey', 'Classic', 'Cloud')]
    [string]$AuthMode = 'Auto',

    [string]$ConsoleId,

    [string]$SiteName,
    [string]$SiteId,

    [switch]$IgnoreSslErrors,
    [switch]$NoStatistics,
    [switch]$IncludeDetails,

    [int]$TimeoutSec = 30,
    [int]$ProbeTimeoutSec = 8,
    [switch]$NoCache
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$swatch = [System.Diagnostics.Stopwatch]::StartNew()
$inv    = [System.Globalization.CultureInfo]::InvariantCulture

# ===========================================================================
# Output helpers
# ===========================================================================

function ConvertTo-XmlText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    return ($t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}

function Format-Number {
    param($Value, [switch]$AsFloat)
    if ($null -eq $Value) { return '0' }
    if ($AsFloat) { return [string]::Format($inv, '{0:0.##}', [double]$Value) }
    return [string]::Format($inv, '{0:0}', [double]$Value)
}

function Write-PrtgError {
    param([string]$Message)
    $out = '<?xml version="1.0" encoding="UTF-8" ?>' + "`n<prtg>`n" +
           "  <error>1</error>`n" +
           '  <text>' + (ConvertTo-XmlText $Message) + "</text>`n" +
           '</prtg>'
    [Console]::Out.Write($out)
    exit 0
}

$script:Channels = New-Object System.Collections.Generic.List[string]

function Add-PrtgChannel {
    param(
        [Parameter(Mandatory = $true)][string]$Channel,
        [Parameter(Mandatory = $true)]$Value,
        [string]$Unit = 'Count',
        [string]$CustomUnit,
        [switch]$AsFloat,
        [object]$LimitMaxWarning,
        [object]$LimitMaxError,
        [object]$LimitMinWarning,
        [object]$LimitMinError,
        [string]$LimitWarningMsg,
        [string]$LimitErrorMsg,
        [switch]$HideChart
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('  <result>')
    [void]$sb.AppendLine('    <channel>' + (ConvertTo-XmlText $Channel) + '</channel>')
    [void]$sb.AppendLine('    <value>' + (Format-Number -Value $Value -AsFloat:$AsFloat) + '</value>')
    [void]$sb.AppendLine('    <unit>' + $Unit + '</unit>')
    if ($CustomUnit) { [void]$sb.AppendLine('    <customunit>' + (ConvertTo-XmlText $CustomUnit) + '</customunit>') }
    [void]$sb.AppendLine('    <float>' + $(if ($AsFloat) { '1' } else { '0' }) + '</float>')
    if ($AsFloat)   { [void]$sb.AppendLine('    <decimalmode>2</decimalmode>') }
    if ($HideChart) { [void]$sb.AppendLine('    <showchart>0</showchart>') }

    $hasLimit = ($null -ne $LimitMaxWarning) -or ($null -ne $LimitMaxError) -or
                ($null -ne $LimitMinWarning) -or ($null -ne $LimitMinError)
    if ($hasLimit) {
        [void]$sb.AppendLine('    <limitmode>1</limitmode>')
        if ($null -ne $LimitMaxWarning) { [void]$sb.AppendLine('    <limitmaxwarning>' + (Format-Number $LimitMaxWarning -AsFloat) + '</limitmaxwarning>') }
        if ($null -ne $LimitMaxError)   { [void]$sb.AppendLine('    <limitmaxerror>'   + (Format-Number $LimitMaxError   -AsFloat) + '</limitmaxerror>') }
        if ($null -ne $LimitMinWarning) { [void]$sb.AppendLine('    <limitminwarning>' + (Format-Number $LimitMinWarning -AsFloat) + '</limitminwarning>') }
        if ($null -ne $LimitMinError)   { [void]$sb.AppendLine('    <limitminerror>'   + (Format-Number $LimitMinError   -AsFloat) + '</limitminerror>') }
        if ($LimitWarningMsg) { [void]$sb.AppendLine('    <limitwarningmsg>' + (ConvertTo-XmlText $LimitWarningMsg) + '</limitwarningmsg>') }
        if ($LimitErrorMsg)   { [void]$sb.AppendLine('    <limiterrormsg>'   + (ConvertTo-XmlText $LimitErrorMsg)   + '</limiterrormsg>') }
    }
    [void]$sb.Append('  </result>')
    $script:Channels.Add($sb.ToString())
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-HttpStatus {
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -eq $resp) { return 0 }
        return [int]$resp.StatusCode
    } catch { return 0 }
}

# ===========================================================================
# Transport
# ===========================================================================

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
} catch { }

$script:SkipCertParam = $false
if ($IgnoreSslErrors) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $script:SkipCertParam = $true
    } else {
        if (-not ('PrtgUniFiCertPolicy' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class PrtgUniFiCertPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object PrtgUniFiCertPolicy
    }
}

function Invoke-Rest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers,
        $Body,
        [int]$Timeout = 0,
        $Session,
        [string]$SessionVariableName
    )

    if ($Timeout -le 0) { $Timeout = $TimeoutSec }

    $params = @{
        Uri             = $Uri
        Method          = $Method
        TimeoutSec      = $Timeout
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($Headers)             { $params['Headers']        = $Headers }
    if ($null -ne $Body)      { $params['Body']           = $Body; $params['ContentType'] = 'application/json' }
    if ($Session)             { $params['WebSession']     = $Session }
    if ($SessionVariableName) { $params['SessionVariable'] = $SessionVariableName }
    if ($script:SkipCertParam) { $params['SkipCertificateCheck'] = $true }

    $result = Invoke-RestMethod @params

    # -SessionVariable creates the variable in THIS function's scope, so hand it
    # back to the caller explicitly.
    if ($SessionVariableName) {
        $script:LastSession = (Get-Variable -Name $SessionVariableName -ValueOnly -ErrorAction SilentlyContinue)
    }

    return $result
}

# ===========================================================================
# Base URL discovery (Integration API)
# ===========================================================================

function Get-NormalizedHost {
    if (-not $ConsoleHost) { return $null }
    return ($ConsoleHost -replace '^https?://', '' -replace '/+$', '')
}

function Get-CandidateBaseUris {
    $h = Get-NormalizedHost
    if (-not $h) { return @() }

    if ($Port -gt 0) {
        return @(
            "https://${h}:$Port/proxy/network/integration",
            "https://${h}:$Port/integration"
        )
    }

    return @(
        "https://$h/proxy/network/integration",          # UniFi OS console (Cloud Key Gen2+, UDM, ...)
        "https://${h}:11443/proxy/network/integration",  # UniFi OS Server
        "https://${h}:11443/integration",
        "https://${h}:8443/proxy/network/integration",   # self-hosted, unlikely but cheap to try
        "https://${h}:8443/integration"
    )
}

function Get-CacheFilePath {
    $h = Get-NormalizedHost
    $safe = ($h -replace '[^A-Za-z0-9\.\-]', '_')
    $dir = $env:TEMP
    if (-not $dir) { $dir = $env:TMP }
    if (-not $dir) { $dir = '.' }
    return (Join-Path $dir ("prtg_unifi_base_{0}_{1}.txt" -f $safe, $Port))
}

function Test-IntegrationBaseUri {
    param([string]$Uri)
    try {
        $null = Invoke-Rest -Uri ($Uri + '/v1/info') -Timeout $ProbeTimeoutSec `
                            -Headers @{ 'X-API-KEY' = $ApiKey; 'Accept' = 'application/json' }
        return 'OK'
    }
    catch {
        $code = Get-HttpStatus $_
        if ($code -eq 401 -or $code -eq 403) { return 'AUTH' }
        return 'NO'
    }
}

function Find-IntegrationBaseUri {
    if ($BaseUrl) {
        $u = $BaseUrl.TrimEnd('/')
        $r = Test-IntegrationBaseUri -Uri $u
        if ($r -eq 'OK')   { return $u }
        if ($r -eq 'AUTH') { Write-PrtgError "The API key was rejected by $u (HTTP 401/403). Check the key and that it was created on this console." }
        return $null
    }

    $candidates = @(Get-CandidateBaseUris)
    if ($candidates.Count -eq 0) { return $null }

    $cacheFile = Get-CacheFilePath
    if (-not $NoCache -and (Test-Path $cacheFile)) {
        try {
            $cached = (Get-Content -Path $cacheFile -TotalCount 1 -ErrorAction Stop).Trim()
            if ($cached) { $candidates = @($cached) + @($candidates | Where-Object { $_ -ne $cached }) }
        } catch { }
    }

    $sawAuth = $false
    foreach ($c in $candidates) {
        $r = Test-IntegrationBaseUri -Uri $c
        if ($r -eq 'OK') {
            if (-not $NoCache) {
                try { Set-Content -Path $cacheFile -Value $c -Encoding ASCII -ErrorAction SilentlyContinue } catch { }
            }
            return $c
        }
        if ($r -eq 'AUTH') { $sawAuth = $true }
    }

    if ($sawAuth) {
        Write-PrtgError ("A UniFi endpoint answered but rejected the API key (HTTP 401/403) on {0}. " -f (Get-NormalizedHost) +
                         "Verify the key was generated in this Network application under Settings > Control Plane > Integrations.")
    }
    return $null
}

# ===========================================================================
# Integration API
# ===========================================================================

function Invoke-UniFiApi {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Invoke-Rest -Uri ($script:BaseUri + $Path) `
                       -Headers @{ 'X-API-KEY' = $ApiKey; 'Accept' = 'application/json' }
}

function Get-UniFiPaged {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$PageSize = 200)

    $all    = New-Object System.Collections.Generic.List[object]
    $offset = 0
    $total  = 0
    do {
        $sep  = if ($Path -match '\?') { '&' } else { '?' }
        $page = Invoke-UniFiApi -Path ("{0}{1}offset={2}&limit={3}" -f $Path, $sep, $offset, $PageSize)

        $batch = @(Get-Prop $page 'data' @())
        foreach ($item in $batch) { [void]$all.Add($item) }

        $tc = Get-Prop $page 'totalCount' 0
        $total = [int]$tc
        $offset += $PageSize
    } while (($all.Count -lt $total) -and ($batch.Count -gt 0) -and ($offset -lt 10000))

    return $all
}

function Get-DevicesViaIntegration {
    if (-not $SiteId) {
        $sites = Get-UniFiPaged -Path '/v1/sites'
        if (-not $sites -or $sites.Count -eq 0) { Write-PrtgError 'The Integration API returned no sites. Check the API key permissions.' }

        if ($SiteName) {
            $site = $sites | Where-Object { $_.name -eq $SiteName } | Select-Object -First 1
            if (-not $site) {
                $available = (($sites | ForEach-Object { $_.name }) -join ', ')
                Write-PrtgError ("Site '{0}' not found. Available: {1}" -f $SiteName, $available)
            }
        } else {
            $site = $sites | Select-Object -First 1
        }
        $script:ResolvedSiteId   = $site.id
        $script:ResolvedSiteName = $site.name
    } else {
        $script:ResolvedSiteId   = $SiteId
        $script:ResolvedSiteName = $SiteName
    }

    $raw = Get-UniFiPaged -Path ("/v1/sites/{0}/devices" -f $script:ResolvedSiteId)
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($d in $raw) {
        $features = @(Get-Prop $d 'features' @())
        $state    = [string](Get-Prop $d 'state' 'UNKNOWN')

        $norm = [pscustomobject]@{
            Name              = [string](Get-Prop $d 'name' '(unnamed)')
            Model             = [string](Get-Prop $d 'model' '')
            State             = if ($state -eq 'ONLINE') { 'ONLINE' } elseif ($state -eq 'OFFLINE') { 'OFFLINE' } else { 'OTHER' }
            IsAp              = ($features -contains 'accessPoint')
            IsSw              = ($features -contains 'switching')
            IsGw              = ($features -contains 'gateway')
            UptimeSec         = $null
            CpuPct            = $null
            MemPct            = $null
            RxRate            = 0
            TxRate            = 0
            FirmwareUpdatable = $false
            Unsupported       = $false
            Ports             = @()
        }

        if (-not $NoStatistics -and $norm.State -eq 'ONLINE') {
            try {
                $s = Invoke-UniFiApi -Path ("/v1/sites/{0}/devices/{1}/statistics/latest" -f $script:ResolvedSiteId, $d.id)
                $norm.UptimeSec = Get-Prop $s 'uptimeSec'
                $norm.CpuPct    = Get-Prop $s 'cpuUtilizationPct'
                $norm.MemPct    = Get-Prop $s 'memoryUtilizationPct'
                $up = Get-Prop $s 'uplink'
                if ($up) {
                    $norm.RxRate = [double](Get-Prop $up 'rxRateBps' 0)
                    $norm.TxRate = [double](Get-Prop $up 'txRateBps' 0)
                }
            } catch { $script:ApiErrors++ }
        }

        if ($IncludeDetails) {
            try {
                $det = Invoke-UniFiApi -Path ("/v1/sites/{0}/devices/{1}" -f $script:ResolvedSiteId, $d.id)
                $norm.FirmwareUpdatable = ((Get-Prop $det 'firmwareUpdatable' $false) -eq $true)
                $norm.Unsupported       = ((Get-Prop $det 'supported' $true) -eq $false)

                $ifaces = Get-Prop $det 'interfaces'
                $ports  = @(Get-Prop $ifaces 'ports' @())
                $plist  = New-Object System.Collections.Generic.List[object]
                foreach ($p in $ports) {
                    $poe = Get-Prop $p 'poe'
                    [void]$plist.Add([pscustomobject]@{
                        Up         = ([string](Get-Prop $p 'state' '') -eq 'UP')
                        PoeEnabled = ((Get-Prop $poe 'enabled' $false) -eq $true)
                        PoeUp      = ([string](Get-Prop $poe 'state' '') -eq 'UP')
                    })
                }
                $norm.Ports = $plist.ToArray()
            } catch { $script:ApiErrors++ }
        }

        [void]$result.Add($norm)
    }
    return $result
}

# ===========================================================================
# Classic API (legacy self-hosted, and any console with a local admin)
# ===========================================================================

function Get-ClassicCandidates {
    $h = Get-NormalizedHost
    if (-not $h) { return @() }

    if ($Port -gt 0) {
        return @(
            [pscustomobject]@{ Root = "https://${h}:$Port"; Login = '/api/auth/login'; Prefix = '/proxy/network' },
            [pscustomobject]@{ Root = "https://${h}:$Port"; Login = '/api/login';      Prefix = '' }
        )
    }

    return @(
        [pscustomobject]@{ Root = "https://${h}:8443";  Login = '/api/login';      Prefix = '' },             # legacy self-hosted
        [pscustomobject]@{ Root = "https://$h";         Login = '/api/auth/login'; Prefix = '/proxy/network' },# UniFi OS console
        [pscustomobject]@{ Root = "https://${h}:11443"; Login = '/api/auth/login'; Prefix = '/proxy/network' } # UniFi OS Server
    )
}

function Connect-ClassicApi {
    if (-not $Username -or -not $Password) { return $false }

    $body = (@{ username = $Username; password = $Password; remember = $true } | ConvertTo-Json -Compress)

    foreach ($c in (Get-ClassicCandidates)) {
        try {
            $script:LastSession = $null
            $null = Invoke-Rest -Uri ($c.Root + $c.Login) -Method 'POST' -Body $body `
                                -Timeout $ProbeTimeoutSec -SessionVariableName 'unifiSess'
            if (-not $script:LastSession) { continue }

            $script:ClassicSession = $script:LastSession
            $script:ClassicRoot    = $c.Root
            $script:ClassicPrefix  = $c.Prefix
            return $true
        }
        catch {
            $code = Get-HttpStatus $_
            if ($code -eq 400 -or $code -eq 401) {
                Write-PrtgError ("Login rejected by {0} (HTTP {1}). Check the credentials and make sure the account is a local-only admin without MFA." -f $c.Root, $code)
            }
            # anything else: wrong port / not this platform, try the next candidate
        }
    }
    return $false
}

function Invoke-ClassicApi {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Invoke-Rest -Uri ($script:ClassicRoot + $script:ClassicPrefix + $Path) -Session $script:ClassicSession
}

function ConvertFrom-ClassicState {
    param($State)
    $s = 0
    try { $s = [int]$State } catch { }
    if ($s -eq 1) { return 'ONLINE' }
    if ($s -eq 0) { return 'OFFLINE' }
    return 'OTHER'   # 2 pending adoption, 4 updating, 5 provisioning, 6 heartbeat missed, 11 isolated, ...
}

function Get-DevicesViaClassic {
    $siteShort = 'default'
    try {
        $siteResp = Invoke-ClassicApi -Path '/api/self/sites'
        $sites = @(Get-Prop $siteResp 'data' @())
        if ($sites.Count -gt 0) {
            if ($SiteName) {
                $site = $sites | Where-Object { $_.name -eq $SiteName -or $_.desc -eq $SiteName } | Select-Object -First 1
                if (-not $site) {
                    $available = (($sites | ForEach-Object { "$($_.desc) [$($_.name)]" }) -join ', ')
                    Write-PrtgError ("Site '{0}' not found. Available: {1}" -f $SiteName, $available)
                }
            } else {
                $site = $sites | Select-Object -First 1
            }
            $siteShort = [string]$site.name
            $script:ResolvedSiteName = [string](Get-Prop $site 'desc' $site.name)
        }
    } catch { $script:ApiErrors++ }

    $devResp = Invoke-ClassicApi -Path ("/api/s/{0}/stat/device" -f $siteShort)
    $raw     = @(Get-Prop $devResp 'data' @())

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($d in $raw) {
        $type = [string](Get-Prop $d 'type' '')
        $sys  = Get-Prop $d 'system-stats'
        $upl  = Get-Prop $d 'uplink'

        $cpu = $null; $mem = $null
        if ($sys) {
            $c = Get-Prop $sys 'cpu'; $m = Get-Prop $sys 'mem'
            if ($c -ne $null -and "$c" -ne '') { try { $cpu = [double]$c } catch { } }
            if ($m -ne $null -and "$m" -ne '') { try { $mem = [double]$m } catch { } }
        }

        $plist = New-Object System.Collections.Generic.List[object]
        foreach ($p in @(Get-Prop $d 'port_table' @())) {
            $poeEnabled = ((Get-Prop $p 'poe_enable' $false) -eq $true)
            $poeGood    = ((Get-Prop $p 'poe_good' $false) -eq $true)
            if (-not $poeGood) {
                $pw = Get-Prop $p 'poe_power'
                if ($pw) { try { if ([double]$pw -gt 0) { $poeGood = $true } } catch { } }
            }
            [void]$plist.Add([pscustomobject]@{
                Up         = ((Get-Prop $p 'up' $false) -eq $true)
                PoeEnabled = $poeEnabled
                PoeUp      = $poeGood
            })
        }

        [void]$result.Add([pscustomobject]@{
            Name              = [string](Get-Prop $d 'name' (Get-Prop $d 'mac' '(unnamed)'))
            Model             = [string](Get-Prop $d 'model' '')
            State             = (ConvertFrom-ClassicState (Get-Prop $d 'state' 0))
            IsAp              = ($type -eq 'uap')
            IsSw              = ($type -eq 'usw')
            IsGw              = ($type -in @('ugw', 'udm', 'uxg'))
            UptimeSec         = (Get-Prop $d 'uptime')
            CpuPct            = $cpu
            MemPct            = $mem
            RxRate            = [double](Get-Prop $upl 'rx_bytes-r' 0)
            TxRate            = [double](Get-Prop $upl 'tx_bytes-r' 0)
            FirmwareUpdatable = ((Get-Prop $d 'upgradable' $false) -eq $true)
            Unsupported       = ((Get-Prop $d 'unsupported' $false) -eq $true)
            Ports             = $plist.ToArray()
        })
    }
    return $result
}

# ===========================================================================
# Connect and collect
# ===========================================================================

$script:ApiErrors        = 0
$script:BaseUri          = $null
$script:ResolvedSiteName = $SiteName
$script:PlatformLabel    = 'unknown'
$devices                 = $null

if ($AuthMode -eq 'Cloud') {
    if (-not $ConsoleId) { Write-PrtgError 'Parameter -ConsoleId is required for -AuthMode Cloud.' }
    if (-not $ApiKey)    { Write-PrtgError 'Parameter -ApiKey (Site Manager key from unifi.ui.com) is required for -AuthMode Cloud.' }
    $script:BaseUri       = "https://api.ui.com/v1/connector/consoles/$ConsoleId/proxy/network/integration"
    $script:PlatformLabel = 'Site Manager'
}
elseif ($AuthMode -eq 'Classic') {
    if (-not $Username -or -not $Password) { Write-PrtgError 'Parameters -Username and -Password are required for -AuthMode Classic.' }
    if (-not (Connect-ClassicApi)) {
        Write-PrtgError ("Could not log in to any classic API endpoint on {0} (tried 8443, 443 and 11443). Check host, port and firewall." -f (Get-NormalizedHost))
    }
}
else {
    if (-not $ConsoleHost -and -not $BaseUrl) { Write-PrtgError 'Parameter -ConsoleHost (or -BaseUrl) is required.' }

    if ($ApiKey) { $script:BaseUri = Find-IntegrationBaseUri }

    if (-not $script:BaseUri) {
        if ($AuthMode -eq 'ApiKey') {
            Write-PrtgError ("No Integration API endpoint found on {0}. The legacy self-hosted Network Application does not support API keys - use -Username/-Password instead, or set -Port / -BaseUrl explicitly." -f (Get-NormalizedHost))
        }
        if (Connect-ClassicApi) {
            # ok, classic fallback
        } elseif ($Username -or $Password) {
            Write-PrtgError ("Neither the Integration API nor the classic API could be reached on {0}. Check host, ports (443/11443/8443), firewall and credentials." -f (Get-NormalizedHost))
        } else {
            Write-PrtgError ("No Integration API endpoint answered on {0} (tried 443, 11443, 8443). If this is the legacy self-hosted Network Application, it has no API key support - supply -Username and -Password instead." -f (Get-NormalizedHost))
        }
    }
}

try {
    if ($script:BaseUri) {
        if ($script:PlatformLabel -ne 'Site Manager') {
            if     ($script:BaseUri -match ':11443') { $script:PlatformLabel = 'UniFi OS Server (11443)' }
            elseif ($script:BaseUri -match ':8443')  { $script:PlatformLabel = 'self-hosted (8443)' }
            else                                     { $script:PlatformLabel = 'UniFi OS (443)' }
        }
        $devices = Get-DevicesViaIntegration
    } else {
        if     ($script:ClassicRoot -match ':8443')  { $script:PlatformLabel = 'legacy self-hosted (8443, classic API)' }
        elseif ($script:ClassicRoot -match ':11443') { $script:PlatformLabel = 'UniFi OS Server (11443, classic API)' }
        else                                         { $script:PlatformLabel = 'UniFi OS (443, classic API)' }
        $devices = Get-DevicesViaClassic
    }
}
catch {
    $msg  = $_.Exception.Message
    $code = Get-HttpStatus $_
    switch ($code) {
        401 { $msg = 'HTTP 401 Unauthorized - credentials or API key rejected.' }
        403 { $msg = 'HTTP 403 Forbidden - the account/key lacks permission for this site.' }
        404 { $msg = 'HTTP 404 Not Found - unexpected API layout for this platform. Try -BaseUrl or -AuthMode Classic.' }
        default { if ($code -gt 0) { $msg = "HTTP $code - $msg" } }
    }
    Write-PrtgError ("UniFi request failed ({0}): {1}" -f $script:PlatformLabel, $msg)
}

if ($null -eq $devices) { $devices = @() }

# ===========================================================================
# Aggregate
# ===========================================================================

$total = @($devices).Count
$online = 0; $offline = 0; $transit = 0
$swTotal = 0; $swOnline = 0
$apTotal = 0; $apOnline = 0
$gwTotal = 0; $gwOnline = 0

$offlineNames = New-Object System.Collections.Generic.List[string]

$cpuValues    = New-Object System.Collections.Generic.List[double]
$memValues    = New-Object System.Collections.Generic.List[double]
$uptimeValues = New-Object System.Collections.Generic.List[double]
$rxTotal = 0; $txTotal = 0; $recentReboots = 0

$fwUpdates = 0; $unsupported = 0
$portsTotal = 0; $portsUp = 0; $poeEnabled = 0; $poeDelivering = 0

foreach ($d in $devices) {
    $isOnline = ($d.State -eq 'ONLINE')
    if     ($isOnline)              { $online++ }
    elseif ($d.State -eq 'OFFLINE') { $offline++; [void]$offlineNames.Add($d.Name) }
    else                            { $transit++ }

    # A gateway with built-in switch ports (UDM/UXG) counts as a gateway, not a switch.
    if     ($d.IsGw) { $gwTotal++; if ($isOnline) { $gwOnline++ } }
    elseif ($d.IsSw) { $swTotal++; if ($isOnline) { $swOnline++ } }
    if     ($d.IsAp) { $apTotal++; if ($isOnline) { $apOnline++ } }

    if ($null -ne $d.CpuPct) { [void]$cpuValues.Add([double]$d.CpuPct) }
    if ($null -ne $d.MemPct) { [void]$memValues.Add([double]$d.MemPct) }
    if ($null -ne $d.UptimeSec -and $isOnline) {
        $u = [double]$d.UptimeSec
        [void]$uptimeValues.Add($u)
        if ($u -lt 86400) { $recentReboots++ }
    }
    $rxTotal += [double]$d.RxRate
    $txTotal += [double]$d.TxRate

    if ($d.FirmwareUpdatable) { $fwUpdates++ }
    if ($d.Unsupported)       { $unsupported++ }

    foreach ($p in @($d.Ports)) {
        $portsTotal++
        if ($p.Up)         { $portsUp++ }
        if ($p.PoeEnabled) { $poeEnabled++ }
        if ($p.PoeUp)      { $poeDelivering++ }
    }
}

# ===========================================================================
# Channels
# ===========================================================================

Add-PrtgChannel -Channel 'Devices Total'         -Value $total
Add-PrtgChannel -Channel 'Devices Online'        -Value $online
Add-PrtgChannel -Channel 'Devices Offline'       -Value $offline -LimitMaxError 0   -LimitErrorMsg 'At least one UniFi device is offline'
Add-PrtgChannel -Channel 'Devices Transitional'  -Value $transit -LimitMaxWarning 0 -LimitWarningMsg 'A device is adopting, updating, provisioning or missing heartbeats'

Add-PrtgChannel -Channel 'Switches Total'        -Value $swTotal
Add-PrtgChannel -Channel 'Switches Online'       -Value $swOnline
Add-PrtgChannel -Channel 'Switches Offline'      -Value ($swTotal - $swOnline) -LimitMaxError 0 -LimitErrorMsg 'At least one switch is not online'

Add-PrtgChannel -Channel 'Access Points Total'   -Value $apTotal
Add-PrtgChannel -Channel 'Access Points Online'  -Value $apOnline
Add-PrtgChannel -Channel 'Access Points Offline' -Value ($apTotal - $apOnline) -LimitMaxError 0 -LimitErrorMsg 'At least one access point is not online'

Add-PrtgChannel -Channel 'Gateways Total'        -Value $gwTotal -HideChart
Add-PrtgChannel -Channel 'Gateways Online'       -Value $gwOnline

if (-not $NoStatistics) {
    $maxCpu = 0; $avgCpu = 0
    if ($cpuValues.Count -gt 0) {
        $maxCpu = ($cpuValues | Measure-Object -Maximum).Maximum
        $avgCpu = ($cpuValues | Measure-Object -Average).Average
    }
    $maxMem = 0; $avgMem = 0
    if ($memValues.Count -gt 0) {
        $maxMem = ($memValues | Measure-Object -Maximum).Maximum
        $avgMem = ($memValues | Measure-Object -Average).Average
    }
    $minUptime = 0
    if ($uptimeValues.Count -gt 0) { $minUptime = ($uptimeValues | Measure-Object -Minimum).Minimum }

    Add-PrtgChannel -Channel 'CPU Load Max'      -Value $maxCpu -Unit 'Percent' -AsFloat -LimitMaxWarning 75 -LimitMaxError 90 -LimitErrorMsg 'A device is running at very high CPU load'
    Add-PrtgChannel -Channel 'CPU Load Avg'      -Value $avgCpu -Unit 'Percent' -AsFloat
    Add-PrtgChannel -Channel 'Memory Used Max'   -Value $maxMem -Unit 'Percent' -AsFloat -LimitMaxWarning 85 -LimitMaxError 95 -LimitErrorMsg 'A device is nearly out of memory'
    Add-PrtgChannel -Channel 'Memory Used Avg'   -Value $avgMem -Unit 'Percent' -AsFloat
    Add-PrtgChannel -Channel 'Lowest Uptime'     -Value $minUptime -Unit 'TimeSeconds' -LimitMinWarning 3600 -LimitWarningMsg 'A device rebooted within the last hour'
    Add-PrtgChannel -Channel 'Rebooted last 24h' -Value $recentReboots
    Add-PrtgChannel -Channel 'Uplink Rx Total'   -Value $rxTotal -Unit 'Custom' -CustomUnit 'B/s' -HideChart
    Add-PrtgChannel -Channel 'Uplink Tx Total'   -Value $txTotal -Unit 'Custom' -CustomUnit 'B/s' -HideChart
}

if ($IncludeDetails) {
    Add-PrtgChannel -Channel 'Firmware Updates Available' -Value $fwUpdates -LimitMaxWarning 0 -LimitWarningMsg 'Firmware updates are pending'
    Add-PrtgChannel -Channel 'Unsupported Devices'        -Value $unsupported -HideChart
    Add-PrtgChannel -Channel 'Switch Ports Total'         -Value $portsTotal -HideChart
    Add-PrtgChannel -Channel 'Switch Ports Up'            -Value $portsUp
    Add-PrtgChannel -Channel 'PoE Ports Enabled'          -Value $poeEnabled -HideChart
    Add-PrtgChannel -Channel 'PoE Ports Delivering'       -Value $poeDelivering
}

Add-PrtgChannel -Channel 'API Errors' -Value $script:ApiErrors -LimitMaxWarning 0 -LimitWarningMsg 'Some per-device API calls failed'
$swatch.Stop()
Add-PrtgChannel -Channel 'Execution Time' -Value $swatch.ElapsedMilliseconds -Unit 'TimeResponse' -HideChart

# ===========================================================================
# Sensor message
# ===========================================================================

$parts = New-Object System.Collections.Generic.List[string]
if ($script:ResolvedSiteName) { [void]$parts.Add("Site '$($script:ResolvedSiteName)'") }
[void]$parts.Add("$online/$total online")
[void]$parts.Add("$swOnline/$swTotal switches")
[void]$parts.Add("$apOnline/$apTotal APs")
if ($IncludeDetails -and $fwUpdates -gt 0) { [void]$parts.Add("$fwUpdates firmware update(s)") }
[void]$parts.Add($script:PlatformLabel)

$message = $parts -join ' | '

if ($offlineNames.Count -gt 0) {
    $shown  = @($offlineNames | Select-Object -First 5)
    $suffix = ''
    if ($offlineNames.Count -gt 5) { $suffix = ", +$($offlineNames.Count - 5) more" }
    $message += ' | Offline: ' + ($shown -join ', ') + $suffix
}

# ===========================================================================
# Emit
# ===========================================================================

$xml = New-Object System.Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8" ?>')
[void]$xml.AppendLine('<prtg>')
foreach ($c in $script:Channels) { [void]$xml.AppendLine($c) }
[void]$xml.AppendLine('  <text>' + (ConvertTo-XmlText $message) + '</text>')
[void]$xml.Append('</prtg>')

[Console]::Out.Write($xml.ToString())
exit 0