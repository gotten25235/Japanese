param(
    [string]$OutJson = "vocab.json",
    [string]$OutJs = "vocab-data.js",
    [string]$ZhCache = "vocab-zh-cache.json",
    [switch]$SkipZhTranslation
)

$ErrorActionPreference = "Stop"

$script:UserAgent = "Mozilla/5.0 (compatible; JapaneseStudyAppVocabScraper/1.0)"

$sources = @(
    @{ Level = "N5"; Url = "https://jlptsensei.com/jlpt-n5-vocabulary-list/" },
    @{ Level = "N4"; Url = "https://jlptsensei.com/jlpt-n4-vocabulary-list/" },
    @{ Level = "N3"; Url = "https://jlptsensei.com/jlpt-n3-vocabulary-list/" }
)

function Get-PageHtml {
    param([string]$Url)

    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Add("User-Agent", $script:UserAgent)
        $bytes = $client.DownloadData($Url)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    finally {
        $client.Dispose()
    }
}

function Get-JsonFromUrl {
    param([string]$Url)

    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Add("User-Agent", $script:UserAgent)
        $bytes = $client.DownloadData($Url)
        $json = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $json | ConvertFrom-Json
    }
    finally {
        $client.Dispose()
    }
}

function Load-ZhCache {
    param([string]$Path)

    $fullPath = Join-Path (Get-Location) $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return @{}
    }

    $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $fullPath
    if (-not $raw.Trim()) {
        return @{}
    }

    $object = $raw | ConvertFrom-Json
    $cache = @{}
    foreach ($property in $object.PSObject.Properties) {
        $cache[$property.Name] = [string]$property.Value
    }
    return $cache
}

function Save-ZhCache {
    param(
        [hashtable]$Cache,
        [string]$Path
    )

    $ordered = [ordered]@{}
    foreach ($key in ($Cache.Keys | Sort-Object)) {
        $ordered[$key] = $Cache[$key]
    }
    $json = $ordered | ConvertTo-Json -Depth 4
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) $Path), $json, $utf8NoBom)
}

function Translate-ToTraditionalChinese {
    param([string]$Text)

    if (-not $Text) {
        return ""
    }

    $encoded = [System.Uri]::EscapeDataString($Text)
    $url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh-TW&dt=t&q=$encoded"
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $response = Get-JsonFromUrl -Url $url
            return [string]$response[0][0][0]
        } catch {
            if ($attempt -eq 4) {
                Write-Warning "Failed zh translation after retries: $Text"
                return $Text
            }
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
}

function Add-ZhTranslations {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [string]$CachePath
    )

    $cache = Load-ZhCache -Path $CachePath
    $total = $Items.Count
    $index = 0
    $changed = $false

    foreach ($item in $Items) {
        $index++
        $english = [string]$item.meaning
        if (-not $english) {
            $zh = ""
        } elseif ($cache.ContainsKey($english)) {
            $zh = $cache[$english]
        } else {
            Write-Host "Translating zh $index/${total}: $english"
            $zh = Translate-ToTraditionalChinese -Text $english
            $cache[$english] = $zh
            $changed = $true
            if (($index % 10) -eq 0) {
                Save-ZhCache -Cache $cache -Path $CachePath
            }
            Start-Sleep -Milliseconds 80
        }

        if ($item.PSObject.Properties.Name -contains "zh") {
            $item.zh = $zh
        } else {
            $item | Add-Member -NotePropertyName "zh" -NotePropertyValue $zh
        }
    }

    if ($changed) {
        Save-ZhCache -Cache $cache -Path $CachePath
    }
}

function ConvertTo-CleanText {
    param([string]$Html)

    $text = $Html -replace '(?i)<br\s*/?>', "`n"
    $text = $text -replace '(?i)</p\s*>', "`n"
    $text = $text -replace '(?i)</div\s*>', "`n"
    $text = $text -replace '(?i)</li\s*>', "`n"
    $text = $text -replace '(?s)<script.*?</script>', ''
    $text = $text -replace '(?s)<style.*?</style>', ''
    $text = $text -replace '<[^>]+>', ''
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $lines = $text -split "`n" | ForEach-Object {
        ($_ -replace '\s+', ' ').Trim()
    } | Where-Object { $_ }
    return ($lines -join "`n").Trim()
}

