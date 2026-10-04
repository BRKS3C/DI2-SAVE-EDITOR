@echo off
setlocal
title Dead Island 2 - Gestor de armas (di2save)
set "BATDIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $s = Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8; $i = $s.IndexOf('#PS_'+'START_MARK'); Invoke-Expression $s.Substring($i)"
echo.
pause
exit /b
#PS_START_MARK
# =====================================================================
#  Dead Island 2 - Gestor de armas / inventario
#  Requiere di2save.exe (steffenl) en la misma carpeta que este .bat
#  (o en una subcarpeta). Cierra el juego antes de usarlo.
#
#  NOTA: todas las invocaciones a di2save pasan por Invoke-DI2 y se
#  ejecutan siempre con --no-version-safety, tal como pide este gestor.
# =====================================================================
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Base    = $env:BATDIR.TrimEnd('\')
$CfgFile = Join-Path $Base 'di2_config.json'

$script:Exe = $null
$script:Save = $null
$script:Prof = $null
$script:ProfLabel = ''
$script:NoVS = $true
$script:Items = $null
$script:UIMap = @{}
$script:Upgrades = $null
$script:LastOk = $true

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Pausa {
    Write-Host ''
    Write-Host 'Pulsa una tecla para volver al menu...' -ForegroundColor DarkGray
    try {
        # Lee directo del buffer de consola (no depende de stdin, que a veces
        # queda en un estado raro tras Clear-Host y hace que Read-Host
        # devuelva vacio inmediatamente).
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        # Fallback por si el host no soporta RawUI (p.ej. redirigido).
        try { [void](Read-Host) } catch { Start-Sleep -Seconds 3 }
    }
    Write-Host ''
}

# ---------------- Configuracion ----------------
function Load-Cfg {
    if (Test-Path -LiteralPath $CfgFile) {
        try {
            $c = Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json
            $script:Exe = $c.Exe
            $script:Save = $c.Save
        } catch {}
    }
}
function Save-Cfg {
    @{ Exe = $script:Exe; Save = $script:Save } | ConvertTo-Json | Set-Content -LiteralPath $CfgFile -Encoding UTF8
}

function Find-Exe {
    if ($script:Exe -and (Test-Path -LiteralPath $script:Exe)) { return }
    $f = Get-ChildItem -LiteralPath $Base -Recurse -Filter 'di2save.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) {
        $script:Exe = $f.FullName
    } else {
        while ($true) {
            $p = (Read-Host 'No encuentro di2save.exe. Pega la ruta completa del .exe o de su carpeta').Trim('"', ' ')
            if (Test-Path -LiteralPath $p -PathType Container) { $p = Join-Path $p 'di2save.exe' }
            if (Test-Path -LiteralPath $p -PathType Leaf) { $script:Exe = $p; break }
            Say 'Ruta no valida.' Red
        }
    }
    Save-Cfg
}

function Find-Save {
    if ($script:Save -and (Test-Path -LiteralPath $script:Save)) { return }
    $cand = @()
    $steam = Join-Path $env:LOCALAPPDATA 'DeadIslandSteam\Saved\SaveGames\DeadIsland2SaveGame.sav'
    $epic  = Join-Path $env:LOCALAPPDATA 'DeadIsland\Saved\SaveGames\DeadIsland2SaveGame.sav'
    if (Test-Path -LiteralPath $steam) { $cand += $steam }
    if (Test-Path -LiteralPath $epic)  { $cand += $epic }
    if ($cand.Count -eq 1) {
        $script:Save = $cand[0]
    } elseif ($cand.Count -gt 1) {
        Say 'He encontrado varios guardados:' Cyan
        for ($i = 0; $i -lt $cand.Count; $i++) { Say ("  {0}. {1}" -f ($i + 1), $cand[$i]) }
        $r = Read-Host 'Cual usas?'
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $cand.Count) { $script:Save = $cand[[int]$r - 1] } else { $script:Save = $cand[0] }
    } else {
        while ($true) {
            $p = (Read-Host 'No encuentro el guardado. Pega la ruta completa de DeadIsland2SaveGame.sav').Trim('"', ' ')
            if (Test-Path -LiteralPath $p -PathType Leaf) { $script:Save = $p; break }
            Say 'Ruta no valida.' Red
        }
    }
    Save-Cfg
}

