# Tests
The Pester tests in `Tests/` cover the modules and the helper functions of the step scripts. They mock all external calls and need neither Calibre nor Gemini nor LibreOffice. They use Pester v4-compatible syntax (`Should Be`), which Pester 5 no longer supports. Windows PowerShell 5.1 ships with Pester 3.4.0, which runs the tests:

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Path .\Tests
```

If Pester 4.x is installed, `Import-Module Pester -MaximumVersion 4.99` works as well.
