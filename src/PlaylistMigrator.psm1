Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:SpotifyApiBase = 'https://api.spotify.com/v1'
$script:SpotifyAccountsBase = 'https://accounts.spotify.com'
$script:SpotifyRequestTimeoutSeconds = 30
$script:SpotifyMaxAutoRetryAfterSeconds = 60
$script:LastSpotifySearchRequestUtc = $null

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Ensure-ParentDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Value
    )

    Ensure-ParentDirectory -Path $Path
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ObjectPropertyValue {
    param(
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function ConvertTo-Base64Url {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-RandomVerifier {
    param(
        [int]$Length = 64
    )

    $allowed = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~'
    $bytes = New-Object byte[] ($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($allowed[$byte % $allowed.Length])
    }

    return $builder.ToString()
}

function Get-Sha256Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Value))
    }
    finally {
        $sha.Dispose()
    }
}

function Normalize-RedirectUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RedirectUri
    )

    if ($RedirectUri.EndsWith('/')) {
        return $RedirectUri
    }

    return $RedirectUri + '/'
}

function Resolve-Config {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory (Get-Location).Path
    if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
        throw ("Missing config file: {0}. Copy config/spotify.sample.json to config/spotify.json first." -f $resolvedConfigPath)
    }

    $config = Read-JsonFile -Path $resolvedConfigPath
    $configDirectory = Split-Path -Parent $resolvedConfigPath
    $tokenPath = Resolve-AbsolutePath -Path ([string]$config.tokenPath) -BaseDirectory $configDirectory
    $searchCachePathSetting = [string](Get-ObjectPropertyValue -Object $config -Name 'searchCachePath' -DefaultValue '../data/spotify-search-cache.json')
    if ([string]::IsNullOrWhiteSpace($searchCachePathSetting)) {
        $searchCachePathSetting = '../data/spotify-search-cache.json'
    }
    $searchCachePath = Resolve-AbsolutePath -Path $searchCachePathSetting -BaseDirectory $configDirectory
    $requestDelayMsValue = Get-ObjectPropertyValue -Object $config -Name 'requestDelayMs' -DefaultValue 350
    if ($null -eq $requestDelayMsValue -or [string]::IsNullOrWhiteSpace([string]$requestDelayMsValue)) {
        $requestDelayMsValue = 350
    }
    $requestDelayMs = [int]$requestDelayMsValue
    if ($requestDelayMs -lt 0) {
        throw 'requestDelayMs must be 0 or greater in config/spotify.json.'
    }

    $redirectUri = Normalize-RedirectUri -RedirectUri ([string]$config.redirectUri)
    $clientId = [string]$config.clientId
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        throw 'clientId is required in config/spotify.json.'
    }

    return [PSCustomObject]@{
        Path          = $resolvedConfigPath
        Directory     = $configDirectory
        ClientId      = $clientId
        RedirectUri   = $redirectUri
        TokenPath     = $tokenPath
        SearchCachePath = $searchCachePath
        RequestDelayMs = $requestDelayMs
        DefaultMarket = [string]$config.defaultMarket
        Scopes        = @($config.scopes)
    }
}

function Get-QueryDictionary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    Add-Type -AssemblyName System.Web
    $uri = [Uri]$Url
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $output = @{}
    foreach ($key in $query.AllKeys) {
        if ($null -ne $key) {
            $output[$key] = $query[$key]
        }
    }

    return $output
}

function Get-QueryParameterValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Query,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Query.ContainsKey($Name)) {
        return [string]$Query[$Name]
    }

    return $null
}

function Get-CollectionCount {
    param(
        $Value
    )

    return @($Value).Count
}

function New-UrlEncodedQueryString {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Query
    )

    Add-Type -AssemblyName System.Web
    $pairs = foreach ($key in $Query.Keys) {
        $value = $Query[$key]
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            '{0}={1}' -f [System.Web.HttpUtility]::UrlEncode([string]$key), [System.Web.HttpUtility]::UrlEncode([string]$value)
        }
    }

    return ($pairs -join '&')
}

function Start-LocalOAuthListener {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RedirectUri,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedState,

        [int]$TimeoutSeconds = 180
    )

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($RedirectUri)
    $listener.Start()

    try {
        $asyncResult = $listener.BeginGetContext($null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw 'Timed out while waiting for Spotify authorization callback.'
        }

        $context = $listener.EndGetContext($asyncResult)
        $query = Get-QueryDictionary -Url $context.Request.Url.AbsoluteUri
        $errorValue = Get-QueryParameterValue -Query $query -Name 'error'
        $stateValue = Get-QueryParameterValue -Query $query -Name 'state'
        $codeValue = Get-QueryParameterValue -Query $query -Name 'code'

        $html = '<html><body><h2>Spotify login completed.</h2><p>You can return to the terminal now.</p></body></html>'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.StatusCode = 200
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()

        if ($errorValue) {
            throw ("Spotify authorization failed: {0}" -f $errorValue)
        }

        if ($stateValue -ne $ExpectedState) {
            throw 'Spotify authorization state validation failed.'
        }

        if (-not $codeValue) {
            throw 'Spotify did not return an authorization code.'
        }

        return [PSCustomObject]@{
            Code = $codeValue
        }
    }
    finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}

function Get-ManualAuthorizationCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedState
    )

    $redirectedUrl = Read-Host 'Paste the full redirected URL from your browser'
    $query = Get-QueryDictionary -Url $redirectedUrl
    $errorValue = Get-QueryParameterValue -Query $query -Name 'error'
    $stateValue = Get-QueryParameterValue -Query $query -Name 'state'
    $codeValue = Get-QueryParameterValue -Query $query -Name 'code'

    if ($errorValue) {
        throw ("Spotify authorization failed: {0}" -f $errorValue)
    }

    if ($stateValue -ne $ExpectedState) {
        throw 'Spotify authorization state validation failed.'
    }

    if (-not $codeValue) {
        throw 'No authorization code was found in the redirected URL.'
    }

    return [PSCustomObject]@{
        Code = $codeValue
    }
}

function Get-HttpResponseBody {
    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    try {
        $stream = $Response.GetResponseStream()
        if ($null -eq $stream) {
            return $null
        }

        if ($stream.CanSeek) {
            $stream.Position = 0
        }

        $reader = New-Object System.IO.StreamReader($stream)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Get-HttpErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return ('{0}: {1}' -f $Context, $ErrorRecord.Exception.Message)
    }

    $statusLine = $null
    try {
        $statusCode = [int]$response.StatusCode
        $statusDescription = [string]$response.StatusDescription
        if ([string]::IsNullOrWhiteSpace($statusDescription)) {
            $statusLine = 'HTTP {0}' -f $statusCode
        }
        else {
            $statusLine = 'HTTP {0} {1}' -f $statusCode, $statusDescription
        }
    }
    catch {
        $statusLine = $null
    }

    $detail = $null
    $body = Get-HttpResponseBody -Response $response
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        try {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error_description) {
                $detail = [string]$parsed.error_description
            }
            elseif ($parsed.error -is [string]) {
                $detail = [string]$parsed.error
            }
            elseif ($parsed.error.message) {
                $detail = [string]$parsed.error.message
            }
        }
        catch {
            $detail = $null
        }

        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = $body.Trim()
        }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($Context)
    if (-not [string]::IsNullOrWhiteSpace($statusLine)) {
        $parts.Add($statusLine)
    }
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $parts.Add($detail)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.Message)) {
        $parts.Add($ErrorRecord.Exception.Message)
    }

    return ($parts -join ': ')
}

