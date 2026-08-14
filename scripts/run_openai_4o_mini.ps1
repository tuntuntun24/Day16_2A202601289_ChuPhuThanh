[CmdletBinding()]
param(
    [string]$Brief = "pub-01-sla-hien-hanh",
    [switch]$AllBriefs,
    [switch]$NoFlaky,
    [switch]$CheckApi,
    [int]$Seed = 11
)

$ErrorActionPreference = "Stop"
$env:PYTHONUTF8 = "1"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$projectRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $projectRoot ".env"
$python = Join-Path $projectRoot ".venv\Scripts\python.exe"
$runPractice = Join-Path $projectRoot "scripts\run_practice.py"

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Missing .env. Copy .env.example to .env and add OPENAI_API_KEY."
}
if (-not (Test-Path -LiteralPath $python)) {
    throw "Missing .venv. Run: uv venv --python 3.12; uv pip install -r requirements.txt"
}

$settings = @{}
foreach ($rawLine in Get-Content -LiteralPath $envFile -Encoding UTF8) {
    $line = $rawLine.Trim()
    if (-not $line -or $line.StartsWith("#")) {
        continue
    }
    $parts = $line.Split(@("="), 2, [System.StringSplitOptions]::None)
    if ($parts.Count -ne 2) {
        continue
    }
    $name = $parts[0].Trim()
    $value = $parts[1].Trim().Trim('"').Trim("'")
    $settings[$name] = $value
}

$apiKey = [string]$settings["OPENAI_API_KEY"]
$apiKey = ($apiKey -replace "[\x00-\x1F\x7F]", "").Trim()
if (-not $apiKey -or $apiKey -eq "PASTE_YOUR_OPENAI_KEY_HERE") {
    throw "Set OPENAI_API_KEY in .env before running this script."
}

$baseUrl = [string]$settings["OPENAI_BASE_URL"]
if (-not $baseUrl) { $baseUrl = "https://api.openai.com/v1" }
$model = [string]$settings["OPENAI_MODEL"]
if (-not $model) { $model = "gpt-4o-mini" }

$oldApiKey = $env:ARENA_API_KEY
$oldBaseUrl = $env:ARENA_BASE_URL
$oldModel = $env:ARENA_MODEL

try {
    $env:ARENA_API_KEY = $apiKey
    $env:ARENA_BASE_URL = $baseUrl.TrimEnd("/")
    $env:ARENA_MODEL = $model

    $payload = @{
        model = $env:ARENA_MODEL
        messages = @(@{ role = "user"; content = "Reply with exactly OK." })
        temperature = 0
        max_tokens = 16
    } | ConvertTo-Json -Depth 5
    try {
        $reply = Invoke-RestMethod `
            -Uri "$($env:ARENA_BASE_URL)/chat/completions" `
            -Method Post `
            -Headers @{ Authorization = "Bearer $($env:ARENA_API_KEY)" } `
            -ContentType "application/json" `
            -Body $payload
        Write-Host "OpenAI preflight succeeded: $($reply.choices[0].message.content)"
    }
    catch {
        $response = $_.Exception.Response
        $body = ""
        if ($null -ne $response) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        throw "OpenAI preflight failed: $($_.Exception.Message)`n$body"
    }
    if ($CheckApi) { return }

    $arguments = @(
        $runPractice,
        "--model", "real",
        "--layers", "all",
        "--prompt-addendum",
        "--seed", $Seed,
        "--out", "runs/openai-4o-mini.json"
    )
    if (-not $AllBriefs) {
        $arguments += @("--brief", $Brief)
    }
    if ($NoFlaky) {
        $arguments += "--no-flaky"
    }

    Push-Location $projectRoot
    try {
        & $python @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Agent Arena exited with code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $oldApiKey) { Remove-Item Env:ARENA_API_KEY -ErrorAction SilentlyContinue }
    else { $env:ARENA_API_KEY = $oldApiKey }
    if ($null -eq $oldBaseUrl) { Remove-Item Env:ARENA_BASE_URL -ErrorAction SilentlyContinue }
    else { $env:ARENA_BASE_URL = $oldBaseUrl }
    if ($null -eq $oldModel) { Remove-Item Env:ARENA_MODEL -ErrorAction SilentlyContinue }
    else { $env:ARENA_MODEL = $oldModel }
}
