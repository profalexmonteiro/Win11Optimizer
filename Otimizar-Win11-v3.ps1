#Requires -Version 5.1
<#
=====================================================================
  Otimizacao Windows 11 v3 - RAM, prioridade de primeiro plano e VMware
---------------------------------------------------------------------
  - Menu de perfis: Seguro / Agressivo / So VMware
  - Toda alteracao e registrada em %ProgramData%\OtimizacaoWin11\estado.json
    com o valor ORIGINAL, permitindo reversao automatica (opcao 4).
  - Log completo de cada execucao na mesma pasta.
  - Rodar pelo Executar.bat (abre como Administrador).

  Observacao: ajustes em HKCU valem para o usuario que executa.
  Rode logado na sua propria conta (que deve ser administradora).
=====================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$ScriptVersion = '3.0'

# ------------------------------------------------------------------
# Verificacao de administrador
# ------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Execute como Administrador (use o Executar.bat).' -ForegroundColor Red
    Read-Host 'Pressione Enter para sair'
    exit 1
}
# Ponto de restauracao, MMAgent e Appx so funcionam bem no Windows PowerShell 5.1
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'Rode no Windows PowerShell 5.1 (use o Executar.bat), nao no PowerShell 7.' -ForegroundColor Red
    Read-Host 'Pressione Enter para sair'
    exit 1
}

# ------------------------------------------------------------------
# Pastas, log e estado
# ------------------------------------------------------------------
$StateDir  = Join-Path $env:ProgramData 'OtimizacaoWin11'
$StateFile = Join-Path $StateDir 'estado.json'
$BackupDir = Join-Path $StateDir 'backup'
$LogFile   = Join-Path $StateDir ('log_{0:yyyyMMdd_HHmmss}.txt' -f (Get-Date))
New-Item -ItemType Directory -Path $StateDir, $BackupDir -Force | Out-Null
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {}

$Latin1 = [Text.Encoding]::GetEncoding(28591)   # leitura/escrita byte a byte (preserva .vmx/.ini)
$script:VmFolder = $null
$script:NoXbox   = $false

$script:State = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $StateFile) {
    try {
        $loaded = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        foreach ($i in @($loaded)) { if ($i) { [void]$script:State.Add($i) } }
    } catch {
        Write-Host "Aviso: estado.json ilegivel, sera recriado. ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------
# Utilitarios de saida e perguntas
# ------------------------------------------------------------------
function Write-Step([string]$m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "   [OK] $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Write-Fail([string]$m) { Write-Host "   [X]  $m" -ForegroundColor Red }
function Write-Info([string]$m) { Write-Host "        $m" -ForegroundColor Gray }

function Ask([string]$q) {
    do { $a = (Read-Host "   $q (S/N)").Trim().ToUpper() } until ($a -eq 'S' -or $a -eq 'N')
    return ($a -eq 'S')
}

# ------------------------------------------------------------------
# Registro de estado (para reversao)
# ------------------------------------------------------------------
function Save-State {
    ConvertTo-Json -InputObject @($script:State) -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}
function Get-Record([string]$Type, [string]$Key) {
    foreach ($r in $script:State) { if ($r.Type -eq $Type -and $r.Key -eq $Key) { return $r } }
    return $null
}
function Add-Record([hashtable]$obj) {
    # So grava o PRIMEIRO estado visto (o original), mesmo rodando varias vezes
    if (-not (Get-Record $obj.Type $obj.Key)) {
        [void]$script:State.Add([pscustomobject]$obj)
        Save-State
    }
}

# ------------------------------------------------------------------
# Registro do Windows (rastreado)
# ------------------------------------------------------------------
function Save-RegOriginal([string]$Path, [string]$Name) {
    $key = "$Path|$Name"
    if (Get-Record 'Reg' $key) { return }
    $existed = $false; $old = $null; $oldKind = $null
    if (Test-Path -LiteralPath $Path) {
        $k = Get-Item -LiteralPath $Path
        if ($k.GetValueNames() -contains $Name) {
            $existed = $true
            $old     = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $oldKind = $k.GetValueKind($Name).ToString()
            if ($old -is [byte[]]) { $old = [int[]]$old }
        }
    }
    Add-Record @{ Type = 'Reg'; Key = $key; Path = $Path; Name = $Name; Existed = $existed; Value = $old; Kind = $oldKind }
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord')
    try {
        Save-RegOriginal $Path $Name
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
        return $true
    } catch {
        Write-Fail "Registro ${Path}\${Name}: $($_.Exception.Message)"
        return $false
    }
}

function Remove-Reg([string]$Path, [string]$Name) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).GetValueNames() -contains $Name)) {
        Save-RegOriginal $Path $Name
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------
# Servicos (rastreado)
# ------------------------------------------------------------------
function Set-Svc {
    param([string]$Name, [string]$Start = 'disabled', [string]$Desc = '')
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $regPath)) { return }   # nao existe nesta edicao
    if (-not (Get-Record 'Svc' $Name)) {
        $p = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
        $delayed = 0
        if ($p.PSObject.Properties.Name -contains 'DelayedAutostart') { $delayed = $p.DelayedAutostart }
        Add-Record @{ Type = 'Svc'; Key = $Name; Start = $p.Start; Delayed = $delayed }
    }
    $out = & sc.exe config $Name start= $Start 2>&1
    if ($LASTEXITCODE -eq 0) {
        if ($Start -eq 'disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        $label = $Name; if ($Desc) { $label = "$Name ($Desc)" }
        Write-Ok "Servico $label -> $Start"
    } else {
        Write-Warn2 "Servico ${Name}: $($out | Out-String)".Trim()
    }
}