function Invoke-SpotifyTokenRequest {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Body
    )

    try {
        return Invoke-RestMethod `
            -Method Post `
            -Uri ($script:SpotifyAccountsBase + '/api/token') `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $Body `
            -TimeoutSec $script:SpotifyRequestTimeoutSeconds `
            -ErrorAction Stop
    }
    catch {
        throw (Get-HttpErrorMessage -ErrorRecord $_ -Context 'Spotify token request failed')
    }
}

function Save-SpotifyToken {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Response,

        [string]$ExistingRefreshToken
    )

    $refreshToken = [string]$Response.refresh_token
    if ([string]::IsNullOrWhiteSpace($refreshToken)) {
        $refreshToken = $ExistingRefreshToken
    }

    $token = [PSCustomObject]@{
        accessToken  = [string]$Response.access_token
        refreshToken = $refreshToken
        tokenType    = [string]$Response.token_type
        scope        = [string]$Response.scope
        expiresAtUtc = (Get-Date).ToUniversalTime().AddSeconds([int]$Response.expires_in).ToString('o')
    }

    Write-JsonFile -Path $Config.TokenPath -Value $token
    return $token
}

function Refresh-SpotifyToken {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Token
    )

    $refreshToken = [string]$Token.refreshToken
    if ([string]::IsNullOrWhiteSpace($refreshToken)) {
        throw 'Spotify token refresh failed because no refresh token is available. Run login again.'
    }

    $response = Invoke-SpotifyTokenRequest -Body @{
        client_id     = $Config.ClientId
        grant_type    = 'refresh_token'
        refresh_token = $refreshToken
    }

    return Save-SpotifyToken -Config $Config -Response $response -ExistingRefreshToken $refreshToken
}

function Connect-Spotify {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [switch]$OpenBrowser
    )

    $config = Resolve-Config -ConfigPath $ConfigPath
    $codeVerifier = New-RandomVerifier
    $codeChallenge = ConvertTo-Base64Url -Bytes (Get-Sha256Bytes -Value $codeVerifier)
    $state = [guid]::NewGuid().ToString('n')

    $query = @{
        client_id             = $config.ClientId
        response_type         = 'code'
        redirect_uri          = $config.RedirectUri
        scope                 = ($config.Scopes -join ' ')
        state                 = $state
        code_challenge_method = 'S256'
        code_challenge        = $codeChallenge
    }

    $authUrl = '{0}/authorize?{1}' -f $script:SpotifyAccountsBase, (New-UrlEncodedQueryString -Query $query)
    Write-Host 'Open this URL and approve access in Spotify:'
    Write-Host $authUrl

    if ($OpenBrowser) {
        try {
            Start-Process $authUrl | Out-Null
        }
        catch {
            Write-Warning 'Unable to auto-open the browser. Please paste the URL manually.'
        }
    }

    try {
        $callback = Start-LocalOAuthListener -RedirectUri $config.RedirectUri -ExpectedState $state
    }
    catch {
        Write-Warning ("Local callback failed: {0}" -f $_.Exception.Message)
        $callback = Get-ManualAuthorizationCode -ExpectedState $state
    }

    $response = Invoke-SpotifyTokenRequest -Body @{
        client_id     = $config.ClientId
        grant_type    = 'authorization_code'
        code          = $callback.Code
        redirect_uri  = $config.RedirectUri
        code_verifier = $codeVerifier
    }

    $savedToken = Save-SpotifyToken -Config $config -Response $response
    return [PSCustomObject]@{
        TokenPath = $config.TokenPath
        Token     = $savedToken
    }
}

function Get-SpotifyToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $config = Resolve-Config -ConfigPath $ConfigPath
    if (-not (Test-Path -LiteralPath $config.TokenPath)) {
        throw ("Missing Spotify token file: {0}. Run .\migrate.ps1 login -OpenBrowser first." -f $config.TokenPath)
    }

    $token = Read-JsonFile -Path $config.TokenPath
    $expiresAt = [DateTime]::Parse([string]$token.expiresAtUtc).ToUniversalTime()
    if ($expiresAt -le (Get-Date).ToUniversalTime().AddMinutes(1)) {
        $token = Refresh-SpotifyToken -Config $config -Token $token
    }

    return [PSCustomObject]@{
        Config = $config
        Token  = $token
    }
}

function New-QueryString {
    param(
        [hashtable]$Query
    )

    if (-not $Query -or $Query.Count -eq 0) {
        return ''
    }

    $queryString = New-UrlEncodedQueryString -Query $Query
    if ([string]::IsNullOrWhiteSpace($queryString)) {
        return ''
    }

    return '?' + $queryString
}

function Invoke-SpotifyApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [hashtable]$Query,
        $Body,
        [switch]$RefreshRetryUsed
    )

    $session = Get-SpotifyToken -ConfigPath $ConfigPath
    $uri = $script:SpotifyApiBase + $Endpoint + (New-QueryString -Query $Query)

    $invokeParams = @{
        Method      = $Method
        Uri         = $uri
        Headers     = @{ Authorization = 'Bearer ' + [string]$session.Token.accessToken }
        ErrorAction = 'Stop'
        TimeoutSec  = $script:SpotifyRequestTimeoutSeconds
    }

    $hasBody = $PSBoundParameters.ContainsKey('Body')
    if ($hasBody) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
        $invokeParams['ContentType'] = 'application/json; charset=utf-8'
        $invokeParams['Body'] = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    }

    try {
        return Invoke-RestMethod @invokeParams
    }
    catch {
        $response = $_.Exception.Response
        if ($null -eq $response) {
            throw
        }

        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 401 -and -not $RefreshRetryUsed) {
            $null = Refresh-SpotifyToken -Config $session.Config -Token $session.Token

            $retryParams = @{
                ConfigPath       = $ConfigPath
                Method           = $Method
                Endpoint         = $Endpoint
                Query            = $Query
                RefreshRetryUsed = $true
            }
            if ($hasBody) {
                $retryParams['Body'] = $Body
            }

            return Invoke-SpotifyApi @retryParams
        }

        if ($statusCode -eq 429) {
            $retryAfter = $response.Headers['Retry-After']
            $retryAfterSeconds = 0
            if ($retryAfter -and [int]::TryParse([string]$retryAfter, [ref]$retryAfterSeconds) -and $retryAfterSeconds -gt 0) {
                if ($retryAfterSeconds -le $script:SpotifyMaxAutoRetryAfterSeconds) {
                    Write-Warning ('Spotify rate limit reached. Retrying after {0} seconds.' -f $retryAfterSeconds)
                    Start-Sleep -Seconds $retryAfterSeconds

                    $retryParams = @{
                        ConfigPath       = $ConfigPath
                        Method           = $Method
                        Endpoint         = $Endpoint
                        Query            = $Query
                        RefreshRetryUsed = [bool]$RefreshRetryUsed
                    }
                    if ($hasBody) {
                        $retryParams['Body'] = $Body
                    }

                    return Invoke-SpotifyApi @retryParams
                }

                throw ('Spotify API rate limit reached for {0} {1}. Spotify asked to retry after {2} seconds, so the tool stopped instead of waiting for hours.' -f ([string]$Method).ToUpperInvariant(), $Endpoint, $retryAfterSeconds)
            }

            throw ('Spotify API rate limit reached for {0} {1}. Try again later.' -f ([string]$Method).ToUpperInvariant(), $Endpoint)
        }

        throw (Get-HttpErrorMessage -ErrorRecord $_ -Context ('Spotify API request failed for {0} {1}' -f ([string]$Method).ToUpperInvariant(), $Endpoint))
    }
}

function New-SpotifySearchCacheKey {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Query
    )

    $parts = foreach ($key in @($Query.Keys | Sort-Object)) {
        '{0}={1}' -f [string]$key, [string]$Query[$key]
    }

    $canonicalQuery = 'spotify-search-v1|' + ($parts -join '&')
    return ConvertTo-Base64Url -Bytes (Get-Sha256Bytes -Value $canonicalQuery)
}

function Import-SpotifySearchCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $entries = @{}
    if (Test-Path -LiteralPath $Path) {
        try {
            $cacheFile = Read-JsonFile -Path $Path
            $entriesObject = Get-ObjectPropertyValue -Object $cacheFile -Name 'entries'
            if ($entriesObject) {
                foreach ($property in $entriesObject.PSObject.Properties) {
                    $entries[$property.Name] = $property.Value
                }
            }
        }
        catch {
            Write-Warning ("Unable to read Spotify search cache. A new cache will be created at {0}. Error: {1}" -f $Path, $_.Exception.Message)
        }
    }

    return [PSCustomObject]@{
        Path   = $Path
        Entries = $entries
        Hits   = 0
        Misses = 0
        Writes = 0
    }
}

function Save-SpotifySearchCache {
    param(
        [Parameter(Mandatory = $true)]
        $SearchCache
    )

    if ($null -eq $SearchCache -or [string]::IsNullOrWhiteSpace([string]$SearchCache.Path)) {
        return
    }

    Write-JsonFile -Path ([string]$SearchCache.Path) -Value ([PSCustomObject]@{
        version      = 1
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        entries      = $SearchCache.Entries
    })
}

function ConvertTo-SpotifySearchCacheResponse {
    param(
        $Response
    )

    $items = foreach ($item in @((Get-NestedPropertyValue -Object $Response -Path 'tracks.items'))) {
        if ($null -eq $item) {
            continue
        }

        $artistsValue = Get-NestedPropertyValue -Object $item -Path 'artists'
        $artists = @()
        if ($artistsValue) {
            $artists = @($artistsValue | ForEach-Object {
                    $artistName = [string](Get-NestedPropertyValue -Object $_ -Path 'name')
                    if (-not [string]::IsNullOrWhiteSpace($artistName)) {
                        [PSCustomObject]@{
                            name = $artistName
                        }
                    }
                })
        }

        [PSCustomObject]@{
            id            = [string](Get-NestedPropertyValue -Object $item -Path 'id')
            uri           = [string](Get-NestedPropertyValue -Object $item -Path 'uri')
            name          = [string](Get-NestedPropertyValue -Object $item -Path 'name')
            duration_ms   = Get-NestedPropertyValue -Object $item -Path 'duration_ms'
            external_urls = [PSCustomObject]@{
                spotify = [string](Get-NestedPropertyValue -Object $item -Path 'external_urls.spotify')
            }
            external_ids  = [PSCustomObject]@{
                isrc = [string](Get-NestedPropertyValue -Object $item -Path 'external_ids.isrc')
            }
            artists       = @($artists)
            album         = [PSCustomObject]@{
                name = [string](Get-NestedPropertyValue -Object $item -Path 'album.name')
            }
        }
    }

    return [PSCustomObject]@{
        tracks = [PSCustomObject]@{
            items = @($items)
        }
    }
}

function Wait-SpotifySearchThrottle {
    param(
        [int]$RequestDelayMs
    )

    if ($RequestDelayMs -le 0 -or $null -eq $script:LastSpotifySearchRequestUtc) {
        return
    }

    $elapsedMs = ((Get-Date).ToUniversalTime() - $script:LastSpotifySearchRequestUtc).TotalMilliseconds
    $remainingMs = $RequestDelayMs - $elapsedMs
    if ($remainingMs -gt 0) {
        Start-Sleep -Milliseconds ([int][Math]::Ceiling($remainingMs))
    }
}

function Search-SpotifyTracks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Query,

        $SearchCache,
        [int]$RequestDelayMs = 0
    )

    $cacheKey = New-SpotifySearchCacheKey -Query $Query
    if ($SearchCache -and $SearchCache.Entries.ContainsKey($cacheKey)) {
        $SearchCache.Hits += 1
        $entry = $SearchCache.Entries[$cacheKey]
        return $entry.response
    }

    if ($SearchCache) {
        $SearchCache.Misses += 1
    }

    Wait-SpotifySearchThrottle -RequestDelayMs $RequestDelayMs
    try {
        $response = Invoke-SpotifyApi -ConfigPath $ConfigPath -Method Get -Endpoint '/search' -Query $Query
    }
    finally {
        $script:LastSpotifySearchRequestUtc = (Get-Date).ToUniversalTime()
    }

    $cacheResponse = ConvertTo-SpotifySearchCacheResponse -Response $response
    if ($SearchCache) {
        $SearchCache.Entries[$cacheKey] = [PSCustomObject]@{
            cachedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            query       = $Query
            response    = $cacheResponse
        }
        $SearchCache.Writes += 1
        Save-SpotifySearchCache -SearchCache $SearchCache
    }

    return $cacheResponse
}

function Get-NestedPropertyValue {
    param(
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) {
            return $null
        }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) {
                return $null
            }

            $current = $current[$part]
            continue
        }

        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

function Get-FirstPresentValue {
    param(
        $Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        $value = Get-NestedPropertyValue -Object $Object -Path $path
        if ($null -eq $value) {
            continue
        }

        if ($value -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
            continue
        }

        return $value
    }

    return $null
}

function Split-ArtistString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $parts = $Value -split '\s*(?:/|&|,|\uFF0C|\u3001)\s*'
    return @($parts | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-ArtistNames {
    param(
        $Item
    )

    $artistValue = Get-FirstPresentValue -Object $Item -Paths @('artists', 'ar', 'singer', 'singers', 'artist', 'artistsText')
    if ($null -eq $artistValue) {
        return @()
    }

    if ($artistValue -is [string]) {
        return Split-ArtistString -Value $artistValue
    }

    if ($artistValue -isnot [string]) {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @($artistValue)) {
            if ($entry -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($entry)) {
                    $names.Add($entry.Trim())
                }
                continue
            }

            $name = Get-FirstPresentValue -Object $entry -Paths @('name', 'title')
            if ($name) {
                $names.Add([string]$name)
            }
        }

        return $names.ToArray()
    }

    return @()
}

function ConvertTo-DurationMs {
    param(
        $Item
    )

    $duration = Get-FirstPresentValue -Object $Item -Paths @('duration_ms', 'duration', 'dt', 'interval')
    if ($null -eq $duration -or [string]::IsNullOrWhiteSpace([string]$duration)) {
        return $null
    }

    $value = [double]$duration
    if ($value -lt 1000) {
        return [int]($value * 1000)
    }

    return [int]$value
}

function New-NormalizedTrack {
    param(
        [Parameter(Mandatory = $true)]
        $Item
    )

    $title = Get-FirstPresentValue -Object $Item -Paths @('title', 'name', 'songname', 'songName', 'trackName')
    if ([string]::IsNullOrWhiteSpace([string]$title)) {
        return $null
    }

    $artists = Get-ArtistNames -Item $Item
    $album = Get-FirstPresentValue -Object $Item -Paths @('album.name', 'al.name', 'album', 'albumname', 'albumName')
    $durationMs = ConvertTo-DurationMs -Item $Item
    $isrc = Get-FirstPresentValue -Object $Item -Paths @('isrc', 'ISRC')
    $sourceId = Get-FirstPresentValue -Object $Item -Paths @('id', 'songmid', 'songMid', 'trackId')

    return [PSCustomObject]@{
        Title      = [string]$title
        Artists    = @($artists)
        ArtistText = (@($artists) -join ', ')
        Album      = [string]$album
        DurationMs = $durationMs
        Isrc       = [string]$isrc
        SourceId   = [string]$sourceId
        Raw        = $Item
    }
}

function Import-CsvPlaylist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rows = Import-Csv -LiteralPath $Path -Encoding UTF8
    $tracks = foreach ($row in $rows) {
        $track = New-NormalizedTrack -Item ([PSCustomObject]@{
                title       = $row.title
                artistsText = $row.artist
                album       = $row.album
                duration_ms = $row.duration_ms
                isrc        = $row.isrc
                trackId     = $row.id
            })

        if ($track) {
            $track
        }
    }

    return [PSCustomObject]@{
        Name   = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Tracks = @($tracks)
    }
}

function Import-JsonPlaylist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $json = Read-JsonFile -Path $Path
    $playlistName = Get-FirstPresentValue -Object $json -Paths @('name', 'playlistName', 'dissname', 'title', 'playlist.name')
    if (-not $playlistName) {
        $playlistName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }

    $trackContainer = $null
    foreach ($candidatePath in @('tracks', 'songs', 'songlist', 'playlist.tracks', 'playlist.songs')) {
        $trackContainer = Get-NestedPropertyValue -Object $json -Path $candidatePath
        if ($trackContainer) {
            break
        }
    }

    if (-not $trackContainer -and $json -is [System.Collections.IEnumerable]) {
        $trackContainer = $json
    }

    if (-not $trackContainer) {
        throw 'No tracks array was found in the JSON file.'
    }

    $tracks = foreach ($item in @($trackContainer)) {
        $track = New-NormalizedTrack -Item $item
        if ($track) {
            $track
        }
    }

    return [PSCustomObject]@{
        Name   = [string]$playlistName
        Tracks = @($tracks)
    }
}

function Import-SourcePlaylist {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('csv', 'generic-json', 'netease-json', 'qqmusic-json')]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path -BaseDirectory (Get-Location).Path
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw ("Source file not found: {0}" -f $resolvedPath)
    }

    $playlist = switch ($Provider) {
        'csv' { Import-CsvPlaylist -Path $resolvedPath }
        'generic-json' { Import-JsonPlaylist -Path $resolvedPath }
        'netease-json' { Import-JsonPlaylist -Path $resolvedPath }
        'qqmusic-json' { Import-JsonPlaylist -Path $resolvedPath }
    }

    if ($playlist.Tracks.Count -eq 0) {
        throw 'The source playlist did not contain any usable track rows.'
    }

    return $playlist
}

function Convert-ToNormalizedPlaylist {
    param(
        [Parameter(Mandatory = $true)]
        $Playlist
    )

    $tracks = foreach ($item in @($Playlist.Tracks)) {
        $track = New-NormalizedTrack -Item $item
        if ($track) {
            $track
        }
    }

    return [PSCustomObject]@{
        Name   = [string]$Playlist.Name
        Tracks = @($tracks)
    }
}

function New-WebRequestHeaders {
    $headers = @{
        'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PlaylistMigrator/1.0'
        'Accept-Language' = 'zh-CN,zh;q=0.9,en;q=0.8'
    }

    return $headers
}

function Invoke-WebJsonRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        $Body,
        [hashtable]$Headers
    )

    $requestHeaders = New-WebRequestHeaders
    if ($Headers) {
        foreach ($key in $Headers.Keys) {
            $requestHeaders[$key] = $Headers[$key]
        }
    }

    $invokeParams = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $requestHeaders
        ErrorAction = 'Stop'
        TimeoutSec  = 30
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $invokeParams['ContentType'] = 'application/json'
        $invokeParams['Body'] = ($Body | ConvertTo-Json -Depth 20)
    }

    return Invoke-RestMethod @invokeParams
}

function Get-QueryDictionaryFromRawString {
    param(
        [string]$QueryString
    )

    Add-Type -AssemblyName System.Web

    if ([string]::IsNullOrWhiteSpace($QueryString)) {
        return @{}
    }

    if ($QueryString.StartsWith('?')) {
        $QueryString = $QueryString.Substring(1)
    }

    $query = [System.Web.HttpUtility]::ParseQueryString($QueryString)
    $output = @{}
    foreach ($key in $query.AllKeys) {
        if ($null -ne $key) {
            $output[$key] = $query[$key]
        }
    }

    return $output
}

function Get-ShareLinkCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalizedText = $Text.Trim().Replace('&amp;', '&')
    if ([string]::IsNullOrWhiteSpace($normalizedText)) {
        throw 'SourceLink cannot be empty.'
    }

    $candidate = $null
    $domainMatch = [regex]::Match($normalizedText, '((?:https?://)?(?:(?:[\w-]+\.)*music\.163\.com|(?:[\w-]+\.)*y\.qq\.com)[^\s"''<>]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($domainMatch.Success) {
        $candidate = $domainMatch.Groups[1].Value
    }
    else {
        $genericMatch = [regex]::Match($normalizedText, '(https?://[^\s"''<>]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($genericMatch.Success) {
            $candidate = $genericMatch.Groups[1].Value
        }
        elseif ($normalizedText -match '^(?:(?:[\w-]+\.)*music\.163\.com|(?:[\w-]+\.)*y\.qq\.com)\b') {
            $candidate = 'https://' + $normalizedText
        }
    }

    if (-not $candidate) {
        throw 'No supported QQ Music or NetEase playlist link was found in SourceLink.'
    }

    return $candidate.TrimEnd([char[]]'.。，,；;!?！？)]}>"''')
}

function Get-ProviderLabel {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('netease', 'qqmusic')]
        [string]$Provider
    )

    switch ($Provider) {
        'netease' { return 'NetEase Cloud Music' }
        'qqmusic' { return 'QQ Music' }
    }
}

function Get-SourcePlaylistDisplayName {
    param(
        [string]$Name,
        [string]$Provider,
        [string]$ProviderPlaylistId
    )

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return $Name.Trim()
    }

    $providerLabel = switch ($Provider) {
        'netease' { 'NetEase Cloud Music' }
        'qqmusic' { 'QQ Music' }
        default { 'Source' }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProviderPlaylistId)) {
        return ('{0} Playlist {1}' -f $providerLabel, $ProviderPlaylistId)
    }

    return ('{0} Playlist' -f $providerLabel)
}

function Resolve-PlaylistShareLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceText
    )

    $shareUrl = Get-ShareLinkCandidate -Text $SourceText
    if ($shareUrl -notmatch '^https?://') {
        $shareUrl = 'https://' + $shareUrl
    }

    $uri = [Uri]$shareUrl
    $host = $uri.Host.ToLowerInvariant()
    $query = Get-QueryDictionary -Url $uri.AbsoluteUri
    $fragment = [Uri]::UnescapeDataString($uri.Fragment.TrimStart('#'))
    $fragmentQuery = @{}
    if ($fragment.Contains('?')) {
        $fragmentQuery = Get-QueryDictionaryFromRawString -QueryString ($fragment.Substring($fragment.IndexOf('?') + 1))
    }

    $provider = $null
    $playlistId = $null

    if ($host.EndsWith('163.com')) {
        $provider = 'netease'
        foreach ($key in @('id', 'playlistId')) {
            if ($query[$key]) {
                $playlistId = $query[$key]
                break
            }
        }

        if (-not $playlistId) {
            foreach ($key in @('id', 'playlistId')) {
                if ($fragmentQuery[$key]) {
                    $playlistId = $fragmentQuery[$key]
                    break
                }
            }
        }

        if (-not $playlistId -and $fragment -match '/playlist(?:/|\?id=)(\d+)') {
            $playlistId = $Matches[1]
        }
    }
    elseif ($host.EndsWith('y.qq.com')) {
        $provider = 'qqmusic'
        foreach ($key in @('id', 'disstid', 'tid')) {
            if ($query[$key]) {
                $playlistId = $query[$key]
                break
            }
        }

        if (-not $playlistId) {
            foreach ($segment in ($uri.AbsolutePath.Trim('/') -split '/')) {
                if ($segment -match '^\d+$') {
                    $playlistId = $segment
                }
            }
        }

        if (-not $playlistId) {
            foreach ($key in @('id', 'disstid', 'tid')) {
                if ($fragmentQuery[$key]) {
                    $playlistId = $fragmentQuery[$key]
                    break
                }
            }
        }
    }

    if (-not $provider -or -not $playlistId) {
        throw ("Unsupported playlist share link: {0}" -f $shareUrl)
    }

    return [PSCustomObject]@{
        Provider      = $provider
        ProviderLabel = Get-ProviderLabel -Provider $provider
        PlaylistId    = [string]$playlistId
        SourceUrl     = $shareUrl
    }
}

function Invoke-QQMusicPlaylistRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlaylistId,

        [int]$Begin = 0,
        [int]$Length = 1000,
        [int]$OnlySongList = 0
    )

    $response = Invoke-WebJsonRequest `
        -Method Post `
        -Uri 'https://u.y.qq.com/cgi-bin/musicu.fcg' `
        -Body @{
            comm  = @{
                cv          = 0
                ct          = 24
                format      = 'json'
                inCharset   = 'utf-8'
                outCharset  = 'utf-8'
                notice      = 0
                platform    = 'yqq.json'
                needNewCode = 1
                uin         = '0'
            }
            req_0 = @{
                module = 'music.srfDissInfo.aiDissInfo'
                method = 'uniform_get_Dissinfo'
                param  = @{
                    disstid      = [int64]$PlaylistId
                    userinfo     = 1
                    tag          = 1
                    orderlist    = 1
                    song_begin   = $Begin
                    song_num     = $Length
                    onlysonglist = $OnlySongList
                    enc_host_uin = ''
                }
            }
        }

    if ($response.code -ne 0 -or $response.req_0.code -ne 0 -or $response.req_0.data.code -ne 0) {
        throw ("QQ Music playlist request failed for playlist {0}." -f $PlaylistId)
    }

    return $response.req_0.data
}

function Get-QQMusicPlaylistFromShareLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlaylistId,

        [Parameter(Mandatory = $true)]
        [string]$SourceUrl
    )

    $pageSize = 1000
    $firstPage = Invoke-QQMusicPlaylistRequest -PlaylistId $PlaylistId -Begin 0 -Length $pageSize -OnlySongList 0
    $songs = New-Object System.Collections.Generic.List[object]
    foreach ($song in @($firstPage.songlist)) {
        $songs.Add($song)
    }

    $expectedCount = [int]$firstPage.dirinfo.songnum
    while ($songs.Count -lt $expectedCount) {
        $nextPage = Invoke-QQMusicPlaylistRequest -PlaylistId $PlaylistId -Begin $songs.Count -Length $pageSize -OnlySongList 1
        $batch = @($nextPage.songlist)
        if ($batch.Count -eq 0) {
            break
        }

        foreach ($song in $batch) {
            $songs.Add($song)
        }
    }

    $tracks = foreach ($song in $songs) {
        [PSCustomObject]@{
            id       = [string](Get-FirstPresentValue -Object $song -Paths @('id', 'mid'))
            songmid  = [string]$song.mid
            name     = [string](Get-FirstPresentValue -Object $song -Paths @('title', 'name'))
            artists  = @($song.singer | ForEach-Object { [PSCustomObject]@{ name = [string]$_.name } })
            album    = [PSCustomObject]@{
                name = [string](Get-FirstPresentValue -Object $song -Paths @('album.title', 'album.name'))
            }
            interval = [int]$song.interval
        }
    }

    $warning = $null
    if ($expectedCount -gt @($tracks).Count) {
        $warning = ('QQ Music returned {0} of {1} tracks for playlist {2}.' -f @($tracks).Count, $expectedCount, $PlaylistId)
    }

    return [PSCustomObject]@{
        Provider          = 'qqmusic'
        ProviderLabel     = Get-ProviderLabel -Provider 'qqmusic'
        ProviderPlaylistId = [string]$firstPage.dirinfo.id
        SourceUrl         = $SourceUrl
        Name              = Get-SourcePlaylistDisplayName -Name ([string]$firstPage.dirinfo.title) -Provider 'qqmusic' -ProviderPlaylistId $PlaylistId
        Description       = [string]$firstPage.dirinfo.desc
        Creator           = [string]$firstPage.dirinfo.host_nick
        TrackCount        = @($tracks).Count
        Warning           = $warning
        Tracks            = @($tracks)
    }
}

