# ============================================================================
# Migrate-Relink.ps1 — rewrite source URLs and photo slugs in article content
# ============================================================================

function Invoke-RelinkArticles {
    param([hashtable]$ArticleMap)

    Write-Log "========== STEP 4: RELINKING INTERNAL URLS =========="

    $updated = 0
    $failed  = 0

    foreach ($entry in $ArticleMap.Values) {
        Use-SourceHudu
        try {
            $raw        = Get-HuduArticles -Id $entry.SourceId
            $srcArticle = $raw.article ?? $raw
        } catch {
            Write-Log "Could not fetch source article ID $($entry.SourceId): $_" "ERROR"
            $failed++
            continue
        }

        $html = $srcArticle.content
        if (-not $html) { continue }

        # Replace cross-article source URLs with their target equivalents
        foreach ($map in $ArticleMap.Values) {
            if (-not $map.TargetUrl) { continue }
            $pattern = [regex]::Escape($script:SourceHuduUrl) + '[^"''<>\s]*' + [regex]::Escape($map.SourceId.ToString())
            $html    = [regex]::Replace($html, $pattern, $map.TargetUrl, 'IgnoreCase')
        }

        # Apply public photo slug remappings built during article migration
        if ($entry.PhotoMap -and $entry.PhotoMap.Count -gt 0) {
            foreach ($oldPath in $entry.PhotoMap.Keys) {
                $html = $html -replace ([regex]::Escape($oldPath)), $entry.PhotoMap[$oldPath]
            }
        }

        # Swap any remaining source base-URL references (links, iframes, etc.)
        $html = $html -replace [regex]::Escape($script:SourceHuduUrl), $script:TargetHuduUrl

        if ($html -ne $srcArticle.content) {
            Use-TargetHudu
            try {
                Set-HuduArticle -ArticleId $entry.TargetId -Name $entry.Name -Content $html | Out-Null
                $updated++
                Write-Log "Relinked '$($entry.Name)'" "SUCCESS"
            } catch {
                Write-Log "Relink update failed for '$($entry.Name)': $_" "ERROR"
                $failed++
            }
        }
    }

    Write-Log "Relinking - Updated: $updated | Failed: $failed"
    return [PSCustomObject]@{ Updated = $updated; Failed = $failed }
}