# ------------------------------------------------------------------
# Arquivos .ini / .vmx (rastreado, com backup)
# ------------------------------------------------------------------
function Backup-File([string]$File) {
    $key = $File.ToLower()
    if (Get-Record 'File' $key) { return }
    $existed = Test-Path -LiteralPath $File
    $bk = $null
    if ($existed) {
        $bk = Join-Path $BackupDir ('{0:yyyyMMddHHmmss}_{1}_{2}' -f (Get-Date), [IO.Path]::GetFileName($File), ([guid]::NewGuid().ToString('N').Substring(0, 6)))
        Copy-Item -LiteralPath $File -Destination $bk -Force
    }
    Add-Record @{ Type = 'File'; Key = $key; Path = $File; Existed = $existed; Backup = $bk }
}

function Set-IniValues([string]$File, [hashtable]$Values) {
    Backup-File $File
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $File) { $lines.AddRange([string[]][IO.File]::ReadAllLines($File, $Latin1)) }
    foreach ($k in $Values.Keys) {
        $newLine = '{0} = "{1}"' -f $k, $Values[$k]
        $pattern = '^\s*' + [regex]::Escape($k) + '\s*='
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) { $lines[$i] = $newLine; $found = $true }
        }
        if (-not $found) { $lines.Add($newLine) }
    }
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($File, $lines, $Latin1)
}

function Get-IniValue([string[]]$Lines, [string]$Key) {
    foreach ($l in $Lines) {
        if ($l -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"')) { return $Matches[1] }
    }
    return $null
}

# ------------------------------------------------------------------
# Informacoes do ambiente
# ------------------------------------------------------------------
function Get-EnvInfo {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    [pscustomobject]@{
        Caption           = $os.Caption
        Build             = [int]$os.BuildNumber
        RamMB             = [math]::Floor($cs.TotalPhysicalMemory / 1MB)
        RamGB             = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        FreeMB            = [math]::Floor($os.FreePhysicalMemory / 1KB)
        Cores             = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
        Threads           = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        Laptop            = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        HypervisorPresent = [bool]$cs.HypervisorPresent
        VTFirmware        = $cpu[0].VirtualizationFirmwareEnabled
    }
}

function Get-VbsStatus {
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        switch ([int]$dg.VirtualizationBasedSecurityStatus) {
            0 { 'Desativado' }
            1 { 'Habilitado, mas nao em execucao' }
            2 { 'EM EXECUCAO' }
            default { 'Desconhecido' }
        }
    } catch { 'Desconhecido' }
}

function Get-VMwarePath {
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation', 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation', 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Player') {
        $p = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).InstallPath
        if ($p) { return $p }
    }
    return $null
}

function Test-VMwareClosed {
    $procs = Get-Process -Name 'vmware', 'vmware-vmx', 'vmplayer' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Warn2 'O VMware esta aberto. Feche-o (e desligue/suspenda as VMs) antes de continuar.'
        Read-Host '   Pressione Enter depois de fechar'
        if (Get-Process -Name 'vmware', 'vmware-vmx', 'vmplayer' -ErrorAction SilentlyContinue) {
            Write-Fail 'VMware ainda aberto - ajustes do VMware ignorados.'
            return $false
        }
    }
    return $true
}

function Get-VmFolder {
    if ($script:VmFolder) { return $script:VmFolder }
    $default = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Virtual Machines'
    $f = Read-Host "   Pasta onde ficam suas VMs [$default]"
    if (-not $f) { $f = $default }
    $f = $f.Trim('"', ' ')
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Warn2 "Pasta nao encontrada: $f"
        return $null
    }
    $script:VmFolder = (Resolve-Path -LiteralPath $f).Path
    return $script:VmFolder
}

# ------------------------------------------------------------------
# Ponto de restauracao
# ------------------------------------------------------------------
function New-RestorePoint {
    Write-Step 'Criando ponto de restauracao'
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prev = (Get-ItemProperty -LiteralPath $srKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    $ok = $false
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Libera a criacao imediata (o padrao e 1 a cada 24h)
        New-ItemProperty -LiteralPath $srKey -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description "Otimizacao Win11 v$ScriptVersion" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $ok = $true
        Write-Ok 'Ponto de restauracao criado.'
    } catch {
        Write-Warn2 "Nao foi possivel criar o ponto de restauracao: $($_.Exception.Message)"
    } finally {
        if ($null -eq $prev) { Remove-ItemProperty -LiteralPath $srKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -LiteralPath $srKey -Name SystemRestorePointCreationFrequency -Value $prev }
    }
    if (-not $ok) {
        return (Ask 'Continuar mesmo assim? (a reversao automatica pela opcao 4 continua disponivel)')
    }
    return $true
}