function Split-ReadingCell {
    param(
        [string]$Reading,
        [string]$Japanese
    )

    $parts = @($Reading -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $romaji = if ($parts.Count -gt 0) { $parts[0] } else { "" }
    $kana = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    if (-not $kana -and $romaji -match '^([A-Za-z\-\s''\./]+)([\u3040-\u30ff\u3400-\u9fff].*)$') {
        $romaji = $Matches[1].Trim()
        $kana = $Matches[2].Trim()
    }

    if (-not $kana) {
        $kana = $Japanese
    }

    return @{ Romaji = $romaji; Kana = $kana }
}

function Parse-VocabRows {
    param(
        [string]$Html,
        [string]$Level
    )

    $items = New-Object System.Collections.Generic.List[object]
    $rowMatches = [regex]::Matches($Html, '(?is)<tr\s+class="?jl-row"?[^>]*>.*?(?=<tr\s+class="?jl-row"?|</table>)')

    foreach ($rowMatch in $rowMatches) {
        $rowHtml = $rowMatch.Value

        $numMatch = [regex]::Match($rowHtml, '(?is)jl-td-num[^>]*>\s*(\d+)')
        $jpMatch = [regex]::Match($rowHtml, '(?is)jl-td-v\s[^>]*>.*?<a[^>]*>(.*?)</a>')
        $readingCellMatch = [regex]::Match($rowHtml, '(?is)jl-td-vr\s[^>]*>(.*?)(?=<td\b|<tr\b|</table>)')
        $typeMatch = [regex]::Match($rowHtml, '(?is)jl-td-v-type[^>]*>(.*?)(?=<td\b|<tr\b|</table>)')
        $meaningMatch = [regex]::Match($rowHtml, '(?is)jl-td-vm[^>]*>(.*?)$')

        if (-not ($numMatch.Success -and $jpMatch.Success -and $readingCellMatch.Success -and $typeMatch.Success -and $meaningMatch.Success)) {
            continue
        }

        $jp = ConvertTo-CleanText $jpMatch.Groups[1].Value
        $readingText = ConvertTo-CleanText $readingCellMatch.Groups[1].Value
        $reading = Split-ReadingCell -Reading $readingText -Japanese $jp
        $item = [ordered]@{
            id = [int]$numMatch.Groups[1].Value
            level = $Level
            jp = $jp
            kana = $reading.Kana
            romaji = $reading.Romaji
            type = (ConvertTo-CleanText $typeMatch.Groups[1].Value)
            meaning = (ConvertTo-CleanText $meaningMatch.Groups[1].Value)
        }
        $items.Add([pscustomobject]$item)
    }

    return $items
}

function Get-PageUrls {
    param(
        [string]$FirstUrl,
        [string]$FirstHtml
    )

    $pageCount = 1
    $pageMatch = [regex]::Match($FirstHtml, 'Currently viewing page\s+\d+\s+of\s+(\d+)', 'IgnoreCase')
    if ($pageMatch.Success) {
        $pageCount = [int]$pageMatch.Groups[1].Value
    }

    $urls = @($FirstUrl)
    $base = $FirstUrl.TrimEnd('/')
    for ($i = 2; $i -le $pageCount; $i++) {
        $urls += "$base/page/$i/"
    }
    return $urls
}

$all = New-Object System.Collections.Generic.List[object]

foreach ($source in $sources) {
    Write-Host "Fetching $($source.Level): $($source.Url)"
    $firstHtml = Get-PageHtml -Url $source.Url
    $pageUrls = Get-PageUrls -FirstUrl $source.Url -FirstHtml $firstHtml
    $levelRows = New-Object System.Collections.Generic.List[object]

    for ($pageIndex = 0; $pageIndex -lt $pageUrls.Count; $pageIndex++) {
        $pageUrl = $pageUrls[$pageIndex]
        $html = if ($pageIndex -eq 0) {
            $firstHtml
        } else {
            Start-Sleep -Milliseconds 250
            Get-PageHtml -Url $pageUrl
        }

        $rows = Parse-VocabRows -Html $html -Level $source.Level
        if ($rows.Count -eq 0) {
            throw "No vocabulary rows parsed for $($source.Level) page $($pageIndex + 1). Source HTML may have changed."
        }
        foreach ($row in $rows) {
            $levelRows.Add($row)
            $all.Add($row)
        }
    }
    Write-Host "Parsed $($levelRows.Count) rows for $($source.Level)"
}

if (-not $SkipZhTranslation) {
    Add-ZhTranslations -Items $all -CachePath $ZhCache
}

$sourceName = if ($SkipZhTranslation) { "JLPTsensei Vocabulary Lists" } else { "JLPTsensei Vocabulary Lists + Google Translate zh-TW" }
$payload = [ordered]@{
    source = [ordered]@{
        name = $sourceName
        url = "https://jlptsensei.com/"
        fetchedAt = (Get-Date).ToString("s")
    }
    vocabulary = $all
}

$json = $payload | ConvertTo-Json -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $OutJson), $json, $utf8NoBom)

$sourceJson = $payload.source | ConvertTo-Json -Compress
$vocabJson = $all | ConvertTo-Json -Depth 8 -Compress
$js = @"
window.VOCAB_SOURCE = $sourceJson;
window.VOCAB_DB = $vocabJson;
"@
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $OutJs), $js, $utf8NoBom)

Write-Host "Wrote $OutJson and $OutJs with $($all.Count) vocabulary entries."
