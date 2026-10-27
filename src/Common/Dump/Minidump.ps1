# Dump engine: pure byte-parse of minidump streams (signature, bitness, OS/CPU, comment). No tools, no symbols.

$script:CLR_EXCEPTION_CODE = 0xE0434352


# Reads only the small minidump streams (exception, miscinfo/pid, module list) - never the memory body.
# Returns kind + the faulting module/offset + enough signature detail for the registry entry, or $null
# if the file is not a minidump. Mirrors scripts/classify.ps1 Read-Dump.
function Get-DumpSignature([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $br = New-Object IO.BinaryReader($fs)
        if ($br.ReadUInt32() -ne 0x504D444D) { return $null }      # 'MDMP'
        [void]$br.ReadUInt32()                                     # version
        $nStreams = $br.ReadUInt32(); $dirRva = $br.ReadUInt32()

        $fs.Position = $dirRva
        $dirs = @(for ($i = 0; $i -lt $nStreams; $i++) { ,@($br.ReadUInt32(), $br.ReadUInt32(), $br.ReadUInt32()) })

        $code = $null; $threadId = $null; $address = $null; $procId = $null
        $osMajor = $null; $osMinor = $null; $osBuild = $null; $numProc = $null; $archCode = $null
        $comment = $null
        $modules = @()
        foreach ($d in $dirs) {
            $type = $d[0]; $size = $d[1]; $rva = $d[2]
            if ($type -eq 7 -and $size -ge 24) {                   # SystemInfoStream (OS + CPU of the DUMPED box)
                $fs.Position = $rva
                $archCode = $br.ReadUInt16(); [void]$br.ReadUInt16(); [void]$br.ReadUInt16()   # arch, level, revision
                $numProc = $br.ReadByte(); [void]$br.ReadByte()                                 # NumberOfProcessors, ProductType
                $osMajor = $br.ReadUInt32(); $osMinor = $br.ReadUInt32(); $osBuild = $br.ReadUInt32()
            }
            elseif ($type -eq 11 -and $size -ge 2) {               # CommentStreamW (ProcDump's note, e.g. "Hung window detected")
                $fs.Position = $rva
                $comment = [Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$size)).Trim([char]0, ' ', "`r", "`n")
            }
            elseif ($type -eq 10 -and $size -ge 1 -and -not $comment) {   # CommentStreamA (ANSI fallback)
                $fs.Position = $rva
                $comment = [Text.Encoding]::ASCII.GetString($br.ReadBytes([int]$size)).Trim([char]0, ' ', "`r", "`n")
            }
            elseif ($type -eq 6 -and $size -ge 40) {               # ExceptionStream
                $fs.Position = $rva
                $threadId = $br.ReadUInt32(); [void]$br.ReadUInt32()
                $code = $br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt64()
                $address = $br.ReadUInt64()
            }
            elseif ($type -eq 15 -and $size -ge 12) {              # MiscInfoStream (flags bit0 => pid valid)
                $fs.Position = $rva
                [void]$br.ReadUInt32(); $flags = $br.ReadUInt32(); $pval = $br.ReadUInt32()
                if ($flags -band 1) { $procId = $pval }
            }
            elseif ($type -eq 4) {                                 # ModuleListStream
                $fs.Position = $rva
                $nMod = $br.ReadUInt32()
                for ($j = 0; $j -lt $nMod; $j++) {
                    $base = $br.ReadUInt64(); $sizeImg = $br.ReadUInt32()
                    [void]$br.ReadUInt32()                         # CheckSum
                    $ts = $br.ReadUInt32()                         # TimeDateStamp
                    $nameRva = $br.ReadUInt32()
                    # VS_FIXEDFILEINFO: dwSignature,dwStrucVersion,dwFileVersionMS,dwFileVersionLS,...
                    [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
                    $verMS = $br.ReadUInt32(); $verLS = $br.ReadUInt32()
                    $fs.Position += (52 - 16) + 8 + 8 + 8 + 8       # rest of VS_FIXEDFILEINFO + Cv + Misc + Reserved0/1
                    $modules += [pscustomobject]@{ Base = $base; Size = $sizeImg; NameRva = $nameRva
                        TimeStamp = $ts; VerMS = $verMS; VerLS = $verLS; Name = $null }
                }
                foreach ($mod in $modules) {
                    $fs.Position = $mod.NameRva
                    $len = $br.ReadUInt32()
                    $full = [Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$len))
                    $mod.Name = [IO.Path]::GetFileNameWithoutExtension($full)
                }
            }
        }

        # resolve the faulting module + offset (never the absolute address)
        $module = $null; $offset = $null; $modVer = $null; $modTs = $null
        if ($address) {
            foreach ($mod in $modules) {
                if ($address -ge $mod.Base -and $address -lt ($mod.Base + $mod.Size)) {
                    $module = $mod.Name; $offset = $address - $mod.Base
                    $modVer = '{0}.{1}.{2}.{3}' -f ($mod.VerMS -shr 16), ($mod.VerMS -band 0xffff), ($mod.VerLS -shr 16), ($mod.VerLS -band 0xffff)
                    $modTs  = '0x{0:x8}' -f $mod.TimeStamp
                    break
                }
            }
        }

        $kind = if ($null -eq $code) { 'hang' }
                elseif ($code -eq $script:CLR_EXCEPTION_CODE) { 'managed-exception' }
                else { 'crash' }

        # Process image (minidumps list the main module first) and the CLR, with exact file versions - the
        # version facts a report's Environment table needs. Pure read of the already-parsed module list.
        $fmtVer = { param($m) '{0}.{1}.{2}.{3}' -f ($m.VerMS -shr 16), ($m.VerMS -band 0xffff), ($m.VerLS -shr 16), ($m.VerLS -band 0xffff) }
        $imageMod = if ($modules.Count) { $modules[0] } else { $null }
        $clrMod   = $modules | Where-Object { $_.Name -match '(?i)^(clr|coreclr|mscorwks)$' } | Select-Object -First 1

        # OS + CPU read from the dump itself (correct wherever analysis runs, unlike the local machine).
        $arch = switch ($archCode) { 9 { 'x64' } 0 { 'x86' } 12 { 'arm64' } 5 { 'arm' } 6 { 'ia64' } default { if ($null -ne $archCode) { "arch$archCode" } else { $null } } }
        $os   = if ($null -ne $osMajor) { 'Windows NT {0}.{1}.{2}' -f $osMajor, $osMinor, $osBuild } else { $null }

        [pscustomobject]@{
            Kind       = $kind
            Code       = if ($null -ne $code) { '{0:X8}' -f $code } else { $null }
            Module     = $module
            Offset     = $offset
            ModuleVer  = $modVer
            ModuleTs   = $modTs
            Address    = $address
            ProcessId  = $procId
            ThreadId   = $threadId
            ImageName  = if ($imageMod) { $imageMod.Name } else { $null }
            ImageVer   = if ($imageMod) { & $fmtVer $imageMod } else { $null }
            ClrName    = if ($clrMod) { $clrMod.Name } else { $null }
            ClrVer     = if ($clrMod) { & $fmtVer $clrMod } else { $null }
            Os         = $os
            Cpus       = $numProc
            Arch       = $arch
            ProcDumpComment = $comment
            Frames     = @()          # filled by Invoke-DumpWalk for Tier-2 kinds
            ExceptionType = $null     # filled by Invoke-DumpWalk for managed-exception dumps
            UiConfirmed    = $false   # set by Invoke-DumpWalk: the walked thread is the WPF Dispatcher thread
            DispatcherFrame = $null   # the Dispatcher frame that proves it (survives frame truncation)
            AppFrame       = $null    # the application (non-framework) frame nearest the leaf - what implicates the software
            StormOperations = @()     # WPF activity classes on the stack (data-binding / resource-lookup / layout / visual-tree-walk)
            StormDominantFrame = $null # the most-repeated framework frame (the recursion driver)
            StormDominantCount = 0     # how many times it repeats (recursion depth signal)
            StackDepth     = 0         # total managed frames on the thread (true depth, not truncated)
        }
    } finally { $fs.Dispose() }
}