# ==================================================================
#  ETAPAS
# ==================================================================

function Step-FixV2 {
    Write-Step 'Corrigindo ajustes sem efeito/indesejados de versoes anteriores'
    # ClearPageFileAtShutdown nao economiza RAM, so deixa o desligamento lento
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 0 | Out-Null
    # AlwaysUnloadDll e ignorado desde o Windows 2000
    Remove-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'AlwaysUnloadDll'
    # Prioridade fixa da v2 (substituida pela prioridade nativa do VMware, so com a VM em foco)
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    foreach ($exe in 'vmware-vmx.exe', 'vmware.exe') {
        Remove-Reg "$ifeo\$exe\PerfOptions" 'CpuPriorityClass'
        Remove-Reg "$ifeo\$exe\PerfOptions" 'IoPriority'
    }
    Write-Ok 'Ajustes antigos corrigidos.'
}

function Step-Telemetry {
    Write-Step 'Telemetria e servicos sem uso'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 | Out-Null
    Write-Info 'Obs.: no Home/Pro o Windows aplica o nivel minimo "Obrigatorio" (equivale a 1).'
    $svcs = [ordered]@{
        'DiagTrack'        = 'telemetria'
        'dmwappushservice' = 'roteamento de mensagens WAP'
        'WerSvc'           = 'relatorio de erros'
        'MapsBroker'       = 'mapas offline'
        'RetailDemo'       = 'modo demonstracao de loja'
        'wisvc'            = 'Windows Insider'
        'Fax'              = 'fax'
        'PhoneSvc'         = 'telefonia'
        'WpcMonSvc'        = 'controle dos pais'
        'CSCService'       = 'arquivos offline'
    }
    foreach ($s in $svcs.Keys) { Set-Svc -Name $s -Start 'disabled' -Desc $svcs[$s] }
}

function Step-Background {
    Write-Step 'Edge, Widgets, apps em segundo plano, Bing, Recall e Game DVR'
    $r = @(
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'StartupBoostEnabled', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'BackgroundModeEnabled', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy', 'LetAppsRunInBackground', 2),
        @('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI', 'DisableAIDataAnalysis', 1),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI', 'AllowRecallEnablement', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI', 'DisableClickToDo', 1),
        @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 0)
    )
    foreach ($i in $r) { Set-Reg $i[0] $i[1] $i[2] | Out-Null }
    Write-Ok 'Edge sem pre-carregamento, Widgets/Recall/Bing/Game DVR desligados, apps da Store sem segundo plano.'
}

function Step-MMAgent {
    Write-Step 'Gerenciador de memoria (pre-carregamento de apps e compressao)'
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        Add-Record @{ Type = 'MMAgent'; Key = 'Prelaunch'; WasEnabled = [bool]$mm.ApplicationPrelaunch }
        if ($mm.ApplicationPrelaunch) { Disable-MMAgent -ApplicationPrelaunch -ErrorAction Stop }
        Write-Ok 'Pre-carregamento de apps da Store desativado.'
        if (-not $mm.MemoryCompression) {
            Write-Warn2 'A compressao de memoria esta DESLIGADA. Ela reduz o uso de RAM.'
            if (Ask 'Ligar a compressao de memoria (recomendado)?') {
                Add-Record @{ Type = 'MMComp'; Key = 'Compression'; WasEnabled = $false }
                Enable-MMAgent -MemoryCompression -ErrorAction Stop
                Write-Ok 'Compressao de memoria ligada.'
            }
        } else {
            Write-Ok 'Compressao de memoria ja esta ligada (mantida).'
        }
    } catch {
        Write-Warn2 "MMAgent indisponivel (o servico SysMain precisa estar ativo): $($_.Exception.Message)"
    }
}

function Step-Visual {
    Write-Step 'Efeitos visuais (transparencia e animacoes)'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 | Out-Null
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 | Out-Null
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String' | Out-Null
    Write-Ok 'Transparencia e animacoes desligadas (suavizacao de fontes mantida).'
}

function Step-Shutdown {
    Write-Step 'Tempo de encerramento de programas travados'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' '2000' 'String' | Out-Null
    Set-Reg 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' '2000' 'String' | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '5000' 'String' | Out-Null
    Write-Ok 'Apps: 2 s / servicos: 5 s.'
}