function Get-NeteaseSongDetailsByIds {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$TrackIds
    )

    $songs = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $TrackIds.Count; $index += 500) {
        $count = [Math]::Min(500, $TrackIds.Count - $index)
        $chunk = New-Object string[] $count
        [Array]::Copy($TrackIds, $index, $chunk, 0, $count)

        $idsJson = '[' + (($chunk | ForEach-Object { [string]$_ }) -join ',') + ']'
        $response = Invoke-WebJsonRequest `
            -Method Get `
            -Uri ('https://music.163.com/api/song/detail/?ids=' + [Uri]::EscapeDataString($idsJson))

        if ($response.code -ne 200) {
            throw 'NetEase song detail request failed.'
        }

        foreach ($song in @($response.songs)) {
            $songs.Add($song)
        }
    }

    return $songs.ToArray()
}

function Get-NeteasePlaylistFromShareLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlaylistId,

        [Parameter(Mandatory = $true)]
        [string]$SourceUrl
    )

    $response = Invoke-WebJsonRequest `
        -Method Get `
        -Uri ('https://music.163.com/api/v6/playlist/detail?id={0}&n=10000' -f $PlaylistId)

    if ($response.code -ne 200 -or -not $response.playlist) {
        throw ("NetEase playlist request failed for playlist {0}." -f $PlaylistId)
    }

    $orderedTrackIds = @($response.playlist.trackIds | ForEach-Object { [string]$_.id })
    $trackRecords = @($response.playlist.tracks)
    if ([int]$response.playlist.trackCount -gt $trackRecords.Count -and $orderedTrackIds.Count -gt $trackRecords.Count) {
        $trackRecords = Get-NeteaseSongDetailsByIds -TrackIds $orderedTrackIds
    }

    $trackMap = @{}
    foreach ($record in @($trackRecords)) {
        $trackMap[[string]$record.id] = $record
    }

    $tracks = foreach ($trackId in $orderedTrackIds) {
        $track = $trackMap[[string]$trackId]
        if (-not $track) {
            continue
        }

        [PSCustomObject]@{
            id       = [string]$track.id
            name     = [string]$track.name
            artists  = @((Get-FirstPresentValue -Object $track -Paths @('ar', 'artists')) | ForEach-Object { [PSCustomObject]@{ name = [string]$_.name } })
            album    = [PSCustomObject]@{
                name = [string](Get-FirstPresentValue -Object $track -Paths @('al.name', 'album.name'))
            }
            duration = [int](Get-FirstPresentValue -Object $track -Paths @('dt', 'duration'))
        }
    }

    $warning = $null
    if ([int]$response.playlist.trackCount -gt @($tracks).Count) {
        $warning = ('NetEase returned {0} of {1} tracks for playlist {2}.' -f @($tracks).Count, [int]$response.playlist.trackCount, $PlaylistId)
    }

    return [PSCustomObject]@{
        Provider           = 'netease'
        ProviderLabel      = Get-ProviderLabel -Provider 'netease'
        ProviderPlaylistId = [string]$response.playlist.id
        SourceUrl          = $SourceUrl
        Name               = Get-SourcePlaylistDisplayName -Name ([string]$response.playlist.name) -Provider 'netease' -ProviderPlaylistId ([string]$response.playlist.id)
        Description        = [string]$response.playlist.description
        Creator            = [string]$response.playlist.creator.nickname
        TrackCount         = @($tracks).Count
        Warning            = $warning
        Tracks             = @($tracks)
    }
}

