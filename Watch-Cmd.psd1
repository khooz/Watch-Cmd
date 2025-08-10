@{
  ModuleVersion      = '1.0.0'
  GUID               = '61bc2fd8-389b-4145-997f-0c0b632211d2'
  Author             = 'Mustafa Talaeezadeh Khouzani'
  Copyright          = '(c) 2025 Mustafa Talaeezadeh Khouzani'
  Description        = 'PowerShell drop-in replacement for Linux watch(1)'
  FunctionsToExport  = @('Watch-Command', 'Enable-AnsiColor', 'Remove-AnsiEscapes', 'Colorize', 'Invoke-ScrollClear')
  AliasesToExport    = @('watch', 'w')
  RootModule         = 'Watch-Command.psm1'
  FileList           = @('Watch-Cmd.psd1','Watch-Command.psm1')
  PrivateData        = @{
    PSData = @{
      Tags         = @('monitoring','cli','watch')
      LicenseUri   = 'https://raw.githubusercontent.com/khooz/Watch-Cmd/refs/heads/main/LICENSE'
      ProjectUri   = 'https://github.com/khooz/Watch-Cmd'
      ReleaseNotes = 'Initial release'
    }
  }
}