function Set-PowerPlan($Info) {
    Write-Step 'Plano de energia'
    if ($Info.Laptop -and -not (Ask 'Notebook detectado. Usar Desempenho Maximo (consome mais bateria)?')) {
        Write-Info 'Plano mantido.'
        return
    }
    $guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $orig = [regex]::Match((powercfg /getactivescheme | Out-String), $guidRx).Value
    Add-Record @{ Type = 'Power'; Key = 'Plan'; Original = $orig; Created = $null }
    $rec = Get-Record 'Power' 'Plan'

    $list = powercfg /list | Out-String
    $guid = $null
    if ($rec.Created -and ($list -match [regex]::Escape($rec.Created))) { $guid = $rec.Created }   # reaproveita (nao duplica)
    if (-not $guid) {
        $dup = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String
        $m = [regex]::Match($dup, $guidRx)
        if ($m.Success) { $guid = $m.Value; $rec.Created = $guid; Save-State }
    }
    if ($guid) {
        powercfg -setactive $guid | Out-Null
        Write-Ok "Desempenho Maximo ativo ($guid)."
    } elseif ($list -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
        powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
        Write-Ok 'Alto Desempenho ativo (Desempenho Maximo indisponivel neste PC).'
    } else {
        Write-Warn2 'Este PC (Modern Standby) so oferece o plano Equilibrado. Use o controle deslizante de energia em Configuracoes > Energia.'
    }
}

function Step-Hibernate($Info) {
    Write-Step 'Hibernacao / Inicializacao Rapida'
    if ($Info.Laptop -and -not (Ask 'Notebook detectado. Desligar hibernacao (libera disco do tamanho da RAM)?')) { return }
    $h = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    Add-Record @{ Type = 'Hibernate'; Key = 'H'; WasEnabled = ([int]$h -eq 1) }
    powercfg -h off | Out-Null
    Write-Ok 'Hibernacao desligada (libera o hiberfil.sys).'
}