function Get-PlaylistFromShareLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceText
    )

    $resolved = Resolve-PlaylistShareLink -SourceText $SourceText
    switch ($resolved.Provider) {
        'netease' {
            return Get-NeteasePlaylistFromShareLink -PlaylistId $resolved.PlaylistId -SourceUrl $resolved.SourceUrl
        }
        'qqmusic' {
            return Get-QQMusicPlaylistFromShareLink -PlaylistId $resolved.PlaylistId -SourceUrl $resolved.SourceUrl
        }
    }

    throw ("Unsupported provider: {0}" -f $resolved.Provider)
}

function Resolve-ExportOutputPath {
    param(
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        $PlaylistData
    )

    $defaultFileName = '{0}-{1}.json' -f $PlaylistData.Provider, $PlaylistData.ProviderPlaylistId

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $defaultDirectory = Resolve-AbsolutePath -Path '.\output\imports' -BaseDirectory (Get-Location).Path
        return Join-Path $defaultDirectory $defaultFileName
    }

    $resolved = Resolve-AbsolutePath -Path $OutputPath -BaseDirectory (Get-Location).Path
    $looksLikeDirectory = $OutputPath.EndsWith('\') -or $OutputPath.EndsWith('/') -or (Test-Path -LiteralPath $resolved -PathType Container) -or (-not [System.IO.Path]::GetExtension($resolved))
    if ($looksLikeDirectory) {
        return Join-Path $resolved $defaultFileName
    }

    return $resolved
}

