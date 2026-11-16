<# A script. #>
param([string]$Name = "world")

# Greet.
function Show-Greeting {
    Write-Host "Hello, $Name"
}

if ($Name -eq 'world') { Show-Greeting }
$text = @"
two lines
"@