function Set-Pagefile {
    Write-Step 'Memoria virtual (pagefile/swap)'
    $in = Read-Host '   Tamanho fixo do pagefile em GB [16]'
    $sizeGB = 16
    if ($in -match '^\d+$' -and [int]$in -ge 4) { $sizeGB = [int]$in }
    $drive  = $env:SystemDrive
    $freeGB = [math]::Floor((Get-PSDrive -Name $drive.TrimEnd(':')).Free / 1GB)
    $curMB  = (Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$drive*" } | Measure-Object -Property AllocatedBaseSize -Sum).Sum
    $availGB = $freeGB + [math]::Floor([double]$curMB / 1024)
    if ($availGB -lt ($sizeGB + 4)) {
        Write-Warn2 "Espaco insuficiente: $availGB GB disponiveis em $drive, necessario $($sizeGB + 4) GB. Pagefile NAO alterado."
        return
    }
    $mb = $sizeGB * 1024
    if (Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'PagingFiles' @("$drive\pagefile.sys $mb $mb") 'MultiString') {
        Write-Ok "Pagefile: $drive\pagefile.sys fixo em $sizeGB GB (inicial = maximo). Gerenciamento automatico desligado."
        Write-Info 'Pagefiles em outros discos foram removidos da configuracao.'
    }
}

function Show-Startup {
    Write-Step 'Programas que iniciam com o Windows (somente leitura)'
    $items = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Location, Command
    if ($items) {
        $items | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
        Write-Info 'Desative os desnecessarios em Configuracoes > Aplicativos > Inicializacao.'
    } else { Write-Info 'Nenhum item encontrado.' }
}

function Step-VMwareGlobal {
    Write-Step 'VMware: configuracao global e prioridade nativa'
    $vmPath = Get-VMwarePath
    if (-not $vmPath) { Write-Info 'VMware Workstation/Player nao encontrado - etapa ignorada.'; return }
    if (-not (Test-VMwareClosed)) { return }

    $global = @{
        'mainMem.useNamedFile'                = 'FALSE'   # sem arquivo .vmem: menos I/O em disco
        'MemTrimRate'                         = '0'       # nao "espreme" a RAM da VM
        'sched.mem.pshare.enable'             = 'FALSE'   # sem varredura de paginas compartilhadas
        'prefvmx.useRecommendedLockedMemSize' = 'TRUE'
    }
    Write-Info 'Reservar 100% da RAM das VMs em memoria fisica evita swap da VM,'
    Write-Info 'mas a VM NAO liga se nao houver RAM livre suficiente no host.'
    if (Ask 'Reservar 100% da RAM das VMs na memoria fisica?') { $global['prefvmx.minVmMemPct'] = '100' }

    Set-IniValues (Join-Path $env:ProgramData 'VMware\VMware Workstation\config.ini') $global
    Write-Ok 'config.ini global do VMware ajustado.'

    # Prioridade: Alta quando a VM esta em foco (entrada capturada), Normal fora dela
    Set-IniValues (Join-Path $env:APPDATA 'VMware\preferences.ini') @{
        'priority.grabbed'   = 'high'
        'priority.ungrabbed' = 'normal'
    }
    Write-Ok 'Prioridade do VMware: Alta com a VM em foco, Normal fora dela.'
}

function Step-Vmx($Info) {
    Write-Step 'VMware: ajustes em cada VM (.vmx)'
    if (-not (Get-VMwarePath)) { Write-Info 'VMware nao encontrado - etapa ignorada.'; return }
    if (-not (Test-VMwareClosed)) { return }
    $folder = Get-VmFolder
    if (-not $folder) { return }
    $vmxs = @(Get-ChildItem -LiteralPath $folder -Recurse -Filter '*.vmx' -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.vmx' })
    if ($vmxs.Count -eq 0) { Write-Warn2 'Nenhum arquivo .vmx encontrado.'; return }
    Write-Info "$($vmxs.Count) VM(s) encontrada(s)."
    $noSound = Ask 'Desativar a placa de som virtual das VMs (economiza CPU se nao usa audio)?'

    foreach ($v in $vmxs) {
        if (Get-ChildItem -LiteralPath $v.DirectoryName -Filter '*.lck' -ErrorAction SilentlyContinue) {
            Write-Warn2 "VM em uso ou travada (.lck), ignorada: $($v.Name)"
            continue
        }
        $lines = [IO.File]::ReadAllLines($v.FullName, $Latin1)
        $name  = Get-IniValue $lines 'displayName'; if (-not $name) { $name = $v.BaseName }
        $mem   = [int](Get-IniValue $lines 'memsize')
        $vcpu  = [int](Get-IniValue $lines 'numvcpus'); if ($vcpu -lt 1) { $vcpu = 1 }

        $vals = @{
            'mainMem.useNamedFile'    = 'FALSE'
            'MemTrimRate'             = '0'
            'sched.mem.pshare.enable' = 'FALSE'
            'vmx.log.keepOld'         = '1'
        }
        if ((Get-IniValue $lines 'serial0.fileType') -eq 'thinprint') { $vals['serial0.present'] = 'FALSE' }   # impressora virtual
        if ($noSound) { $vals['sound.present'] = 'FALSE' }

        Set-IniValues $v.FullName $vals
        Write-Ok "VM '$name' ajustada ($mem MB RAM, $vcpu vCPU)."

        # Alertas de dimensionamento
        if ($mem -gt [math]::Floor($Info.RamMB * 0.6)) {
            Write-Warn2 "  '$name' usa $mem MB = mais de 60% da RAM do host ($($Info.RamMB) MB). O host vai paginar; reduza a RAM da VM."
        }
        if ($vcpu -gt $Info.Cores) {
            Write-Warn2 "  '$name' tem $vcpu vCPUs, mais que os $($Info.Cores) nucleos fisicos. Isso costuma PIORAR o desempenho."
        }
    }
    Write-Info 'Dica: discos virtuais pre-alocados ("Allocate all disk space now") sao mais rapidos que os que crescem sob demanda.'
}

function Step-Defender {
    Write-Step 'Windows Defender: exclusao da pasta das VMs'
    try { Get-MpComputerStatus -ErrorAction Stop | Out-Null }
    catch { Write-Info 'Defender indisponivel (outro antivirus instalado?) - etapa ignorada.'; return }
    Write-Info 'Remove a verificacao em tempo real dos discos virtuais (grande ganho de I/O).'
    Write-Info 'Custo: arquivos nessa pasta deixam de ser verificados. So aceite se confiar nas VMs.'
    if (-not (Ask 'Adicionar exclusao da pasta das VMs e do processo vmware-vmx.exe?')) { return }
    $folder = Get-VmFolder
    if (-not $folder) { return }
    $pref = Get-MpPreference
    try {
        if (@($pref.ExclusionPath) -notcontains $folder) {
            Add-MpPreference -ExclusionPath $folder -ErrorAction Stop
            Add-Record @{ Type = 'DefPath'; Key = $folder.ToLower(); Value = $folder }
        }
        if (@($pref.ExclusionProcess) -notcontains 'vmware-vmx.exe') {
            Add-MpPreference -ExclusionProcess 'vmware-vmx.exe' -ErrorAction Stop
            Add-Record @{ Type = 'DefProc'; Key = 'vmware-vmx.exe'; Value = 'vmware-vmx.exe' }
        }
        Write-Ok "Exclusoes adicionadas: $folder e vmware-vmx.exe."
    } catch {
        Write-Fail "Falha ao adicionar exclusao (Defender gerenciado pela empresa?): $($_.Exception.Message)"
    }
}

function Step-SensitiveServices {
    Write-Step 'Servicos que podem fazer falta (um a um)'
    $list = @(
        @('WbioSrvc',      'leitor de digital / Windows Hello biometrico'),
        @('SensorService', 'sensores: brilho e rotacao automaticos em notebooks'),
        @('SCardSvr',      'leitor de cartao/token: e-CPF, certificado digital, alguns bancos'),
        @('lfsvc',         'localizacao do Windows'),
        @('SharedAccess',  'compartilhamento de internet / hotspot movel / Default Switch do Hyper-V')
    )
    foreach ($s in $list) {
        if (Ask "Desativar $($s[0]) ($($s[1]))?") { Set-Svc -Name $s[0] -Start 'disabled' -Desc $s[1] }
    }
}

function Step-OptionalServices {
    Write-Step 'Impressao, Xbox, SysMain e Indexacao'
    if (-not (Ask 'Voce usa impressora neste PC?')) { Set-Svc -Name 'Spooler' -Start 'disabled' -Desc 'impressao' }
    if (-not (Ask 'Voce joga jogos da Xbox/Game Pass neste PC?')) {
        $script:NoXbox = $true
        foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') { Set-Svc -Name $s -Start 'disabled' -Desc 'Xbox' }
    }
    Write-Info 'SysMain usa RAM em espera (cache), que e liberada na hora em que a VM precisa.'
    Write-Info 'Desativar NAO aumenta a memoria disponivel e pode deixar a abertura de programas mais lenta.'
    if (Ask 'Mesmo assim, desativar SysMain e a Indexacao de Pesquisa? (recomendado: N)') {
        Set-Svc -Name 'SysMain' -Start 'disabled' -Desc 'Superfetch'
        Set-Svc -Name 'WSearch' -Start 'disabled' -Desc 'Indexacao'
    }
}

function Step-Apps {
    Write-Step 'Apps pre-instalados que consomem RAM'
    $apps = [ordered]@{
        'Microsoft.Copilot'                      = 'Copilot'
        'MSTeams'                                = 'Teams (pessoal)'
        'MicrosoftTeams'                         = 'Teams (pessoal, versao antiga)'
        'Microsoft.YourPhone'                    = 'Vincular ao Celular'
        'Clipchamp.Clipchamp'                    = 'Clipchamp'
        'Microsoft.BingNews'                     = 'Noticias'
        'Microsoft.BingWeather'                  = 'Clima'
        'Microsoft.BingSearch'                   = 'Bing Search'
        'Microsoft.MicrosoftSolitaireCollection' = 'Paciencia'
        'Microsoft.GetHelp'                      = 'Obter Ajuda'
        'Microsoft.WindowsFeedbackHub'           = 'Hub de Comentarios'
        'Microsoft.PowerAutomateDesktop'         = 'Power Automate'
        'Microsoft.Todos'                        = 'Microsoft To Do'
        'Microsoft.549981C3F5F10'                = 'Cortana (antiga)'
    }
    if ($script:NoXbox) {
        $apps['Microsoft.GamingApp']                 = 'App Xbox'
        $apps['Microsoft.XboxGamingOverlay']         = 'Xbox Game Bar'
        $apps['Microsoft.XboxSpeechToTextOverlay']   = 'Xbox fala-texto'
    }
    $found = @()
    foreach ($n in $apps.Keys) {
        if (Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue) { $found += $n }
    }
    if ($found.Count -eq 0) { Write-Ok 'Nenhum dos apps da lista esta instalado.'; return }
    Write-Info 'Instalados:'
    foreach ($n in $found) { Write-Info " - $($apps[$n])" }
    Write-Info 'Eles podem ser reinstalados depois pela Microsoft Store.'
    if (-not (Ask 'Remover todos os apps listados?')) { return }

    foreach ($n in $found) {
        $ok = $true
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            catch {
                try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
                catch { $ok = $false; Write-Fail "$($apps[$n]): $($_.Exception.Message)" }
            }
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        if ($ok) {
            Add-Record @{ Type = 'Appx'; Key = $n; Desc = $apps[$n] }
            Write-Ok "Removido: $($apps[$n])"
        }
    }
}

function Step-OneDrive {
    Write-Step 'OneDrive'
    Write-Info 'Desativa o OneDrive por politica (reversivel). Arquivos "somente online" ficam inacessiveis ate reativar.'
    if (-not (Ask 'Desativar o OneDrive?')) { return }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1 | Out-Null
    Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok 'OneDrive desativado.'
}

function Test-Virtualization($Info) {
    Write-Step 'Virtualizacao do processador (VT-x / AMD-V)'
    if ($Info.HypervisorPresent) {
        Write-Ok 'Um hypervisor esta ativo, entao a virtualizacao esta habilitada na BIOS.'
    } elseif ($Info.VTFirmware -eq $false) {
        Write-Fail 'Virtualizacao DESLIGADA na BIOS/UEFI. Ative "Intel VT-x" ou "SVM/AMD-V" - sem isso a VM fica muito lenta.'
    } else {
        Write-Ok 'Virtualizacao habilitada na BIOS.'
    }
}

function Step-VBS {
    Write-Step 'Hyper-V / VBS (maior ganho para VMware)'
    Write-Info "Status atual do VBS: $(Get-VbsStatus)"
    Write-Info 'Com VBS/Hyper-V ativo, o VMware roda por cima do hypervisor da Microsoft e perde desempenho.'
    Write-Info 'Desativar DESLIGA: Integridade de Memoria, Credential Guard, WSL2, Windows Sandbox,'
    Write-Info 'Docker (WSL2) e o login biometrico com seguranca aprimorada.'
    if (-not (Ask 'Desativar Hyper-V/VBS?')) { return }

    $bcd = bcdedit /enum '{current}' | Out-String
    $m = [regex]::Match($bcd, 'hypervisorlaunchtype\s+(\S+)', 'IgnoreCase')
    $val = $null; if ($m.Success) { $val = $m.Groups[1].Value }
    Add-Record @{ Type = 'Bcd'; Key = 'hypervisorlaunchtype'; Existed = $m.Success; Value = $val }
    bcdedit /set hypervisorlaunchtype off | Out-Null

    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0 | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0 | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags' 0 | Out-Null
    Write-Ok 'Hyper-V/VBS desativados (efeito apos reiniciar).'
    Write-Info 'Depois do reboot, use a opcao 5 (Status) para confirmar. Se continuar "EM EXECUCAO",'
    Write-Info 'o Credential Guard pode estar travado por UEFI ou politica da empresa.'
}

# ==================================================================
#  REVERSAO
# ==================================================================
function Invoke-Revert {
    Write-Step 'Reversao automatica'
    if ($script:State.Count -eq 0) { Write-Warn2 'Nenhuma alteracao registrada para reverter.'; return }
    Write-Info "$($script:State.Count) alteracao(oes) registrada(s)."
    if (-not (Ask 'Reverter TODAS as alteracoes para o estado original?')) { return }

    $appx = @()
    for ($i = $script:State.Count - 1; $i -ge 0; $i--) {
        $r = $script:State[$i]
        try {
            switch ($r.Type) {
                'Reg' {
                    if ($r.Existed) {
                        if (-not (Test-Path -LiteralPath $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
                        $val = $r.Value
                        if ($r.Kind -eq 'Binary') { $val = [byte[]]$val }
                        elseif ($r.Kind -eq 'MultiString') { $val = [string[]]$val }
                        New-ItemProperty -LiteralPath $r.Path -Name $r.Name -Value $val -PropertyType $r.Kind -Force | Out-Null
                    } else {
                        Remove-ItemProperty -LiteralPath $r.Path -Name $r.Name -Force -ErrorAction SilentlyContinue
                    }
                }
                'Svc' {
                    $mode = $null
                    switch ([int]$r.Start) {
                        2 { if ([int]$r.Delayed -eq 1) { $mode = 'delayed-auto' } else { $mode = 'auto' } }
                        3 { $mode = 'demand' }
                        4 { $mode = 'disabled' }
                    }
                    if ($mode) {
                        & sc.exe config $r.Key start= $mode | Out-Null
                        if ($mode -like '*auto') { Start-Service -Name $r.Key -ErrorAction SilentlyContinue }
                    }
                }
                'MMAgent' { if ($r.WasEnabled) { Enable-MMAgent -ApplicationPrelaunch -ErrorAction SilentlyContinue } }
                'MMComp'  { if (-not $r.WasEnabled) { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } }
                'File' {
                    if ($r.Existed -and $r.Backup -and (Test-Path -LiteralPath $r.Backup)) {
                        Copy-Item -LiteralPath $r.Backup -Destination $r.Path -Force
                    } elseif (-not $r.Existed) {
                        Remove-Item -LiteralPath $r.Path -Force -ErrorAction SilentlyContinue
                    }
                }
                'Power' {
                    if ($r.Original) { powercfg -setactive $r.Original | Out-Null }
                    if ($r.Created)  { powercfg -delete $r.Created | Out-Null }
                }
                'Hibernate' { if ($r.WasEnabled) { powercfg -h on | Out-Null } }
                'Bcd' {
                    if ($r.Existed) { bcdedit /set hypervisorlaunchtype $r.Value | Out-Null }
                    else { bcdedit /deletevalue hypervisorlaunchtype | Out-Null }
                }
                'DefPath' { Remove-MpPreference -ExclusionPath $r.Value -ErrorAction SilentlyContinue }
                'DefProc' { Remove-MpPreference -ExclusionProcess $r.Value -ErrorAction SilentlyContinue }
                'Appx'    { $appx += $r.Desc }
            }
            Write-Ok "$($r.Type): $($r.Key)"
        } catch {
            Write-Fail "$($r.Type) $($r.Key): $($_.Exception.Message)"
        }
    }

    $archive = Join-Path $StateDir ('estado_revertido_{0:yyyyMMdd_HHmmss}.json' -f (Get-Date))
    Move-Item -LiteralPath $StateFile -Destination $archive -Force
    $script:State.Clear()
    Write-Ok "Reversao concluida. Registro arquivado em: $archive"
    if ($appx.Count -gt 0) {
        Write-Warn2 'Apps removidos nao voltam automaticamente. Reinstale pela Microsoft Store se quiser:'
        Write-Info ($appx -join ', ')
    }
    Write-Warn2 'REINICIE o computador para concluir a reversao.'
}

# ==================================================================
#  STATUS
# ==================================================================
function Show-Status {
    Write-Step 'Status do sistema'
    $i = Get-EnvInfo
    $usedGB = [math]::Round(($i.RamMB - $i.FreeMB) / 1024, 1)
    Write-Info "Sistema:           $($i.Caption) (build $($i.Build))"
    Write-Info "RAM:               $($i.RamGB) GB total, ~$usedGB GB em uso, $([math]::Round($i.FreeMB/1024,1)) GB disponivel"
    Write-Info "CPU:               $($i.Cores) nucleos / $($i.Threads) threads"
    Write-Info "Notebook:          $($i.Laptop)"
    Write-Info "Hypervisor ativo:  $($i.HypervisorPresent)"
    Write-Info "VBS:               $(Get-VbsStatus)"
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        Write-Info "Compressao de RAM: $($mm.MemoryCompression)   Pre-carregamento de apps: $($mm.ApplicationPrelaunch)"
    } catch {}
    foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) {
        Write-Info "Pagefile:          $($pf.Name) - $($pf.AllocatedBaseSize) MB alocados, $($pf.CurrentUsage) MB em uso"
    }
    $plan = (powercfg /getactivescheme | Out-String).Trim()
    Write-Info "Energia:           $plan"
    $vm = Get-VMwarePath
    if ($vm) { Write-Info "VMware:            $vm" } else { Write-Info 'VMware:            nao encontrado' }
    Write-Info "Alteracoes registradas para reversao: $($script:State.Count)"
    Write-Info "Pasta de estado/logs: $StateDir"
}

# ==================================================================
#  PERFIS
# ==================================================================
function Invoke-Profile([string]$Perfil) {
    $info = Get-EnvInfo
    Write-Host ''
    switch ($Perfil) {
        'Seguro'    { Write-Host '  Perfil SEGURO: nada que quebre recursos do dia a dia.' -ForegroundColor White }
        'Agressivo' { Write-Host '  Perfil AGRESSIVO: Seguro + remocao de apps, servicos opcionais, VMs, Defender e Hyper-V/VBS (tudo perguntado).' -ForegroundColor White }
        'VMware'    { Write-Host '  Perfil SO VMWARE: apenas o que afeta o desempenho das VMs.' -ForegroundColor White }
    }
    if (-not (Ask "Aplicar o perfil $Perfil?")) { return }
    if (-not (New-RestorePoint)) { return }

    Step-FixV2
    switch ($Perfil) {
        'Seguro' {
            Step-Telemetry; Step-Background; Step-MMAgent; Step-Visual; Step-Shutdown
            Set-PowerPlan $info; Step-Hibernate $info; Set-Pagefile
            Step-VMwareGlobal; Show-Startup
        }
        'Agressivo' {
            Test-Virtualization $info
            Step-Telemetry; Step-Background; Step-MMAgent      # MMAgent antes do SysMain
            Step-Visual; Step-Shutdown
            Step-SensitiveServices; Step-OptionalServices
            Step-Apps; Step-OneDrive
            Set-PowerPlan $info; Step-Hibernate $info; Set-Pagefile
            Step-VMwareGlobal; Step-Vmx $info; Step-Defender
            Step-VBS; Show-Startup
        }
        'VMware' {
            Test-Virtualization $info
            Step-VMwareGlobal; Step-Vmx $info; Step-Defender
            Set-PowerPlan $info; Set-Pagefile
            Step-VBS
        }
    }

    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Green
    Write-Host '  Perfil aplicado. Para desfazer tudo: opcao 4 do menu.' -ForegroundColor Green
    Write-Host "  Log: $LogFile" -ForegroundColor Green
    Write-Host '======================================================' -ForegroundColor Green
    if (Ask 'Reiniciar agora para aplicar tudo?') {
        try { Stop-Transcript | Out-Null } catch {}
        Restart-Computer -Force
    }
}

# ==================================================================
#  MENU
# ==================================================================
$sair = $false
while (-not $sair) {
    Clear-Host
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host "   Otimizacao Windows 11 v$ScriptVersion - RAM e VMware"      -ForegroundColor Cyan
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '  1) Seguro     - telemetria, segundo plano, energia, pagefile, VMware global'
    Write-Host '  2) Agressivo  - Seguro + apps, servicos opcionais, VMs, Defender, Hyper-V/VBS'
    Write-Host '  3) So VMware  - apenas ajustes de desempenho das VMs'
    Write-Host '  4) Reverter   - desfaz TODAS as alteracoes registradas'
    Write-Host '  5) Status     - diagnostico do sistema'
    Write-Host '  6) Sair'
    Write-Host ''
    Write-Host "  Alteracoes registradas: $($script:State.Count)" -ForegroundColor DarkGray
    $op = Read-Host '  Escolha'
    switch ($op) {
        '1' { Invoke-Profile 'Seguro' }
        '2' { Invoke-Profile 'Agressivo' }
        '3' { Invoke-Profile 'VMware' }
        '4' { Invoke-Revert }
        '5' { Show-Status }
        '6' { $sair = $true }
        default { Write-Warn2 'Opcao invalida.' }
    }
    if (-not $sair) { Read-Host "`n  Pressione Enter para voltar ao menu" | Out-Null }
}
try { Stop-Transcript | Out-Null } catch {}