function Export-PlaylistFromShareLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceText,

        [string]$OutputPath
    )

    $playlistData = Get-PlaylistFromShareLink -SourceText $SourceText
    $resolvedOutputPath = Resolve-ExportOutputPath -OutputPath $OutputPath -PlaylistData $playlistData

    $exportObject = [PSCustomObject]@{
        name               = $playlistData.Name
        description        = $playlistData.Description
        provider           = $playlistData.Provider
        providerLabel      = $playlistData.ProviderLabel
        providerPlaylistId = $playlistData.ProviderPlaylistId
        sourceUrl          = $playlistData.SourceUrl
        creator            = $playlistData.Creator
        fetchedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        warning            = $playlistData.Warning
        tracks             = @($playlistData.Tracks)
    }

    Write-JsonFile -Path $resolvedOutputPath -Value $exportObject

    return [PSCustomObject]@{
        Provider      = $playlistData.Provider
        ProviderLabel = $playlistData.ProviderLabel
        PlaylistName  = $playlistData.Name
        TrackCount    = $playlistData.TrackCount
        OutputPath    = $resolvedOutputPath
        Warning       = $playlistData.Warning
        Playlist      = $playlistData
    }
}

function Normalize-Text {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $normalized = $Text.ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '\(.*?\)|\[.*?\]|\uFF08.*?\uFF09', ' ')
    $normalized = [regex]::Replace($normalized, '[^0-9a-z\u4e00-\u9fa5]+', ' ')
    $normalized = [regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Get-TokenSet {
    param(
        [string]$Text
    )

    $normalized = Normalize-Text -Text $Text
    if (-not $normalized) {
        return @()
    }

    return @($normalized.Split(' ') | Where-Object { $_ })
}

function Get-TokenOverlapScore {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftTokens = Get-TokenSet -Text $Left
    $rightTokens = Get-TokenSet -Text $Right
    $leftCount = Get-CollectionCount -Value $leftTokens
    $rightCount = Get-CollectionCount -Value $rightTokens
    if ($leftCount -eq 0 -or $rightCount -eq 0) {
        return 0.0
    }

    $shared = 0
    foreach ($token in $leftTokens) {
        if ($rightTokens -contains $token) {
            $shared += 1
        }
    }

    $base = [Math]::Max($leftCount, $rightCount)
    if ($base -eq 0) {
        return 0.0
    }

    return [double]$shared / [double]$base
}

function Get-StringMatchScore {
    param(
        [string]$Expected,
        [string]$Actual
    )

    $left = Normalize-Text -Text $Expected
    $right = Normalize-Text -Text $Actual
    if (-not $left -or -not $right) {
        return 0.0
    }

    if ($left -eq $right) {
        return 1.0
    }

    if ($left.Contains($right) -or $right.Contains($left)) {
        return 0.9
    }

    return Get-TokenOverlapScore -Left $left -Right $right
}

function Get-DurationScore {
    param(
        $ExpectedDurationMs,
        $ActualDurationMs
    )

    if ($null -eq $ExpectedDurationMs -or $null -eq $ActualDurationMs) {
        return 0.0
    }

    $delta = [Math]::Abs([int]$ExpectedDurationMs - [int]$ActualDurationMs)
    if ($delta -le 2000) {
        return 1.0
    }
    if ($delta -le 5000) {
        return 0.8
    }
    if ($delta -le 12000) {
        return 0.5
    }

    return 0.0
}

function Get-TrackSearchQueries {
    param(
        [Parameter(Mandatory = $true)]
        $Track
    )

    $queries = New-Object System.Collections.Generic.List[string]
    $artistList = @($Track.Artists)
    $artistCount = Get-CollectionCount -Value $artistList

    if ($Track.Isrc) {
        $queries.Add(('isrc:{0}' -f $Track.Isrc))
    }

    if ($artistCount -gt 0) {
        $primaryArtist = [string]$artistList[0]
        $queries.Add(('track:"{0}" artist:"{1}"' -f $Track.Title, $primaryArtist))
        $queries.Add(('{0} {1}' -f $Track.Title, $primaryArtist))
    }

    if ($Track.Album -and $artistCount -gt 0) {
        $queries.Add(('track:"{0}" artist:"{1}" album:"{2}"' -f $Track.Title, $primaryArtist, $Track.Album))
    }

    $queries.Add($Track.Title)
    return @($queries.ToArray() | Select-Object -Unique)
}

function Find-BestSpotifyMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        $Track,

        [string]$Market,
        $SearchCache,
        [int]$RequestDelayMs = 0
    )

    $candidatesById = @{}
    foreach ($query in (Get-TrackSearchQueries -Track $Track)) {
        $searchParams = @{
            q     = $query
            type  = 'track'
            limit = 10
        }

        if ($Market -and $Market -ne 'from_token') {
            $searchParams['market'] = $Market
        }

        $response = Search-SpotifyTracks -ConfigPath $ConfigPath -Query $searchParams -SearchCache $SearchCache -RequestDelayMs $RequestDelayMs
        $items = @(Get-NestedPropertyValue -Object $response -Path 'tracks.items')
        foreach ($item in $items) {
            if ($null -eq $item) {
                continue
            }

            $candidatesById[[string]$item.id] = $item
        }

        if ((Get-CollectionCount -Value $candidatesById.Keys) -ge 10) {
            break
        }
    }

    $scored = foreach ($candidate in $candidatesById.Values) {
        $candidateArtists = @($candidate.artists | ForEach-Object { $_.name }) -join ', '
        $titleScore = Get-StringMatchScore -Expected $Track.Title -Actual $candidate.name
        $artistScore = Get-StringMatchScore -Expected $Track.ArtistText -Actual $candidateArtists
        $albumScore = Get-StringMatchScore -Expected $Track.Album -Actual $candidate.album.name
        $durationScore = Get-DurationScore -ExpectedDurationMs $Track.DurationMs -ActualDurationMs $candidate.duration_ms

        $score = ($titleScore * 0.5) + ($artistScore * 0.3) + ($albumScore * 0.1) + ($durationScore * 0.1)
        if ($Track.Isrc -and $candidate.external_ids.isrc -eq $Track.Isrc) {
            $score = 1.2
        }

        [PSCustomObject]@{
            Score             = [Math]::Round($score, 4)
            Candidate         = $candidate
            CandidateArtists  = $candidateArtists
            CandidateAlbum    = [string]$candidate.album.name
        }
    }

    $best = $scored | Sort-Object -Property Score -Descending | Select-Object -First 1
    if ($null -eq $best) {
        return $null
    }

    if ($best.Score -lt 0.60) {
        return $null
    }

    return $best
}