# ---------------- Ejecutar di2save ----------------
function Invoke-DI2 {
    param([string[]]$A)

    $all = @($A)
    if (-not ($all -contains '--no-version-safety')) {
        $all += '--no-version-safety'
    }

    $out = @(& $script:Exe @all 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $txt = ($out -join "`n")
    $script:LastOk = ($code -eq 0) -and ($txt -notmatch '(?im)^\s*(Exception|Error)')
    return $out
}

function Invoke-DI2-Help {
    # Igual que Invoke-DI2 pero SIN --no-version-safety, porque el
    # comando 'help' no lo acepta.
    param([string[]]$A)

    $out = @(& $script:Exe @A 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $txt = ($out -join "`n")
    $script:LastOk = ($code -eq 0) -and ($txt -notmatch '(?im)^\s*(Exception|Error)')
    return $out
}

function Get-CommonArgs {
    $a = @('--file', $script:Save)
    if ($script:Prof) { $a += @('--profile', $script:Prof) }
    return $a
}



# ---------------- Listas de items / mejoras ----------------
function Load-Items {
    if ($script:Items) { return }

    Say 'Cargando base de armas/items...' DarkGray
    $list = New-Object 'System.Collections.Generic.List[object]'
    $map = @{}

    function Add-ItemRecord($ui, $name) {
        if (-not $name) { return }
        $name = "$name".Trim()
        if ($name -notmatch '^DA_[A-Za-z0-9_]+$') { return }

        $ui = if ($ui) { "$ui".Trim() } else { $name }
        $ui = $ui -replace '^[\s|\u2502]*', ''
        $ui = $ui -replace '[\s|\u2502]+$', ''

        if ($map.ContainsKey($name)) { return }
        $obj = [pscustomobject]@{ Name = $name; UI = $ui }
        [void]$list.Add($obj)
        $map[$name] = $ui
    }

    # ------------------------------------------------------------------
    # 1) Cargar items.csv (armas normales + DLC conocidos por la base)
    # ------------------------------------------------------------------
    $csvs = @()
    if ($script:Exe) {
        $exeDir = [System.IO.Path]::GetDirectoryName($script:Exe)
        if ($exeDir) {
            $csvs += @(Get-ChildItem -LiteralPath $exeDir -Recurse -Filter 'items.csv' -File -ErrorAction SilentlyContinue)
        }
    }
    $csvs += @(Get-ChildItem -LiteralPath $Base -Recurse -Filter 'items.csv' -File -ErrorAction SilentlyContinue)

    foreach ($csv in ($csvs | Sort-Object FullName -Unique)) {
        try {
            foreach ($row in (Import-Csv -LiteralPath $csv.FullName)) {
                $props = @($row.PSObject.Properties.Name)
                $nameCol = @($props | Where-Object {
                    $n = ($_ -replace '[\s_\-]', '').ToLowerInvariant()
                    $n -in @('name','internalname','itemname')
                } | Select-Object -First 1)
                $uiCol = @($props | Where-Object {
                    $n = ($_ -replace '[\s_\-]', '').ToLowerInvariant()
                    $n -in @('uiname','nameui','displayname','uitem','uiname')
                } | Select-Object -First 1)

                if ($nameCol.Count -gt 0) {
                    $name = "$($row.($nameCol[0]))"
                    $ui = if ($uiCol.Count -gt 0) { "$($row.($uiCol[0]))" } else { $name }
                    Add-ItemRecord $ui $name
                }
            }
        } catch {
            continue
        }
        if ($list.Count -gt 0) { break }
    }

    $csvCount = $list.Count

    # ------------------------------------------------------------------
    # 2) COMPLEMENTAR con di2save (incluye items internos, debug y AI)
    # ------------------------------------------------------------------
    $variantes = @(
        @('help','inventory','items','--include-dlc','--include-ai','--include-internal'),
        @('help','inventory','items','--include-dlc','--include-ai'),
        @('help','inventory','items','--include-internal'),
        @('help','inventory','items')
    )

    $out = @()
    foreach ($v in $variantes) {
        $tmp = @(Invoke-DI2-Help $v)
        if ($tmp.Count -gt 0 -and $script:LastOk) {
            $out = $tmp
            break
        }
    }

    foreach ($l in $out) {
        $line = "$l"
        $matches2 = [regex]::Matches($line, '(?i)(DA_[A-Za-z0-9_]+)')
        foreach ($m in $matches2) {
            $name = $m.Value
            $ui = $line.Substring(0, $m.Index)
            $ui = ($ui -replace '[|\u2502]', ' ').Trim()
            Add-ItemRecord $ui $name
        }
    }

    # ------------------------------------------------------------------
    # 3) Ultimo recurso: leer del guardado si no hay nada de lo anterior
    # ------------------------------------------------------------------
    if ($list.Count -eq 0 -and $script:Save -and (Test-Path -LiteralPath $script:Save)) {
        try {
            $raw = @(Invoke-DI2 @('player', 'inventory', 'ls') + (Get-CommonArgs))
            foreach ($l in $raw) {
                $m = [regex]::Match("$l", '(?i)DA_[A-Za-z0-9_]+')
                if ($m.Success) {
                    Add-ItemRecord $m.Value $m.Value
                }
            }
        } catch {}
    }

    $script:Items = @($list | Sort-Object UI, Name)
    $script:UIMap = $map

    if ($script:Items.Count -eq 0) {
        Say 'No pude cargar la base de items. Comprueba que di2save.exe y su carpeta data esten instalados.' Red
    } else {
        $extra = $script:Items.Count - $csvCount
        Say "Items disponibles: $($script:Items.Count)  ($csvCount de items.csv + $extra de di2save)" DarkGray
    }
}

function Load-Upgrades {
    if ($script:Upgrades) { return }

    Say 'Cargando base de mejoras...' DarkGray
    $set = New-Object 'System.Collections.Generic.List[string]'

    function Add-UpgradeName($name) {
        if (-not $name) { return }
        $n = "$name".Trim()
        if ($n -match '^DA_[A-Za-z0-9_]+$' -and -not $set.Contains($n)) {
            $set.Add($n)
        }
    }

    $csvs = @()
    if ($script:Exe) {
        $exeDir = [System.IO.Path]::GetDirectoryName($script:Exe)
        if ($exeDir) {
            $csvs += @(Get-ChildItem -LiteralPath $exeDir -Recurse -Filter 'weapon_upgrades.csv' -File -ErrorAction SilentlyContinue)
        }
    }
    $csvs += @(Get-ChildItem -LiteralPath $Base -Recurse -Filter 'weapon_upgrades.csv' -File -ErrorAction SilentlyContinue)

    foreach ($csv in ($csvs | Sort-Object FullName -Unique)) {
        try {
            foreach ($row in (Import-Csv -LiteralPath $csv.FullName)) {
                $props = @($row.PSObject.Properties.Name)
                $nameCol = @($props | Where-Object { ($_ -replace '\s', '').ToLowerInvariant() -eq 'name' } | Select-Object -First 1)
                if ($nameCol.Count -gt 0) {
                    Add-UpgradeName $row.($nameCol[0])
                }
            }
        } catch {
            continue
        }
        if ($set.Count -gt 0) { break }
    }

    if ($set.Count -eq 0) {
        $out = @(Invoke-DI2 @('help', 'inventory', 'upgrades'))
        foreach ($l in $out) {
            foreach ($m in [regex]::Matches("$l", '(?i)DA_[A-Za-z0-9_]+')) {
                Add-UpgradeName $m.Value
            }
        }
    }

    $script:Upgrades = @($set | Sort-Object)
    Say "Mejoras detectadas: $($script:Upgrades.Count)" DarkGray
}

function Normalize-SearchText($text) {
    if ($null -eq $text) { return '' }

    $s = "$text".Trim().ToLowerInvariant()
    $s = $s.Normalize([Text.NormalizationForm]::FormD)
    $s = [regex]::Replace($s, '\p{Mn}', '')
    $s = $s -replace '[_\-.]+', ' '
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

function Search-Items($pool, $text) {
    $pool = @($pool)
    $q = Normalize-SearchText $text

    if (-not $q) { return @($pool) }

    $words = @($q -split ' ' | Where-Object { $_ })
    $prefixMatches = @()
    $containsMatches = @()

    foreach ($it in $pool) {
        $ui = Normalize-SearchText $it.UI
        $name = Normalize-SearchText $it.Name
        $id = Normalize-SearchText $it.ID

        # Quitamos el prefijo tecnico para poder buscar "katana" por el
        # nombre interno aunque el UI Name no este disponible.
        $shortName = $name -replace '^da (melee|ranged) weapon archetype ', ''
        $haystack = "$ui $name $shortName $id"

        $ok = $true
        foreach ($w in $words) {
            if (-not $haystack.Contains($w)) {
                $ok = $false
                break
            }
        }

        if ($ok) {
            # Una sola letra significa "empieza por esta letra" cuando hay
            # coincidencia al principio del nombre visible o tecnico corto.
            if (
                $q.Length -eq 1 -and
                ($ui.StartsWith($q) -or $shortName.StartsWith($q))
            ) {
                $prefixMatches += $it
            } else {
                $containsMatches += $it
            }
        }
    }

    return @($prefixMatches + $containsMatches)
}
# ---------------- Personajes ----------------
function Get-Profiles {
    $out = @(Invoke-DI2 @('player', 'profile', 'ls', '--file', $script:Save))
    $profs = @()
    $cur = $null

    foreach ($l in $out) {
        if ($l -match '^\s*-\s*ID:\s*([0-9a-fA-F]+)') {
            if ($cur) { $profs += $cur }
            $cur = [pscustomobject]@{
                ID = $matches[1]
                Active = $false
                NG = ''
                Arch = ''
                Level = ''
            }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s*Active:\s*(\w+)') { $cur.Active = ($matches[1] -eq 'true') }
        elseif ($l -match '^\s*NewGamePlus:\s*(\w+)') { $cur.NG = $matches[1] }
        elseif ($l -match '^\s*KeyArchetype:\s*(.+)$') { $cur.Arch = $matches[1].Trim() }
        elseif ($l -match '^\s*KeyProgression:\s*(.+)$') { $cur.Level = $matches[1].Trim() }
    }

    if ($cur) { $profs += $cur }
    return $profs
}

function Select-Profile {
    $p = @(Get-Profiles)
    if ($p.Count -eq 0) {
        Say 'No pude leer los personajes del guardado (se usara el activo por defecto).' Yellow
        $script:Prof = $null
        $script:ProfLabel = 'activo'
        return
    }

    Say ''
    Say 'Personajes en el guardado:' Cyan
    $def = 1

    for ($i = 0; $i -lt $p.Count; $i++) {
        $x = $p[$i]
        $t = "{0}. ID {1}" -f ($i + 1), $x.ID
        if ($x.Arch)  { $t += " | $($x.Arch)" }
        if ($x.Level) { $t += " | nivel $($x.Level)" }
        if ($x.NG -eq 'true') { $t += ' | NG+' }
        if ($x.Active) { $t += ' | ACTIVO'; $def = $i + 1 }
        Say "  $t"
    }

    $r = Read-Host "Elige personaje [$def]"
    $n = $def
    if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $p.Count) { $n = [int]$r }

    $sel = $p[$n - 1]
    $script:Prof = $sel.ID
    $lbl = $sel.ID.Substring(0, [Math]::Min(8, $sel.ID.Length))
    if ($sel.Arch) { $lbl = "$($sel.Arch) ($lbl)" }
    $script:ProfLabel = $lbl
}

function Get-CurrentProfile {
    $p = @(Get-Profiles)
    if ($script:Prof) {
        $x = @($p | Where-Object { $_.ID -eq $script:Prof } | Select-Object -First 1)
        if ($x.Count -gt 0) { return $x[0] }
    }
    $x = @($p | Where-Object { $_.Active } | Select-Object -First 1)
    if ($x.Count -gt 0) { return $x[0] }
    if ($p.Count -gt 0) { return $p[0] }
    return $null
}

# ---------------- Inventario ----------------
function Get-Inventory {
    Load-Items
    $out = @(Invoke-DI2 (@('player', 'inventory', 'ls') + (Get-CommonArgs)))
    $items = @()
    $cat = '?'
    $cur = $null

    foreach ($l in $out) {
        if ($l -match '^(\S[^:]*):\s*$') {
            if ($cur) { $items += $cur; $cur = $null }
            $cat = $matches[1]
            continue
        }

        if ($l -match '^\s*-\s*EntryID:\s*(\w+)') {
            if ($cur) { $items += $cur }
            $cur = [pscustomobject]@{
                Cat = $cat
                ID = $matches[1]
                Name = ''
                UI = ''
                Count = ''
                Rarity = ''
                Level = ''
                Ups = ''
                UpList = @()
            }
            continue
        }

        if (-not $cur) { continue }

        if ($l -match '^\s*Archetype:\s*(\S+)') {
            $a = $matches[1]
            $n = $a.Substring($a.LastIndexOf('.') + 1)
            $cur.Name = $n
            if ($script:UIMap.ContainsKey($n)) { $cur.UI = $script:UIMap[$n] }
        }
        elseif ($l -match '^\s*Count:\s*(\d+)') { $cur.Count = $matches[1] }
        elseif ($l -match '(?i)^\s*Required\s*Rarity:\s*(?:EItemRarity::)?(\w+)') { $cur.Rarity = $matches[1] }
        elseif ($l -match '(?i)^\s*Required\s*Level:\s*(\d+)') { $cur.Level = $matches[1] }
        elseif ($l -match '^\s*NumUpgrades:\s*(\d+)') { $cur.Ups = $matches[1] }
        elseif ($l -match '^\s*UpgradeEntry\d+:\s*(.+)$') {
            $u = $matches[1].Trim()
            $u = $u.Substring($u.LastIndexOf('.') + 1).Trim()
            if ($u) { $cur.UpList += $u }
        }
    }

    if ($cur) { $items += $cur }

    if ($items.Count -eq 0 -and $out.Count -gt 0) {
        Say 'No pude interpretar el inventario. Salida cruda de di2save:' Yellow
        $out | ForEach-Object { Say $_ }
    }

    return $items
}

function Show-Inv($list) {
    $i = 0
    foreach ($it in $list) {
        $i++
        $d = if ($it.UI) { $it.UI } else { $it.Name }
        $parts = @($it.Cat)
        if ($it.Rarity) { $parts += $it.Rarity }
        if ($it.Level)  { $parts += "Nv $($it.Level)" }
        if ($it.Ups)    { $parts += "$($it.Ups) mejoras" }
        if ($it.Count)  { $parts += "x$($it.Count)" }
        $parts += "ID $($it.ID)"
        Say ("{0,3}. {1}" -f $i, $d) White
        Say ("       " + ($parts -join ' | ')) DarkGray
    }
}

function Show-Inv-Paged($list, [int]$pageSize = 100) {
    $list = @($list)
    $total = $list.Count
    if ($total -eq 0) { return }

    $totalPages = [Math]::Ceiling($total / $pageSize)
    $page = 0

    while ($true) {
        Clear-Host
        $start = $page * $pageSize
        $end   = [Math]::Min($start + $pageSize, $total) - 1

        Say ("Mostrando items {0}-{1} de {2}   (pagina {3}/{4})" -f `
             ($start + 1), ($end + 1), $total, ($page + 1), $totalPages) Cyan
        Say ''

        for ($i = $start; $i -le $end; $i++) {
            $it = $list[$i]
            $num = $i + 1
            $d = if ($it.UI) { $it.UI } else { $it.Name }

            $parts = @()
            if ($it.Cat)    { $parts += $it.Cat }
            if ($it.Rarity) { $parts += $it.Rarity }
            if ($it.Level)  { $parts += "Nv $($it.Level)" }
            if ($it.Ups)    { $parts += "$($it.Ups) mejoras" }
            if ($it.Count)  { $parts += "x$($it.Count)" }
            if ($it.ID)     { $parts += "ID $($it.ID)" }

            Say ("{0,5}. {1}" -f $num, $d) White
            if ($parts.Count -gt 0) {
                Say ("        " + ($parts -join ' | ')) DarkGray
            }
        }

        Say ''
        Say '[N] siguiente pagina   [P] anterior   [I] ir a pagina   [Q] terminar de ver   [Enter] siguiente' DarkGray
        $cmd = (Read-Host 'Comando').Trim()

        if ($cmd -match '^[qQ]$') { break }
        if ($cmd -match '^[pP]$') {
            if ($page -gt 0) { $page-- } else { Say 'Ya estas en la primera pagina.' Yellow; Start-Sleep -Milliseconds 800 }
        } elseif ($cmd -match '^[iI]$') {
            $p = Read-Host "Ir a pagina (1-$totalPages)"
            if ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $totalPages) {
                $page = [int]$p - 1
            }
        } elseif (-not $cmd -or $cmd -match '^[nN]$') {
            if ($page -lt $totalPages - 1) { $page++ } else { break }
        } else {
            break
        }
    }
}

function Is-MeleeWeapon($it) {
    # Detecta armas melee normales, de IA, o las manos
    return ($it.Name -match '^DA_MeleeWeaponArchetype_') -or ($it.Name -match '^DA_MeleeWeaponArchetype_AI_') -or ($it.Name -eq 'DA_MeleeWeaponArchetype_BareHands')
}

function Is-RangedWeapon($it) {
    return ($it.Name -match '^DA_RangedWeaponArchetype_')
}

function Is-Weapon($it) {
    return (Is-MeleeWeapon $it) -or (Is-RangedWeapon $it) -or ($it.Cat -eq 'Weapons')
}

function Search-WeaponPool([string]$kind, [string]$query, [string]$container = 'inventario') {
    $pool = @(Get-WeaponPool $kind $container)
    if ($query) {
        return @(Search-Items $pool $query)
    }
    return @($pool)
}


function Get-WeaponPool([string]$kind, [string]$container = 'inventario') {
    if ($container -eq 'alijo') {
        $inv = @(Get-Stash)
    } else {
        $inv = @(Get-Inventory)
    }
    switch ($kind) {
        'melee'  { return @($inv | Where-Object { Is-MeleeWeapon $_ }) }
        'ranged' { return @($inv | Where-Object { Is-RangedWeapon $_ }) }
        'todo'   { return @($inv) }
        default  { return @($inv | Where-Object { Is-Weapon $_ }) }
    }
}

function Ask-WeaponCategory {
    Say '1. Armas a melee'
    Say '2. Armas a distancia / largas'
    Say '3. Todas las armas'
    Say '4. TODOS los items (medicinas, curveballs, ingredientes, etc.)'
    $r = (Read-Host 'Categoria').Trim()
    switch ($r) {
        '1' { return 'melee' }
        '2' { return 'ranged' }
        '3' { return 'all' }
        '4' { return 'todo' }
        default { return $null }
    }
}

function Ver-Inventario {
    $inv = @(Get-Inventory)
    if ($inv.Count -eq 0) { Say 'Inventario vacio o no legible.' Yellow; return }

    $w = Read-Host 'Mostrar solo armas? (S/N) [S]'
    if ($w -notmatch '^[nN]') {
        $inv = @($inv | Where-Object { Is-Weapon $_ -or $_.Cat -eq 'Weapons' })
    }

    $f = Read-Host 'Filtrar por nombre (vacio = todo)'
    if ($f) { $inv = @(Search-Items $inv $f) }

    Say ''
    Say "Inventario de $($script:ProfLabel) - $($inv.Count) entradas" Cyan
    Show-Inv $inv
}

# ---------------- Seleccion multiple ----------------
function Select-Multiple($pool, [string]$prompt = 'Seleccion') {
    $pool = @($pool)
    if ($pool.Count -eq 0) { return @() }

    $s = (Read-Host "$prompt (1,2,3 / T=todas / 0=cancelar)").Trim()
    if (-not $s -or $s -eq '0') { return @() }
    if ($s -match '^[tT]$') { return @($pool) }

    $chosen = @()
    $seenIdx = @{}

    foreach ($t in ($s -split '[,; ]+')) {
        $t = $t.Trim()
        if ($t -match '^\d+$') {
            $n = [int]$t
            if ($n -ge 1 -and $n -le $pool.Count) {
                if (-not $seenIdx.ContainsKey($n)) {
                    $seenIdx[$n] = $true
                    $chosen += $pool[$n - 1]
                }
            }
        }
    }

    return @($chosen)
}

function Show-Selection($chosen) {
    if (-not $chosen -or $chosen.Count -eq 0) { return }
    Say ''
    Say "Seleccionados: $($chosen.Count)" Cyan
    Show-Inv $chosen
}

# ---------------- Anadir armas ----------------
function Ask-Rarity {
    $r = Read-Host 'Rareza (common/uncommon/rare/superior/legendary) [legendary]'
    if (-not $r) { return 'legendary' }
    $r = $r.ToLower().Trim()
    if (@('common', 'uncommon', 'rare', 'superior', 'legendary') -contains $r) { return $r }
    Say 'Rareza no valida, uso legendary.' Yellow
    return 'legendary'
}

function Ask-Level {
    $l = Read-Host 'Nivel del arma (vacio = nivel del personaje)'
    if ($l -match '^\d+$') { return [int]$l }
    return $null
}

function Add-One($name, $rar, $lvl) {
    $a = @('player', 'inventory', 'add') + (Get-CommonArgs) + @('--name', $name, '--rarity', $rar)
    if ($null -ne $lvl) { $a += @('--level', "$lvl") }
    $o = @(Invoke-DI2 $a)
    $txt = $o -join "`n"
    if ($script:LastOk -and ($txt -match '\b([0-9a-fA-F]{32})\b')) { return $matches[1] }
    Say $txt Red
    return $null
}

function Add-AllUpgrades($id, [string]$container = 'inventario') {
    Load-Upgrades
    $names = @($script:Upgrades)

    if (-not $names -or $names.Count -eq 0) {
        Say 'No hay lista de mejoras disponible.' Red
        return $false
    }

    if ($container -eq 'alijo') {
        $a = @('stash', 'upgrade', 'add') + (Get-StashArgs) + @('--item', $id)
    } else {
        $a = @('player', 'inventory', 'upgrade', 'add') + (Get-CommonArgs) + @('--item', $id)
    }
    foreach ($n in $names) { $a += @('--name', $n) }

    $o = @(Invoke-DI2 $a)
    if ($script:LastOk) {
        Say "  -> $($names.Count) mejoras solicitadas para ID $id" Green
        return $true
    }
    Say ($o -join "`n") Red
    return $false
}

function Anadir-Arma {
    Load-Items

    # Preguntar si solo armas o todos los items (incluye especiales)
    Say 'Que items quieres poder anadir?' Cyan
    Say '  1. Solo armas (melee y a distancia)'
    Say '  2. Todos los items (armas + curveballs + debug + AI + etc.)'
    $tipo = (Read-Host 'Opcion [1]').Trim()
    if ($tipo -eq '2') {
        $weps = @($script:Items)
        $tipoLabel = 'TODOS los items'
    } else {
        $weps = @($script:Items | Where-Object { Is-Weapon $_ })
        $tipoLabel = 'solo armas'
    }

    if ($weps.Count -eq 0) {
        Say 'No hay items disponibles para seleccionar.' Red
        return
    }

    Say "Filtro activo: $tipoLabel ($($weps.Count) disponibles)" DarkGray
    $q = Read-Host 'Nombre, palabra o primera letra (vacio = todas)'
    $res = @(Search-Items $weps $q)

    if ($res.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Say "Coincidencias: $($res.Count)" Cyan
    Show-Inv-Paged $res 100
    $chosen = @(Select-Multiple $res 'Numero(s) del item')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    $lvl = Ask-Level
    $rar = Ask-Rarity
    $nc = Read-Host 'Cuantas copias de cada item? [1]'
    if ($nc -notmatch '^\d+$' -or [int]$nc -lt 1) { $nc = 1 } else { $nc = [int]$nc }

    $up = Read-Host 'Aplicar TODAS las mejoras (~118) a cada copia? (S/N) [N]'
    $aplicarTodas = ($up -match '^[sSyY]')

    if ($aplicarTodas) { Load-Upgrades }

    $ok = 0
    $fail = 0
    foreach ($w in $chosen) {
        Say ''
        Say "-> $($w.UI) [$($w.Name)]" Cyan
        for ($k = 1; $k -le $nc; $k++) {
            $id = Add-One $w.Name $rar $lvl
            if ($id) {
                Say "   [$k/$nc] Anadido (ID $id)" Green
                if ($aplicarTodas) { [void](Add-AllUpgrades $id) }
                $ok++
            } else {
                $fail++
            }
        }
    }
    Say ''
    Say "Resumen: $ok correctos, $fail fallos." Cyan
}

# ---------------- Modificar multiples armas existentes ----------------
function Edit-Weapon($it, $rarity, $level, [string]$container = 'inventario') {
    $edit = @()
    if ($rarity) { $edit += @('--rarity', $rarity) }
    if ($null -ne $level) { $edit += @('--level', "$level") }

    if ($edit.Count -eq 0) { return $true }

    if ($container -eq 'alijo') {
        $a = @('stash', 'edit') + (Get-StashArgs) + @('--item', $it.ID) + $edit
    } else {
        $a = @('player', 'inventory', 'edit') + (Get-CommonArgs) + @('--item', $it.ID) + $edit
    }
    $o = @(Invoke-DI2 $a)

    if ($script:LastOk) {
        Say "  -> ID $($it.ID): modificacion aplicada" Green
        return $true
    }
    Say ($o -join "`n") Red
    return $false
}

function Mejorar-Existente([string]$container = 'inventario') {
    $kind = Ask-WeaponCategory
    if (-not $kind) { Say 'Categoria no valida.' Yellow; return }

    $inv = @(Get-WeaponPool $kind $container)
    if ($inv.Count -eq 0) { Say 'No hay armas de esa categoria.' Yellow; return }

    $f = Read-Host 'Filtrar por nombre (vacio = todas)'
    if ($f) { $inv = @(Search-Items $inv $f) }
    if ($inv.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Show-Inv $inv
    $chosen = @(Select-Multiple $inv 'Armas a modificar')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }
    Show-Selection $chosen

    Say 'Opcional: cambiar rareza/nivel. Deja vacio para no tocar.'
    $r = (Read-Host 'Nueva rareza (vacio = no cambiar)').ToLower().Trim()
    $l = Read-Host 'Nuevo nivel (vacio = no cambiar)'

    if ($r -and (-not (@('common', 'uncommon', 'rare', 'superior', 'legendary') -contains $r))) {
        Say 'Rareza no valida; no se cambiara la rareza.' Yellow
        $r = $null
    }

    $level = $null
    if ($l -match '^\d+$') { $level = [int]$l }
    elseif ($l) { Say 'Nivel no valido; no se cambiara el nivel.' Yellow }

    $up = Read-Host 'Aplicar TODAS las mejoras a todas las armas seleccionadas? (S/N) [S]'
    foreach ($it in $chosen) {
        [void](Edit-Weapon $it $r $level $container)
        if ($up -match '^[sSyY]') {
            [void](Add-AllUpgrades $it.ID $container)
        }
    }
}

function Aplicar-Upgrades-Multiples([string]$container = 'inventario') {
    $kind = Ask-WeaponCategory
    if (-not $kind) { Say 'Categoria no valida.' Yellow; return }

    $inv = @(Get-WeaponPool $kind $container)
    if ($inv.Count -eq 0) { Say 'No hay armas de esa categoria.' Yellow; return }

    $f = Read-Host 'Filtrar por nombre o letra (vacio = todas)'
    if ($f) { $inv = @(Search-Items $inv $f) }
    if ($inv.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Show-Inv $inv
    $chosen = @(Select-Multiple $inv 'Armas a recibir las mejoras')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    Load-Upgrades
    Say ''
    Say "Aplicando las $($script:Upgrades.Count) mejoras disponibles a $($chosen.Count) arma(s)..." Yellow

    $done = 0
    foreach ($it in $chosen) {
        if (Add-AllUpgrades $it.ID $container) { $done++ }
    }
    Say "Completadas $done de $($chosen.Count) armas." Green
}

# ---------------- Ver mejoras instaladas ----------------
function Get-InstalledUpgrades($id, [string]$container = 'inventario') {
    if ($container -eq 'alijo') {
        $out = @(Invoke-DI2 (@('stash', 'show', $id) + (Get-StashArgs)))
    } else {
        $out = @(Invoke-DI2 (@('player', 'inventory', 'show', $id) + (Get-CommonArgs)))
    }
    $ups = @()

    foreach ($l in $out) {
        $line = "$l"
        $m = [regex]::Match($line, '(?i)^\s*UpgradeEntry\d+\s*:\s*(.+)$')
        if (-not $m.Success) { continue }

        $value = $m.Groups[1].Value.Trim()
        $u = [regex]::Match($value, '(?i)(DA_[A-Za-z0-9_]+)(?:\.[A-Za-z0-9_]+)?$')
        if ($u.Success) {
            $name = $u.Groups[1].Value
            if ($name -and -not ($ups -contains $name)) { $ups += $name }
        }
    }
    return @($ups)
}

function Ver-Mejoras-Multiples([string]$container = 'inventario') {
    $kind = Ask-WeaponCategory
    if (-not $kind) { Say 'Categoria no valida.' Yellow; return }

    $inv = @(Get-WeaponPool $kind $container)
    if ($inv.Count -eq 0) { Say 'No hay armas de esa categoria.' Yellow; return }

    $f = Read-Host 'Nombre, palabra o primera letra del arma (vacio = todas)'
    if ($f) { $inv = @(Search-Items $inv $f) }
    if ($inv.Count -eq 0) { Say 'No se encontro ninguna arma con ese texto.' Yellow; return }

    Say ''
    Say "Armas encontradas: $($inv.Count)" Cyan
    Show-Inv $inv

    $chosen = @(Select-Multiple $inv 'Armas a consultar')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    foreach ($it in $chosen) {
        Say ''
        Say '------------------------------------------------------------' DarkGray
        Say "$($it.UI)  [$($it.Name)]  | ID $($it.ID)" Cyan

        $ups = @(Get-InstalledUpgrades $it.ID $container)
        if ($ups.Count -eq 0) {
            if ($it.Ups) {
                Say "di2save indica $($it.Ups) mejoras, pero no pude leer las entradas individuales." Yellow
            } else {
                Say 'No hay mejoras instaladas (o no se pudieron interpretar).' DarkGray
            }
            continue
        }

        Say "Mejoras instaladas: $($ups.Count)" Green
        for ($i = 0; $i -lt $ups.Count; $i++) {
            Say ("  {0,3}. {1}" -f ($i + 1), $ups[$i])
        }
    }
}

# ---------------- Eliminar ----------------
function Remove-One($id, [string]$container = 'inventario') {
    if ($container -eq 'alijo') {
        $a = @('stash', 'rm') + (Get-StashArgs) + @($id)
    } else {
        $a = @('player', 'inventory', 'rm') + (Get-CommonArgs) + @($id)
    }
    $o = @(Invoke-DI2 $a)

    if ($script:LastOk) { return $true }
    Say ($o -join "`n") Red
    return $false
}

function Eliminar-Armas-Multiples([string]$container = 'inventario') {
    $kind = Ask-WeaponCategory
    if (-not $kind) { Say 'Categoria no valida.' Yellow; return }

    $inv = @(Get-WeaponPool $kind $container)
    if ($inv.Count -eq 0) { Say 'No hay armas de esa categoria.' Yellow; return }

    $f = Read-Host 'Filtrar por nombre o letra (vacio = todas)'
    if ($f) { $inv = @(Search-Items $inv $f) }
    if ($inv.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Show-Inv $inv
    $chosen = @(Select-Multiple $inv 'Armas a eliminar')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    $done = 0
    foreach ($it in $chosen) {
        if (Remove-One $it.ID $container) {
            $done++
            Say "Borrada: $($it.Name) [$($it.ID)]" Green
        }
    }
    Say "Borradas $done de $($chosen.Count)." Green
}

function Eliminar-Armas-Por-Categoria([string]$container = 'inventario') {
    $kind = Ask-WeaponCategory
    if (-not $kind) { Say 'Categoria no valida.' Yellow; return }

    $inv = @(Get-WeaponPool $kind $container)
    if ($inv.Count -eq 0) { Say 'No hay armas de esa categoria.' Yellow; return }

    Say ''
    Say "Eliminando TODAS las armas de esta categoria: $($inv.Count) entradas." Yellow

    $done = 0
    foreach ($it in $inv) {
        if (Remove-One $it.ID $container) {
            $done++
            Say "Borrada: $($it.Name) [$($it.ID)]" DarkGray
        }
    }
    Say "Borradas $done de $($inv.Count)." Green
}

function Eliminar-Items {
    $inv = @(Get-Inventory)
    if ($inv.Count -eq 0) { Say 'Inventario vacio o no legible.' Yellow; return }

    $q = (Read-Host 'Nombre, texto o ID del item a borrar (0 = cancelar)').Trim()
    if (-not $q -or $q -eq '0') { return }

    if ($q -match '^[0-9a-fA-F]{32}$') {
        $m = @($inv | Where-Object { $_.ID -ieq $q })
        if ($m.Count -eq 0) { Say 'Ese ID no esta en el inventario de este personaje.' Yellow; return }

        $done = 0
        foreach ($it in $m) {
            if (Remove-One $it.ID) { $done++ }
        }
        Say "Borrados $done item(s)." Green
        return
    }

    $m = @(Search-Items $inv $q)
    if ($m.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Say "Resultados encontrados: $($m.Count)" Cyan
    Show-Inv $m

    $chosen = @(Select-Multiple $m 'Items a borrar')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    $done = 0
    foreach ($it in $chosen) {
        if (Remove-One $it.ID) { $done++ }
    }
    Say "Borrados $done de $($chosen.Count)." Green
}

# ---------------- Nivel del personaje ----------------
function Get-MaxLevelForProfile {
    $p = Get-CurrentProfile
    if ($p -and $p.NG -eq 'true') { return 40 }
    return 30
}

function Gestionar-Nivel {
    $p = Get-CurrentProfile
    $cap = Get-MaxLevelForProfile

    Say ''
    Say "Personaje: $script:ProfLabel" Cyan
    if ($p -and $p.Level) { Say "Progresion actual (campo interno): $($p.Level)" DarkGray }
    Say "Tope esperado: nivel $cap (30 normal / 40 en NG+)." DarkGray
    Say ''
    Say '  1. Subir al MAXIMO mediante max-xp'
    Say '  2. Elegir un nivel exacto'
    Say '  3. Restablecer a nivel 1'
    Say '  0. Cancelar'

    $op = (Read-Host 'Opcion').Trim()
    switch ($op) {
        '1' {
            $a = @('quick', 'apply', 'max-xp') + (Get-CommonArgs)
            $o = @(Invoke-DI2 $a)
            if ($script:LastOk) {
                Say "XP del personaje llevado al maximo (tope esperado: nivel $cap)." Green
            } else {
                Say ($o -join "`n") Red
            }
        }
        '2' {
            $n = Read-Host "Nivel deseado (1-$cap)"
            if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $cap) {
                Say "Nivel fuera de rango. Usa 1-$cap." Yellow
                return
            }

            Say ''
            Say 'El nivel exacto no se modifica porque di2save no documenta un setter de nivel arbitrario.' Yellow
            Say "No se ha tocado el save. Nivel solicitado: $n." DarkGray
        }
        '3' {
            Say ''
            Say 'El reset a nivel 1 no se ejecuta porque di2save no documenta un setter para forzar directamente ese nivel.' Yellow
            Say 'No se ha tocado el save.' DarkGray
        }
        '0' { return }
        default { Say 'Opcion no valida.' Yellow }
    }
}

# ---------------- Municion ----------------
function Municion-Maxima {
    # Lista de municion estandar en Dead Island 2.
    # Si tu version tiene DLC con municion extra (Haus, SoLA, etc.)
    # puedes anadir sus IDs aqui siguiendo el mismo patron.
    $ammoList = @(
        'DA_AmmoArchetype_PistolAmmo',
        'DA_AmmoArchetype_CarbineAmmo',
        'DA_AmmoArchetype_ShotgunAmmo',
        'DA_AmmoArchetype_HeavyRoundsAmmo',
        'DA_AmmoArchetype_NailgunNailsAmmo',
        'DA_AmmoArchetype_CrossbowBoltsAmmo'
    )

    Say ''
    Say "Anadiendo municion de todos los tipos (999 balas por tipo)..." Yellow
    Say ''

    $okInv = 0
    $okStash = 0
    $fail = 0

    foreach ($name in $ammoList) {
        # --- 1) Intentar anadir al inventario del personaje ---
        $aInv = @('player', 'inventory', 'add') + (Get-CommonArgs) + @('--name', $name, '--count', '999')
        $oInv = @(Invoke-DI2 $aInv)

        if ($script:LastOk) {
            Say "  [Inventario] OK: $name" Green
            $okInv++
        } else {
            # --- 2) Si falla el inventario, intentar al alijo (stash) ---
            $aStash = @('stash', 'add') + (Get-StashArgs) + @('--name', $name, '--count', '999')
            $oStash = @(Invoke-DI2 $aStash)

            if ($script:LastOk) {
                Say "  [Alijo]      OK: $name" Cyan
                $okStash++
            } else {
                Say "  FALLO: $name" Red
                Say ("       " + (($oStash -join "`n") -replace "`n", "`n       ")) DarkGray
                $fail++
            }
        }
    }

    Say ''
    Say "Resumen: $okInv en inventario, $okStash en alijo, $fail fallos." Cyan
    if ($fail -gt 0) {
        Say 'Los tipos que fallen puede que no existan en tu version del juego.' DarkGray
    }
}

# ---------------- Dinero ----------------
function Dinero-Maximo {
    # El dinero en DI2 es un item de inventario. Al anadirlo con --count
    # muy alto, el juego lo recorta automaticamente a su tope interno.
    $a = @('player', 'inventory', 'add') + (Get-CommonArgs) + @(
        '--name', 'DA_InventoryTypes_Special_CashItem',
        '--count', '9999999'
    )
    $o = @(Invoke-DI2 $a)

    if ($script:LastOk) {
        Say ''
        Say 'Dinero al maximo anadido al inventario.' Green
        Say 'Si el juego lo recorta, es porque tiene un tope interno.' DarkGray
    } else {
        Say ''
        Say 'No se pudo anadir el dinero.' Red
        Say ($o -join "`n") Red
    }
}

# ---------------- Desbloqueos ----------------
function Desbloquear-Todo {
    Say ''
    Say 'Desbloqueando TODOS los blueprints y curveballs...' Yellow
    Say ''

    # 1) Blueprints
    $a1 = @('quick', 'apply', 'unlock-blueprints') + (Get-CommonArgs)
    $o1 = @(Invoke-DI2 $a1)

    if ($script:LastOk) {
        Say '  [OK] Blueprints desbloqueados.' Green
    } else {
        Say '  [FALLO] No se pudieron desbloquear los blueprints.' Red
        Say ('       ' + (($o1 -join "`n") -replace "`n", "`n       ")) DarkGray
    }

    # 2) Curveballs
    $a2 = @('quick', 'apply', 'unlock-curveballs') + (Get-CommonArgs)
    $o2 = @(Invoke-DI2 $a2)

    if ($script:LastOk) {
        Say '  [OK] Curveballs desbloqueadas.' Green
    } else {
        Say '  [FALLO] No se pudieron desbloquear las curveballs.' Red
        Say ('       ' + (($o2 -join "`n") -replace "`n", "`n       ")) DarkGray
    }

    Say ''
    Say 'Proceso completado. Reinicia el juego si no ves los cambios.' Cyan
}

# ---------------- Alijo (Stash) ----------------
function Get-NGArgs {
    # Devuelve el flag --ng+ correcto segun el perfil activo.
    $p = Get-CurrentProfile
    if ($p -and $p.NG -eq 'true') { return @('--ng+', '1') }
    return @('--ng+', '0')
}

function Get-StashArgs {
    # El stash es del save completo, no de un perfil concreto.
    # Pasamos solo --file (sin --profile ni --ng+).
    return @('--file', $script:Save)
}

function Get-Stash {
    Load-Items
    $cmdArgs = @('stash', 'ls') + (Get-StashArgs)
    $out = @(Invoke-DI2 $cmdArgs)

    $items = @()
    $cat = '?'
    $cur = $null

    foreach ($l in $out) {
        if ($l -match '^(\S[^:]*):\s*$') {
            if ($cur) { $items += $cur; $cur = $null }
            $cat = $matches[1]
            continue
        }
        if ($l -match '^\s*-\s*EntryID:\s*(\w+)') {
            if ($cur) { $items += $cur }
            $cur = [pscustomobject]@{
                Cat = $cat
                ID = $matches[1]
                Name = ''
                UI = ''
                Count = ''
                Rarity = ''
                Level = ''
                Ups = ''
                UpList = @()
            }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s*Archetype:\s*(\S+)') {
            $a = $matches[1]
            $n = $a.Substring($a.LastIndexOf('.') + 1)
            $cur.Name = $n
            if ($script:UIMap.ContainsKey($n)) { $cur.UI = $script:UIMap[$n] }
        }
        elseif ($l -match '^\s*Count:\s*(\d+)') { $cur.Count = $matches[1] }
        elseif ($l -match '(?i)^\s*Required\s*Rarity:\s*(?:EItemRarity::)?(\w+)') { $cur.Rarity = $matches[1] }
        elseif ($l -match '(?i)^\s*Required\s*Level:\s*(\d+)') { $cur.Level = $matches[1] }
        elseif ($l -match '^\s*NumUpgrades:\s*(\d+)') { $cur.Ups = $matches[1] }
    }
    if ($cur) { $items += $cur }

    # --- DIAGNOSTICO: si no encontramos items, mostramos la salida cruda ---
    if ($items.Count -eq 0) {
        Say ''
        Say 'No se encontraron items en el alijo. Salida cruda de di2save:' Yellow
        Say ('  Comando: di2save ' + ($args -join ' ')) DarkGray
        Say '  ---- inicio salida ----' DarkGray
        if ($out.Count -eq 0) {
            Say '  (sin salida)' DarkGray
        } else {
            $out | ForEach-Object { Say "  $_" DarkGray }
        }
        Say '  ---- fin salida ----' DarkGray
        Say ''
        Say 'LastOk = ' -NoNewline DarkGray
        Say "$($script:LastOk)" DarkGray
    }

    return $items
}

function Ver-Stash {
    $items = @(Get-Stash)
    if ($items.Count -eq 0) { Say 'Alijo vacio o no legible.' Yellow; return }

    $w = Read-Host 'Mostrar solo armas? (S/N) [S]'
    if ($w -notmatch '^[nN]') {
        $items = @($items | Where-Object { Is-Weapon $_ -or $_.Cat -eq 'Weapons' })
    }
    $f = Read-Host 'Filtrar por nombre (vacio = todo)'
    if ($f) { $items = @(Search-Items $items $f) }

    Say ''
    Say "Alijo de $($script:ProfLabel) - $($items.Count) entradas" Cyan
    Show-Inv $items
}

function Anadir-Arma-AlStash {
    Load-Items

    # Preguntar si solo armas o todos los items
    Say 'Que items quieres poder anadir al alijo?' Cyan
    Say '  1. Solo armas (melee y a distancia)'
    Say '  2. Todos los items (armas + curveballs + debug + AI + etc.)'
    $tipo = (Read-Host 'Opcion [1]').Trim()
    if ($tipo -eq '2') {
        $weps = @($script:Items)
        $tipoLabel = 'TODOS los items'
    } else {
        $weps = @($script:Items | Where-Object { Is-Weapon $_ })
        $tipoLabel = 'solo armas'
    }

    if ($weps.Count -eq 0) {
        Say 'No hay items disponibles.' Red
        return
    }

    Say "Filtro activo: $tipoLabel ($($weps.Count) disponibles)" DarkGray
    $q = Read-Host 'Nombre, palabra o primera letra (vacio = todos)'
    $res = @(Search-Items $weps $q)
    if ($res.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Say "Coincidencias: $($res.Count)" Cyan
    Show-Inv-Paged $res 100
    $chosen = @(Select-Multiple $res 'Numero(s) del item')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    $lvl = Ask-Level
    $rar = Ask-Rarity
    $nc = Read-Host 'Cuantas copias de cada item? [1]'
    if ($nc -notmatch '^\d+$' -or [int]$nc -lt 1) { $nc = 1 } else { $nc = [int]$nc }

    $up = Read-Host 'Aplicar TODAS las mejoras (~118) a cada copia? (S/N) [N]'
    $aplicarTodas = ($up -match '^[sSyY]')

    if ($aplicarTodas) { Load-Upgrades }

    $ok = 0
    $fail = 0
    foreach ($w in $chosen) {
        Say ''
        Say "-> $($w.UI) [$($w.Name)]" Cyan
        for ($k = 1; $k -le $nc; $k++) {
            $a = @('stash', 'add') + (Get-StashArgs) + @('--name', $w.Name, '--rarity', $rar)
            if ($null -ne $lvl) { $a += @('--level', "$lvl") }
            $o = @(Invoke-DI2 $a)
            if ($script:LastOk) {
                $txt = $o -join "`n"
                $newId = $null
                if ($txt -match '\b([0-9a-fA-F]{32})\b') { $newId = $matches[1] }

                Say "   [$k/$nc] Anadido al alijo" Green
                if ($aplicarTodas -and $newId) { [void](Add-AllUpgrades $newId 'alijo') }
                $ok++
            } else {
                Say "   [$k/$nc] FALLO" Red
                Say ("   " + (($o -join "`n") -replace "`n", "`n   ")) DarkGray
                $fail++
            }
        }
    }
    Say ''
    Say "Resumen: $ok correctos, $fail fallos." Cyan
}

function Mover-Item {
    param([string]$Origen = 'inventario')

    if ($Origen -eq 'inventario') {
        $pool    = @(Get-Inventory)
        $dstCmd  = @('stash')
        $dstArgs = (Get-StashArgs)
        $srcCmd  = @('player', 'inventory')
        $srcArgs = (Get-CommonArgs)
        $dstLabel = 'alijo'
        $srcLabel = 'inventario'
    } else {
        $pool    = @(Get-Stash)
        $dstCmd  = @('player', 'inventory')
        $dstArgs = (Get-CommonArgs)
        $srcCmd  = @('stash')
        $srcArgs = (Get-StashArgs)
        $dstLabel = 'inventario'
        $srcLabel = 'alijo'
    }

    if ($pool.Count -eq 0) { Say "El $srcLabel esta vacio." Yellow; return }

    $q = Read-Host "Buscar item en $srcLabel (vacio = todos)"
    $res = @($pool)
    if ($q) { $res = @(Search-Items $res $q) }
    if ($res.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Show-Inv $res
    $chosen = @(Select-Multiple $res "Items a mover al $dstLabel")
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    $okMove = 0
    foreach ($it in $chosen) {
        # 1) Anadir al destino
        $addArgs = $dstCmd + @('add') + $dstArgs + @('--name', $it.Name)
        if ($it.Count)  { $addArgs += @('--count', $it.Count) }
        if ($it.Rarity) { $addArgs += @('--rarity', $it.Rarity) }
        if ($it.Level)  { $addArgs += @('--level', $it.Level) }

        $oAdd = @(Invoke-DI2 $addArgs)
        if (-not $script:LastOk) {
            Say "Fallo al anadir $($it.Name) al $dstLabel" Red
            Say ($oAdd -join "`n") DarkGray
            continue
        }

        # 2) Eliminar del origen
        $rmArgs = $srcCmd + @('rm') + $srcArgs + @($it.ID)

        $oRm = @(Invoke-DI2 $rmArgs)
        if ($script:LastOk) {
            Say "Movido: $($it.Name)  ($srcLabel -> $dstLabel)" Green
            $okMove++
        } else {
            $msg = "Anadido al $dstLabel pero no se pudo borrar del " + $srcLabel + ": " + $it.Name
            Say $msg Yellow
            Say ($oRm -join "`n") DarkGray
        }
    }
    Say "Movidos $okMove de $($chosen.Count)." Cyan
}

function Eliminar-DelStash {
    $pool = @(Get-Stash)
    if ($pool.Count -eq 0) { Say 'Alijo vacio.' Yellow; return }

    $q = (Read-Host 'Nombre, texto o ID a borrar (vacio = mostrar todo, 0 = cancelar)').Trim()
    if ($q -eq '0') { return }

    if ($q -match '^[0-9a-fA-F]{32}$') {
        $m = @($pool | Where-Object { $_.ID -ieq $q })
    } elseif ($q) {
        $m = @(Search-Items $pool $q)
    } else {
        # Sin input: mostrar todo
        $m = @($pool)
    }
    if ($m.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Show-Inv $m
    $chosen = @(Select-Multiple $m 'Items a borrar del alijo')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    $done = 0
    foreach ($it in $chosen) {
        if (Remove-One $it.ID 'alijo') {
            $done++
            Say "Borrado: $($it.Name)" Green
        }
    }
    Say "Borrados $done de $($chosen.Count)." Green
}

function Clonar-Item {
    Clear-Host
    Say '============================================================' Cyan
    Say '           CLONAR / COPIAR ITEMS ENTRE CONTENEDORES' Cyan
    Say '============================================================' Cyan
    Say 'Esta opcion COPIA items. El original NO se borra.' DarkGray
    Say 'Si quieres MOVER (borrar el original), usa las opciones 3 o 4.' Yellow
    Say ''

    # --- 1) Elegir ORIGEN ---
    Say 'PASO 1 de 3: Desde donde quieres copiar?' Cyan
    Say '  1. Inventario del personaje   (lo que llevas encima)'
    Say '  2. Alijo / Stash              (la caja fuerte compartida)'
    Say '  0. Cancelar'
    $c = (Read-Host 'Origen').Trim()

    switch ($c) {
        '1' { $origen = 'inventario'; $origenLabel = 'INVENTARIO DEL PERSONAJE' }
        '2' { $origen = 'alijo';      $origenLabel = 'ALIJO (STASH)' }
        '0' { return }
        default { Say 'Opcion no valida.' Yellow; return }
    }
    Say "  -> Origen elegido: $origenLabel" Green
    Say ''

    # --- 2) Elegir DESTINO (con explicacion clara) ---
    Say 'PASO 2 de 3: Donde quieres poner las copias?' Cyan

    if ($origen -eq 'inventario') {
        Say '  1. Copiar al MISMO inventario    (duplicar dentro del inventario)'
        Say '  2. Copiar al ALIJO (STASH)       (inventario  ->  alijo)'
        Say '  0. Cancelar'
    } else {
        Say '  1. Copiar al MISMO alijo         (duplicar dentro del alijo)'
        Say '  2. Copiar al INVENTARIO          (alijo  ->  inventario)'
        Say '  0. Cancelar'
    }

    $d = (Read-Host 'Destino [1]').Trim()
    if ($d -eq '0') { return }
    if (-not $d) { $d = '1' }

    if ($d -eq '1') {
        $destino = $origen
        $destinoLabel = $origenLabel
        $accion = 'DUPLICAR EN EL MISMO SITIO'
    } elseif ($d -eq '2') {
        if ($origen -eq 'inventario') {
            $destino = 'alijo'
            $destinoLabel = 'ALIJO (STASH)'
            $accion = 'INVENTARIO -> ALIJO'
        } else {
            $destino = 'inventario'
            $destinoLabel = 'INVENTARIO DEL PERSONAJE'
            $accion = 'ALIJO -> INVENTARIO'
        }
    } else {
        Say 'Opcion no valida.' Yellow; return
    }

    Say ''
    Say '  -----------------------------------------------' DarkGray
    Say "  Origen:     $origenLabel" Cyan
    Say "  Destino:    $destinoLabel" Cyan
    Say "  Operacion:  $accion" Yellow
    Say '  -----------------------------------------------' DarkGray
    Say ''

    $confirma = Read-Host 'Continuar con esta direccion? (S/N) [S]'
    if ($confirma -match '^[nN]') { Say 'Cancelado.' Yellow; return }

    # --- 3) Leer items del origen y seleccionarlos ---
    Say ''
    Say 'PASO 3 de 3: Que items quieres copiar?' Cyan

    if ($origen -eq 'alijo') {
        $pool = @(Get-Stash)
    } else {
        $pool = @(Get-Inventory)
    }

    if ($pool.Count -eq 0) {
        Say "El $origenLabel esta vacio." Yellow
        return
    }

    $q = Read-Host "Filtrar items del $origenLabel (vacio = mostrar todos)"
    $res = @($pool)
    if ($q) { $res = @(Search-Items $res $q) }
    if ($res.Count -eq 0) { Say 'Sin resultados.' Yellow; return }

    Say ''
    Say "Items disponibles en $origenLabel : $($res.Count)" Cyan
    Show-Inv $res
    $chosen = @(Select-Multiple $res 'Items a copiar')
    if ($chosen.Count -eq 0) { Say 'Cancelado.' Yellow; return }

    Say ''
    Say "Resumen de la operacion:" Cyan
    Say "  $($chosen.Count) item(s)  |  $accion" Yellow
    Show-Inv $chosen

    $nc = Read-Host 'Cuantas copias de cada uno? [1]'
    if ($nc -notmatch '^\d+$' -or [int]$nc -lt 1) { $nc = 1 } else { $nc = [int]$nc }

    $confirma2 = Read-Host "Confirmar $accion ($nc copia(s) por item) (S/N) [S]"
    if ($confirma2 -match '^[nN]') { Say 'Cancelado.' Yellow; return }

    # --- Preguntar sobre mejoras a aplicar en las copias ---
    $aplicarTodas = $false
    $copiarDelOriginal = $true

    if ($destino -ne $origen) {
        # Solo tiene sentido preguntar en cross-container, porque en mismo
        # contenedor usamos 'clone' que ya preserva exactamente lo que tenia.
        Say ''
        Say 'Que mejoras quieres en las COPIAS?' Cyan
        Say '  1. Solo copiar las mejoras que tenia el original'
        Say '  2. Aplicar TODAS las mejoras del juego (~118) a las copias'
        Say '  3. No aplicar ninguna mejora a las copias'
        $mq = (Read-Host 'Opcion [1]').Trim()

        switch ($mq) {
            '1' { $copiarDelOriginal = $true;  $aplicarTodas = $false }
            '2' { $copiarDelOriginal = $false; $aplicarTodas = $true }
            '3' { $copiarDelOriginal = $false; $aplicarTodas = $false }
            default { $copiarDelOriginal = $true; $aplicarTodas = $false }
        }

        if ($aplicarTodas) {
            Load-Upgrades
            Say "  -> Se aplicaran las $($script:Upgrades.Count) mejoras disponibles a cada copia." Yellow
        } elseif ($copiarDelOriginal) {
            Say '  -> Se copiaran solo las mejoras del arma original.' DarkGray
        } else {
            Say '  -> Las copias se quedaran sin mejoras.' DarkGray
        }
    }

    # Argumentos segun contenedor
    if ($origen  -eq 'alijo') { $srcArgs = (Get-StashArgs) }  else { $srcArgs = (Get-CommonArgs) }
    if ($destino -eq 'alijo') { $dstArgs = (Get-StashArgs) }  else { $dstArgs = (Get-CommonArgs) }

    $done = 0
    $errores = 0
    foreach ($it in $chosen) {
        for ($k = 1; $k -le $nc; $k++) {
            if ($destino -eq $origen) {
                # --- Clonar en el mismo contenedor (preserva mejoras) ---
                if ($destino -eq 'alijo') {
                    $a = @('stash', 'clone') + $dstArgs + @($it.ID)
                } else {
                    $a = @('player', 'inventory', 'clone') + $dstArgs + @($it.ID)
                }
                $o = @(Invoke-DI2 $a)
                if ($script:LastOk) {
                    $done++
                    $txt = $o -join "`n"
                    if ($txt -match '\b([0-9a-fA-F]{32})\b') {
                        Say "  [$accion] $($it.Name)  ->  nuevo ID $($matches[1])" Green
                    } else {
                        Say "  [$accion] $($it.Name)" Green
                    }
                } else {
                    $errores++
                    Say "  [FALLO] $($it.Name)" Red
                    Say ("    " + (($o -join "`n") -replace "`n", "`n    ")) DarkGray
                }
            } else {
                # --- Cross-container: add + copiar mejoras ---
                if ($destino -eq 'alijo') {
                    $addArgs = @('stash', 'add') + $dstArgs
                } else {
                    $addArgs = @('player', 'inventory', 'add') + $dstArgs
                }
                $addArgs += @('--name', $it.Name)
                if ($it.Count)  { $addArgs += @('--count', $it.Count) }
                if ($it.Rarity) { $addArgs += @('--rarity', $it.Rarity) }
                if ($it.Level)  { $addArgs += @('--level', $it.Level) }

                $oAdd = @(Invoke-DI2 $addArgs)
                if (-not $script:LastOk) {
                    $errores++
                    Say "  [FALLO] $($it.Name)  ($accion)" Red
                    Say ("    " + (($oAdd -join "`n") -replace "`n", "`n    ")) DarkGray
                    continue
                }

                # Obtener el nuevo ID del output
                $txt = $oAdd -join "`n"
                $newId = $null
                if ($txt -match '\b([0-9a-fA-F]{32})\b') { $newId = $matches[1] }

                # Aplicar mejoras a la copia segun lo elegido
                if ($newId) {
                    if ($aplicarTodas) {
                        # Meter el set completo de mejoras
                        [void](Add-AllUpgrades $newId $destino)
                        Say "  [$accion] $($it.Name)  ->  nuevo ID $newId  (TODAS las mejoras)" Green
                    } elseif ($copiarDelOriginal) {
                        # Copiar solo las mejoras que ya tenia el original
                        $ups = @(Get-InstalledUpgrades $it.ID $origen)
                        if ($ups.Count -gt 0) {
                            if ($destino -eq 'alijo') {
                                $upArgs = @('stash', 'upgrade', 'add') + $dstArgs + @('--item', $newId)
                            } else {
                                $upArgs = @('player', 'inventory', 'upgrade', 'add') + $dstArgs + @('--item', $newId)
                            }
                            foreach ($u in $ups) { $upArgs += @('--name', $u) }
                            [void](Invoke-DI2 $upArgs)
                            Say "  [$accion] $($it.Name)  ->  nuevo ID $newId  ($($ups.Count) mejoras copiadas)" Green
                        } else {
                            Say "  [$accion] $($it.Name)  ->  nuevo ID $newId  (sin mejoras)" Green
                        }
                    } else {
                        # No aplicar mejoras
                        Say "  [$accion] $($it.Name)  ->  nuevo ID $newId  (sin mejoras)" Green
                    }
                } else {
                    Say "  [$accion] $($it.Name)" Green
                }
                $done++
            }
        }
    }

    Say ''
    Say "Total copias creadas: $done" Green
    if ($errores -gt 0) {
        Say "Fallos: $errores" Red
    }
    Say "Direccion usada: $accion" DarkGray
}

function Gestionar-Stash {
    while ($true) {
        Clear-Host
        Say '============================================================' Cyan
        Say '                 GESTION DEL ALIJO (STASH)' Cyan
        Say '============================================================' Cyan
        Say "Personaje: $($script:ProfLabel)" DarkGray
        Say ''
        Say '  1. Ver contenido del alijo'
        Say '  2. Anadir arma(s) al alijo'
        Say '  3. Mover items del inventario al alijo'
        Say '  4. Mover items del alijo al inventario'
        Say '  5. Eliminar items del alijo'
        Say '  6. Clonar items (mismo contenedor o entre contenedores)'
        Say '  7. Modificar armas del alijo (rareza/nivel/mejoras)'
        Say '  8. Aplicar TODAS las mejoras a armas del alijo'
        Say '  9. Ver mejoras instaladas de armas del alijo'
        Say ' 10. Eliminar armas del alijo por categoria'
        Say '  0. Volver al menu principal'
        Say ''
        $op = (Read-Host 'Opcion').Trim()

        switch ($op) {
            '1'  { Ver-Stash; Pausa }
            '2'  { Anadir-Arma-AlStash; Pausa }
            '3'  { Mover-Item 'inventario'; Pausa }
            '4'  { Mover-Item 'alijo'; Pausa }
            '5'  { Eliminar-DelStash; Pausa }
            '6'  { Clonar-Item; Pausa }
            '7'  { Mejorar-Existente 'alijo'; Pausa }
            '8'  { Aplicar-Upgrades-Multiples 'alijo'; Pausa }
            '9'  { Ver-Mejoras-Multiples 'alijo'; Pausa }
            '10' { Eliminar-Armas-Por-Categoria 'alijo'; Pausa }
            '0'  { return }
            default {
                Say 'Opcion no valida.' Yellow
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

function Ver-ItemsEspeciales {
    Clear-Host
    Say '============================================================' Cyan
    Say '         EXPLORADOR DE ITEMS ESPECIALES (IA / DEBUG)' Cyan
    Say '============================================================' Cyan
    Say 'Consultando di2save todos los items conocidos...' DarkGray
    Say ''

    # Probamos varias combinaciones porque el comando 'help' no acepta
    # --no-version-safety y segun la version los flags pueden variar.
    $variantes = @(
        @('help','inventory','items','--include-dlc','--include-ai','--include-internal'),
        @('help','inventory','items','--include-dlc','--include-ai'),
        @('help','inventory','items','--include-internal'),
        @('help','inventory','items')
    )

    $out = @()
    $usada = $null

    foreach ($v in $variantes) {
        $tmp = @(Invoke-DI2-Help $v)
        if ($tmp.Count -gt 0 -and $script:LastOk) {
            $out = $tmp
            $usada = ($v -join ' ')
            break
        }
    }

    if (-not $usada) {
        Say 'di2save no devolvio nada con ninguna combinacion.' Red
        Say ''
        Say 'Salida cruda del ultimo intento:' Yellow
        $ultimo = @(Invoke-DI2-Help @('help','inventory','items','--include-internal'))
        if ($ultimo.Count -eq 0) {
            Say '  (sin salida - el comando no devuelve nada)' DarkGray
        } else {
            $ultimo | ForEach-Object { Say "  $_" DarkGray }
        }
        Say ''
        Say 'Comprueba manualmente en CMD:' Cyan
        Say '  di2save help inventory items' Cyan
        Say '  di2save help inventory items --include-internal' Cyan
        return
    }

    Say "Sintaxis correcta detectada: di2save $usada" Green
    Say ''

    # Parsear la salida buscando cualquier ID DA_...
    $todos = @()
    $vistos = @{}
    foreach ($l in $out) {
        $line = "$l"
        $matches2 = [regex]::Matches($line, '(?i)(DA_[A-Za-z0-9_]+)')
        foreach ($m in $matches2) {
            $name = $m.Value
            if ($vistos.ContainsKey($name)) { continue }
            $vistos[$name] = $true

            $ui = $line.Substring(0, $m.Index)
            $ui = ($ui -replace '[|\u2502]', ' ').Trim()
            if (-not $ui) { $ui = $name }

            $todos += [pscustomobject]@{ Name = $name; UI = $ui }
        }
    }

    if ($todos.Count -eq 0) {
        Say 'di2save respondio pero no contiene ningun ID DA_...' Yellow
        Say ''
        Say 'Primeras 30 lineas de la salida:' DarkGray
        $out | Select-Object -First 30 | ForEach-Object { Say "  $_" DarkGray }
        return
    }

    Say "Items totales devueltos por di2save: $($todos.Count)" DarkGray
    Say ''

    # --- Menu de filtros ---
    Say 'Que categoria quieres explorar?' Cyan
    Say '  1. Items con nombre "Debug"       (herramientas de desarrollo)'
    Say '  2. Items con nombre "AI"          (variantes de enemigos)'
    Say '  3. Curveballs'
    Say '  4. Blueprints / recipes'
    Say '  5. TODOS los items disponibles (puede ser muy largo)'
    Say '  6. Buscar por texto libre'
    Say '  0. Cancelar'
    $f = (Read-Host 'Opcion').Trim()

    $res = @()
    switch ($f) {
        '1' { $res = @($todos | Where-Object { $_.Name -match '(?i)Debug' } | Sort-Object Name -Unique) }
        '2' { $res = @($todos | Where-Object { $_.Name -match '(?i)_AI_|AI_' } | Sort-Object Name -Unique) }
        '3' { $res = @($todos | Where-Object { $_.Name -match '(?i)Curveball' } | Sort-Object Name -Unique) }
        '4' { $res = @($todos | Where-Object { $_.Name -match '(?i)Recipe|Blueprint' } | Sort-Object Name -Unique) }
        '5' { $res = @($todos | Sort-Object Name -Unique) }
        '6' {
            $q = (Read-Host 'Texto a buscar (ej: machete, debug, AI)').Trim()
            if (-not $q) { Say 'Cancelado.' Yellow; return }
            $res = @($todos | Where-Object {
                $_.Name -match [regex]::Escape($q) -or $_.UI -match [regex]::Escape($q)
            } | Sort-Object Name -Unique)
        }
        '0' { return }
        default { Say 'Opcion no valida.' Yellow; return }
    }

    if ($res.Count -eq 0) {
        Say 'No se encontraron items con ese filtro.' Yellow
        Say ''
        Say 'Sugerencia: usa la opcion 6 (busqueda libre) con:' DarkGray
        Say '  machete    -> variantes de machete' DarkGray
        Say '  debug      -> herramientas de desarrollo' DarkGray
        Say '  AI         -> variantes de IA' DarkGray
        Say '  Curveball  -> curveballs' DarkGray
        return
    }

    Say ''
    Say "Items encontrados: $($res.Count)" Cyan
    Show-Inv-Paged $res 100
    $chosen = @(Select-Multiple $res 'Items a procesar')
    if ($chosen.Count -eq 0) { return }

    # ============================================================
    # AQUI ESTA LO NUEVO: preguntamos lo mismo que en "Anadir armas"
    # ============================================================

    Say ''
    Say '  -----------------------------------------------' DarkGray
    Say '  Configuracion de las copias a crear' Cyan
    Say '  -----------------------------------------------' DarkGray

    # 1) Contenedor destino
    Say '  1. Inventario del personaje'
    Say '  2. Alijo (stash)'
    $c = (Read-Host 'Donde quieres anadirlos? [1]').Trim()
    if ($c -eq '2') { $container = 'alijo'; $containerLabel = 'ALIJO' }
    else            { $container = 'inventario'; $containerLabel = 'INVENTARIO' }

    # 2) Cantidad de copias
    $nc = Read-Host 'Cuantas copias de cada item? [1]'
    if ($nc -notmatch '^\d+$' -or [int]$nc -lt 1) { $nc = 1 } else { $nc = [int]$nc }

    # 3) Nivel (opcional)
    $lvl = Ask-Level

    # 4) Rareza (opcional)
    $rar = Ask-Rarity

    # 5) Aplicar todas las mejoras
    $up = Read-Host 'Aplicar TODAS las mejoras (~118) a cada copia? (S/N) [N]'
    $aplicarTodas = ($up -match '^[sSyY]')

    if ($aplicarTodas) { Load-Upgrades }

    # --- Resumen antes de ejecutar ---
    Say ''
    Say '  -----------------------------------------------' DarkGray
    Say "  Destino:          $containerLabel" Cyan
    Say "  Items unicos:     $($chosen.Count)" Cyan
    Say "  Copias por item:  $nc" Cyan
    Say "  Total a crear:    $($chosen.Count * $nc)" Cyan
    if ($null -ne $lvl) { Say "  Nivel:            $lvl" Cyan }
    Say "  Rareza:           $rar" Cyan
    Say "  Todas mejoras:    $(if ($aplicarTodas) { 'SI' } else { 'NO' })" Cyan
    Say '  -----------------------------------------------' DarkGray
    Say ''

    $confirma = Read-Host 'Continuar? (S/N) [S]'
    if ($confirma -match '^[nN]') { Say 'Cancelado.' Yellow; return }

    # ============================================================
    # Bucle de creacion
    # ============================================================
    $ok = 0
    $fail = 0

    foreach ($it in $chosen) {
        Say ''
        Say "-> Procesando: $($it.Name)" Cyan

        for ($k = 1; $k -le $nc; $k++) {
            # --- Construir argumentos de add ---
            if ($container -eq 'alijo') {
                $addArgs = @('stash','add') + (Get-StashArgs) + @('--name', $it.Name, '--rarity', $rar)
            } else {
                $addArgs = @('player','inventory','add') + (Get-CommonArgs) + @('--name', $it.Name, '--rarity', $rar)
            }
            if ($null -ne $lvl) { $addArgs += @('--level', "$lvl") }

            $oAdd = @(Invoke-DI2 $addArgs)

            # Fallback: si falla con rareza, probamos sin ella
            if (-not $script:LastOk) {
                $addArgsRetry = $addArgs | Where-Object { $_ -ne '--rarity' -and $_ -ne $rar }
                $oAdd = @(Invoke-DI2 $addArgsRetry)
            }

            if (-not $script:LastOk) {
                Say "   [$k/$nc] FALLO al anadir $($it.Name)" Red
                Say ("   " + (($oAdd -join "`n") -replace "`n", "`n   ")) DarkGray
                $fail++
                continue
            }

            # --- Extraer nuevo ID ---
            $txt = $oAdd -join "`n"
            $newId = $null
            if ($txt -match '\b([0-9a-fA-F]{32})\b') { $newId = $matches[1] }

            if ($newId) {
                Say "   [$k/$nc] Anadido con ID $newId" Green
            } else {
                Say "   [$k/$nc] Anadido (sin ID visible)" Green
            }

            # --- Aplicar mejoras si se pidio ---
            if ($aplicarTodas -and $newId) {
                [void](Add-AllUpgrades $newId $container)
            }

            $ok++
        }
    }

    Say ''
    Say "Resumen: $ok copias creadas, $fail fallos." Cyan
    if ($fail -gt 0) {
        Say 'Los items que fallen puede que no acepten los parametros enviados.' DarkGray
        Say 'Prueba a anadirlos uno a uno con diferentes rarezas/niveles.' DarkGray
    }
}

# ---------------- Programa principal ----------------
Load-Cfg
Find-Exe
Find-Save

$g = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'DeadIsland*' })
if ($g.Count -gt 0) {
    Say 'AVISO: Dead Island 2 parece estar abierto. Cierralo antes de editar el guardado.' Yellow
}
Say "Herramienta: $script:Exe" DarkGray
Say "Guardado:    $script:Save" DarkGray
Say 'Todas las operaciones di2save usan --no-version-safety' Yellow
Select-Profile

while ($true) {
    Clear-Host
    Say '============================================================' Cyan
    Say '       DEAD ISLAND 2 - GESTOR DE ARMAS (di2save)' Cyan
    Say '============================================================' Cyan
    Say "Personaje: $($script:ProfLabel)" DarkGray
    Say ''
    Say '  1. Ver inventario / armas'
    Say '  2. Anadir arma(s)'
    Say '  3. Modificar MULTIPLES armas (rareza/nivel/mejoras)'
    Say '  4. Aplicar TODAS las mejoras (~118) a MULTIPLES armas'
    Say '  5. Ver TODAS las mejoras instaladas de MULTIPLES armas'
    Say '  6. Eliminar MULTIPLES armas'
    Say '  7. Eliminar TODAS las armas de melee o a distancia'
    Say '  8. Eliminar multiples items (no solo armas)'
    Say '  9. Gestionar nivel del personaje (MAX / exacto / reset)'
    Say ' 10. Municion Maxima'
    Say ' 11. Dinero Maximo'
    Say ' 12. Desbloquear TODO (blueprints + curveballs)'
    Say ' 13. Gestionar alijo (STASH)'
    Say ' 14. Cambiar de personaje'
    Say ' 15. Explorar ítems especiales (IA, debug)'
    Say '  0. Salir'
    Say ''
    $op = (Read-Host 'Opcion').Trim()
    Say ''

    switch ($op) {
        '1'  { Ver-Inventario; Pausa }
        '2'  { Anadir-Arma; Pausa }
        '3'  { Mejorar-Existente; Pausa }
        '4'  { Aplicar-Upgrades-Multiples; Pausa }
        '5'  { Ver-Mejoras-Multiples; Pausa }
        '6'  { Eliminar-Armas-Multiples; Pausa }
        '7'  { Eliminar-Armas-Por-Categoria; Pausa }
        '8'  { Eliminar-Items; Pausa }
        '9'  { Gestionar-Nivel; Pausa }
        '10' { Municion-Maxima; Pausa }
        '11' { Dinero-Maximo; Pausa }
        '12' { Desbloquear-Todo; Pausa }
        '13' { Gestionar-Stash }
        '14' { Select-Profile }
		'15' { Ver-ItemsEspeciales; Pausa }
        '0'  { return }
        default {
            Say 'Opcion no valida.' Yellow
            Start-Sleep -Milliseconds 800
        }
    }
}
