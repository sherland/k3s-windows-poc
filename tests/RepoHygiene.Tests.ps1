# =============================================================================
# tests/RepoHygiene.Tests.ps1
# Fast, no-VM checks: shell script line endings, PowerShell/Packer syntax,
# YAML parseability, and version-pin drift between config/variables.ps1 and
# the fallback defaults scattered across packer scripts/templates.
#
# Run: Invoke-Pester -Path tests/RepoHygiene.Tests.ps1 -Output Detailed
# =============================================================================

BeforeDiscovery {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ShFiles    = @(Get-ChildItem -Path $script:RepoRoot -Filter '*.sh'   -Recurse -File)
    $script:PsFiles    = @(Get-ChildItem -Path $script:RepoRoot -Filter '*.ps1'  -Recurse -File)
    $script:YamlFiles  = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'config\cni') -Filter '*.yaml' -File)
    $script:HavePacker = [bool](Get-Command packer -ErrorAction SilentlyContinue)
}

Describe 'Shell script line endings' {
    It 'has at least one shell script to check' {
        $ShFiles.Count | Should -BeGreaterThan 0
    }

    It '<_.Name> has no CRLF line endings' -ForEach $ShFiles {
        $content = Get-Content -Raw -LiteralPath $_.FullName
        $content | Should -Not -Match "`r`n" -Because 'CRLF breaks bash (e.g. set -euo pipefail<CR> parses as an invalid option)'
    }
}

Describe 'PowerShell syntax' {
    It 'has at least one PowerShell script to check' {
        $PsFiles.Count | Should -BeGreaterThan 0
    }

    It '<_.Name> parses without errors' -ForEach $PsFiles {
        $parseErrors = [System.Management.Automation.Language.ParseError[]]@()
        $tokens      = [System.Management.Automation.Language.Token[]]@()
        $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0 -Because ($parseErrors -join '; ')
    }
}

Describe 'Packer templates' -Tag 'RequiresPacker' {
    BeforeAll {
        if ($HavePacker) {
            # `packer init` downloads the hyperv plugin these templates require --
            # `packer validate` alone doesn't do this, and fails with "Missing
            # plugins" on a runner that has never built with these templates
            # before (e.g. a fresh CI checkout).
            Push-Location (Join-Path $RepoRoot 'packer\linux');   packer init . 2>&1 | Out-Null; Pop-Location
            Push-Location (Join-Path $RepoRoot 'packer\windows'); packer init . 2>&1 | Out-Null; Pop-Location
        }
    }

    It 'validates ubuntu.pkr.hcl' -Skip:(-not $HavePacker) {
        Push-Location (Join-Path $RepoRoot 'packer\linux')
        try {
            $out = packer validate -var "iso_url=http://example.invalid/x.iso" -var "iso_checksum=none" ubuntu.pkr.hcl 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        } finally {
            Pop-Location
        }
    }

    It 'validates winserver.pkr.hcl' -Skip:(-not $HavePacker) {
        Push-Location (Join-Path $RepoRoot 'packer\windows')
        try {
            $out = packer validate -var "iso_path=x.iso" -var "os_version=2025" winserver.pkr.hcl 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        } finally {
            Pop-Location
        }
    }
}

Describe 'CNI manifest YAML' {
    It 'has at least one CNI manifest to check' {
        $YamlFiles.Count | Should -BeGreaterThan 0
    }

    It '<_.Name> parses as valid YAML' -ForEach $YamlFiles {
        { ConvertFrom-Yaml -Yaml (Get-Content -Raw -LiteralPath $_.FullName) -AllDocuments } | Should -Not -Throw
    }
}

Describe 'Version pin consistency (config/variables.ps1 vs. fallback defaults)' {
    BeforeAll {
        . (Join-Path $RepoRoot 'config\variables.ps1')
    }

    Context 'k3s / Kubernetes version' {
        It 'winserver.pkr.hcl k8s_version default matches K3sVersion (minus +k3sN suffix)' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\windows\winserver.pkr.hcl')
            $expected = ($script:K3sVersion -split '\+')[0]
            $content | Should -Match ([regex]::Escape("default = `"$expected`""))
        }

        It 'ubuntu.pkr.hcl k3s_version default matches K3sVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\linux\ubuntu.pkr.hcl')
            $content | Should -Match ([regex]::Escape("default = `"$script:K3sVersion`""))
        }

        It '02-install-k3s-binary.sh fallback default matches K3sVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\linux\scripts\02-install-k3s-binary.sh')
            $content | Should -Match ([regex]::Escape("K3S_VERSION:-$script:K3sVersion"))
        }

        It '02-k3s-server.sh fallback default matches K3sVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\linux\scripts\02-k3s-server.sh')
            $content | Should -Match ([regex]::Escape("K3S_VERSION:-$script:K3sVersion"))
        }
    }

    Context 'containerd version' {
        It 'winserver.pkr.hcl containerd_version default matches ContainerdVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\windows\winserver.pkr.hcl')
            $content | Should -Match ([regex]::Escape("default = `"$script:ContainerdVersion`""))
        }

        It '03-containerd.ps1 fallback default matches ContainerdVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\windows\scripts\03-containerd.ps1')
            $content | Should -Match ([regex]::Escape("`$ContainerdVersion = '$script:ContainerdVersion'"))
        }
    }

    Context 'flannel / windows-container-networking versions' {
        It '<_> fallback FlannelVersion default matches FlannelVersion' -ForEach @('04-install-k8s-binaries.ps1', '04-k3s-agent.ps1') {
            $content = Get-Content -Raw (Join-Path $RepoRoot "packer\windows\scripts\$_")
            $content | Should -Match ([regex]::Escape("else { '$script:FlannelVersion' }"))
        }

        It '<_> fallback WinCniVersion default matches WinsCniVersion' -ForEach @('04-install-k8s-binaries.ps1', '04-k3s-agent.ps1') {
            $content = Get-Content -Raw (Join-Path $RepoRoot "packer\windows\scripts\$_")
            $content | Should -Match ([regex]::Escape("else { '$script:WinsCniVersion' }"))
        }

        It 'winserver.pkr.hcl flannel_version default matches FlannelVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\windows\winserver.pkr.hcl')
            $content | Should -Match ([regex]::Escape("default = `"$script:FlannelVersion`""))
        }

        It 'winserver.pkr.hcl wins_cni_version default matches WinsCniVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'packer\windows\winserver.pkr.hcl')
            $content | Should -Match ([regex]::Escape("default = `"$script:WinsCniVersion`""))
        }
    }

    Context 'multus-cni image tag' {
        It 'multus-daemonset.yaml image tags match MultusVersion' {
            $content = Get-Content -Raw (Join-Path $RepoRoot 'config\cni\multus-daemonset.yaml')
            $matches = [regex]::Matches($content, 'multus-cni:v([\d.]+)-thick')
            $matches.Count | Should -BeGreaterThan 0
            $expected = $script:MultusVersion.TrimStart('v')
            foreach ($m in $matches) {
                $m.Groups[1].Value | Should -Be $expected
            }
        }
    }
}
