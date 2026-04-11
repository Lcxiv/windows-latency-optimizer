# pipeline-helpers.ps1
# Backwards-compatible shim that loads all helper modules.
# Previously a 1,682-line monolith; now split into domain-specific files
# under scripts/helpers/ for maintainability.
#
# Usage (unchanged): . "$PSScriptRoot\pipeline-helpers.ps1"
# PowerShell 5.1 compatible.

# Load central config (tool paths, defaults, project paths)
if (-not $script:ToolPaths) {
    . "$PSScriptRoot\config.ps1"
}

# Load helper modules in dependency order
. "$PSScriptRoot\helpers\logging.ps1"
. "$PSScriptRoot\helpers\experiment.ps1"
. "$PSScriptRoot\helpers\capture-core.ps1"
. "$PSScriptRoot\helpers\capture-tools.ps1"
. "$PSScriptRoot\helpers\network.ps1"
. "$PSScriptRoot\helpers\smi-detect.ps1"