# Bitness of the DUMPED PROCESS (not the machine). SystemInfo.ProcessorArchitecture reports the OS/CPU arch,
# so on a 64-bit OS it is x64 even for a 32-bit (WOW64) process - useless here. The reliable signal is that a
# WOW64 process always has wow64.dll loaded. So: wow64.dll in the module list => 32-bit; else fall back to the
# SystemInfo arch (covers a genuine 32-bit OS). Returns 32 or 64 (0 if unknown).
function Get-DumpBitness([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $br = New-Object IO.BinaryReader($fs)
            if ($br.ReadUInt32() -ne 0x504D444D) { return 0 }
            [void]$br.ReadUInt32(); $n = $br.ReadUInt32(); $dir = $br.ReadUInt32()
            $fs.Position = $dir
            $dirs = @(for ($i = 0; $i -lt $n; $i++) { ,@($br.ReadUInt32(), $br.ReadUInt32(), $br.ReadUInt32()) })
            $sysArch = $null
            foreach ($d in $dirs) {
                if ($d[0] -eq 7) { $fs.Position = $d[2]; $sysArch = $br.ReadUInt16() }
                elseif ($d[0] -eq 4) {                                   # ModuleList: look for wow64.dll
                    $fs.Position = $d[2]; $nMod = $br.ReadUInt32()
                    $nameRvas = @()
                    for ($j = 0; $j -lt $nMod; $j++) {
                        [void]$br.ReadUInt64(); [void]$br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
                        $nameRvas += $br.ReadUInt32(); $fs.Position += 52 + 8 + 8 + 8 + 8
                    }
                    foreach ($nr in $nameRvas) {
                        $fs.Position = $nr; $len = $br.ReadUInt32()
                        $nm = [Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$len))
                        if ($nm -match '(?i)\\wow64\.dll$') { return 32 }
                    }
                }
            }
            if ($null -ne $sysArch) { return $(if ($sysArch -eq 9 -or $sysArch -eq 12) { 64 } else { 32 }) }
            return 0
        } finally { $fs.Dispose() }
    } catch { return 0 }
}