function New-SpotifyPlaylist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Description,
        [bool]$Public = $false
    )

    return Invoke-SpotifyApi `
        -ConfigPath $ConfigPath `
        -Method Post `
        -Endpoint '/me/playlists' `
        -Body @{
            name        = $Name
            description = $Description
            public      = $Public
        }
}

function Set-SpotifyPlaylistDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$PlaylistId,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Description,
        [bool]$Public = $false
    )

    Invoke-SpotifyApi `
        -ConfigPath $ConfigPath `
        -Method Put `
        -Endpoint ("/playlists/{0}" -f $PlaylistId) `
        -Body @{
            name        = $Name
            description = $Description
            public      = $Public
        } | Out-Null
}

function Add-TracksToSpotifyPlaylist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$PlaylistId,

        [Parameter(Mandatory = $true)]
        [string[]]$Uris
    )

    for ($index = 0; $index -lt $Uris.Count; $index += 100) {
        $count = [Math]::Min(100, $Uris.Count - $index)
        $chunk = New-Object string[] $count
        [Array]::Copy($Uris, $index, $chunk, 0, $count)

        Invoke-SpotifyApi `
            -ConfigPath $ConfigPath `
            -Method Post `
            -Endpoint ("/playlists/{0}/items" -f $PlaylistId) `
            -Query @{ uris = ($chunk -join ',') } | Out-Null
    }
}

function Invoke-PlaylistMigrationCore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        $Playlist,

        [Parameter(Mandatory = $true)]
        $SourceInfo,

        [string]$PlaylistName,
        [string]$Description,
        [string]$ReportPath = '.\output\last-report.json',
        [string]$Market,
        [switch]$Public,
        [switch]$DryRun,
        [switch]$OpenBrowser
    )

    $config = Resolve-Config -ConfigPath $ConfigPath
    $resolvedReportPath = Resolve-AbsolutePath -Path $ReportPath -BaseDirectory (Get-Location).Path
    if (-not $Market) {
        $Market = $config.DefaultMarket
    }

    $sourceProvider = [string]$SourceInfo.Provider
    $sourcePlaylistId = $null
    if ($SourceInfo.PSObject.Properties['ProviderPlaylistId']) {
        $sourcePlaylistId = [string]$SourceInfo.ProviderPlaylistId
    }
    $sourcePlaylistName = Get-SourcePlaylistDisplayName -Name ([string]$Playlist.Name) -Provider $sourceProvider -ProviderPlaylistId $sourcePlaylistId
    if ([string]::IsNullOrWhiteSpace($PlaylistName)) {
        $PlaylistName = '{0} (Imported)' -f $sourcePlaylistName
    }

    if (-not (Test-Path -LiteralPath $config.TokenPath)) {
        if ($OpenBrowser) {
            $null = Connect-Spotify -ConfigPath $ConfigPath -OpenBrowser
        }
        else {
            throw ("Missing Spotify token file: {0}. Run .\migrate.ps1 login -OpenBrowser first, or rerun import with -OpenBrowser." -f $config.TokenPath)
        }
    }

    $matched = New-Object System.Collections.Generic.List[object]
    $unmatched = New-Object System.Collections.Generic.List[object]
    $searchCache = Import-SpotifySearchCache -Path $config.SearchCachePath
    Write-Host ('Spotify search cache: {0}' -f $searchCache.Path)

    $trackList = @($Playlist.Tracks)
    $trackCount = $trackList.Count
    $trackIndex = 0
    foreach ($track in $trackList) {
        $trackIndex += 1
        $trackLabel = ('{0} - {1}' -f $track.Title, $track.ArtistText).Trim(' ', '-')
        Write-Progress -Activity 'Matching Spotify tracks' -Status ('{0}/{1} {2}' -f $trackIndex, $trackCount, $trackLabel) -PercentComplete ([int](($trackIndex - 1) * 100 / [Math]::Max(1, $trackCount)))
        Write-Host ('[{0}/{1}] Matching: {2}' -f $trackIndex, $trackCount, $trackLabel)

        try {
            $bestMatch = Find-BestSpotifyMatch -ConfigPath $ConfigPath -Track $track -Market $Market -SearchCache $searchCache -RequestDelayMs $config.RequestDelayMs
        }
        catch {
            throw ('Failed while matching track {0}/{1} "{2}": {3}' -f $trackIndex, $trackCount, $trackLabel, $_.Exception.Message)
        }

        if ($bestMatch) {
            Write-Host ('[{0}/{1}] Matched: {2} -> {3} - {4}' -f $trackIndex, $trackCount, $trackLabel, [string]$bestMatch.Candidate.name, [string]$bestMatch.CandidateArtists)
            $matched.Add([PSCustomObject]@{
                    SourceTitle     = $track.Title
                    SourceArtist    = $track.ArtistText
                    SourceAlbum     = $track.Album
                    Score           = $bestMatch.Score
                    SpotifyTrackId  = [string]$bestMatch.Candidate.id
                    SpotifyTrackUri = [string]$bestMatch.Candidate.uri
                    SpotifyTitle    = [string]$bestMatch.Candidate.name
                    SpotifyArtist   = [string]$bestMatch.CandidateArtists
                    SpotifyAlbum    = [string]$bestMatch.CandidateAlbum
                    SpotifyUrl      = [string]$bestMatch.Candidate.external_urls.spotify
                })
        }
        else {
            Write-Host ('[{0}/{1}] Unmatched: {2}' -f $trackIndex, $trackCount, $trackLabel) -ForegroundColor Yellow
            $unmatched.Add([PSCustomObject]@{
                    SourceTitle  = $track.Title
                    SourceArtist = $track.ArtistText
                    SourceAlbum  = $track.Album
                    Isrc         = $track.Isrc
                })
        }
    }
    Write-Progress -Activity 'Matching Spotify tracks' -Completed
    Save-SpotifySearchCache -SearchCache $searchCache
    Write-Host ('Spotify cache stats: {0} hit(s), {1} miss(es), {2} new cache item(s).' -f $searchCache.Hits, $searchCache.Misses, $searchCache.Writes)

    $sourceReport = [PSCustomObject]@{
        provider     = [string]$SourceInfo.Provider
        playlistName = $sourcePlaylistName
        trackCount   = $trackCount
    }
    if ($SourceInfo.PSObject.Properties['SourcePath']) {
        $sourceReport | Add-Member -NotePropertyName sourcePath -NotePropertyValue ([string]$SourceInfo.SourcePath) -Force
    }
    if ($SourceInfo.PSObject.Properties['SourceLink']) {
        $sourceReport | Add-Member -NotePropertyName sourceLink -NotePropertyValue ([string]$SourceInfo.SourceLink) -Force
    }
    if ($SourceInfo.PSObject.Properties['ProviderPlaylistId']) {
        $sourceReport | Add-Member -NotePropertyName providerPlaylistId -NotePropertyValue ([string]$SourceInfo.ProviderPlaylistId) -Force
    }
    if ($SourceInfo.PSObject.Properties['ExportedFilePath']) {
        $sourceReport | Add-Member -NotePropertyName exportedFilePath -NotePropertyValue ([string]$SourceInfo.ExportedFilePath) -Force
    }
    if ($SourceInfo.PSObject.Properties['Warning'] -and $SourceInfo.Warning) {
        $sourceReport | Add-Member -NotePropertyName warning -NotePropertyValue ([string]$SourceInfo.Warning) -Force
    }

    $report = [PSCustomObject]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = $sourceReport
        target = [PSCustomObject]@{
            playlistName = $PlaylistName
            description  = $Description
            public       = [bool]$Public
            market       = $Market
        }
        spotifySearchCache = [PSCustomObject]@{
            path    = [string]$searchCache.Path
            hits    = [int]$searchCache.Hits
            misses  = [int]$searchCache.Misses
            writes  = [int]$searchCache.Writes
            entries = [int]$searchCache.Entries.Count
        }
        matched   = $matched.ToArray()
        unmatched = $unmatched.ToArray()
    }

    Write-JsonFile -Path $resolvedReportPath -Value $report

    $playlistUrl = $null
    if (-not $DryRun -and $matched.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($Description)) {
            $Description = 'Imported by PlaylistMigrator on ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }

        $createdPlaylist = New-SpotifyPlaylist -ConfigPath $ConfigPath -Name $PlaylistName -Description $Description -Public ([bool]$Public)
        Add-TracksToSpotifyPlaylist -ConfigPath $ConfigPath -PlaylistId ([string]$createdPlaylist.id) -Uris @($matched | ForEach-Object { $_.SpotifyTrackUri })
        $playlistUrl = [string]$createdPlaylist.external_urls.spotify

        $report | Add-Member -NotePropertyName spotifyPlaylistId -NotePropertyValue ([string]$createdPlaylist.id) -Force
        $report | Add-Member -NotePropertyName spotifyPlaylistUrl -NotePropertyValue $playlistUrl -Force
        Write-JsonFile -Path $resolvedReportPath -Value $report
    }

    return [PSCustomObject]@{
        Matched     = $matched.ToArray()
        Unmatched   = $unmatched.ToArray()
        ReportPath  = $resolvedReportPath
        PlaylistUrl = $playlistUrl
        CacheHits   = [int]$searchCache.Hits
        CacheMisses = [int]$searchCache.Misses
        CacheWrites = [int]$searchCache.Writes
    }
}

function Start-PlaylistMigration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('csv', 'generic-json', 'netease-json', 'qqmusic-json')]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [string]$PlaylistName,
        [string]$Description,
        [string]$ReportPath = '.\output\last-report.json',
        [string]$Market,
        [switch]$Public,
        [switch]$DryRun,
        [switch]$OpenBrowser
    )

    $playlist = Import-SourcePlaylist -Provider $Provider -Path $SourcePath
    $resolvedSourcePath = Resolve-AbsolutePath -Path $SourcePath -BaseDirectory (Get-Location).Path

    return Invoke-PlaylistMigrationCore `
        -ConfigPath $ConfigPath `
        -Playlist $playlist `
        -SourceInfo ([PSCustomObject]@{
            Provider   = $Provider
            SourcePath = $resolvedSourcePath
        }) `
        -PlaylistName $PlaylistName `
        -Description $Description `
        -ReportPath $ReportPath `
        -Market $Market `
        -Public:$Public `
        -DryRun:$DryRun `
        -OpenBrowser:$OpenBrowser
}

function Start-PlaylistMigrationFromShareLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$SourceText,

        [string]$OutputPath,
        [string]$PlaylistName,
        [string]$Description,
        [string]$ReportPath = '.\output\last-report.json',
        [string]$Market,
        [switch]$Public,
        [switch]$DryRun,
        [switch]$OpenBrowser
    )

    $export = Export-PlaylistFromShareLink -SourceText $SourceText -OutputPath $OutputPath
    $normalizedPlaylist = Convert-ToNormalizedPlaylist -Playlist $export.Playlist
    $result = Invoke-PlaylistMigrationCore `
        -ConfigPath $ConfigPath `
        -Playlist $normalizedPlaylist `
        -SourceInfo ([PSCustomObject]@{
            Provider          = $export.Provider
            SourceLink        = $export.Playlist.SourceUrl
            ProviderPlaylistId = $export.Playlist.ProviderPlaylistId
            ExportedFilePath  = $export.OutputPath
            Warning           = $export.Warning
        }) `
        -PlaylistName $PlaylistName `
        -Description $Description `
        -ReportPath $ReportPath `
        -Market $Market `
        -Public:$Public `
        -DryRun:$DryRun `
        -OpenBrowser:$OpenBrowser

    return [PSCustomObject]@{
        Matched     = $result.Matched
        Unmatched   = $result.Unmatched
        ReportPath  = $result.ReportPath
        PlaylistUrl = $result.PlaylistUrl
        ExportPath  = $export.OutputPath
        Warning     = $export.Warning
    }
}

Export-ModuleMember -Function Connect-Spotify, Import-SourcePlaylist, Start-PlaylistMigration, Export-PlaylistFromShareLink, Start-PlaylistMigrationFromShareLink
