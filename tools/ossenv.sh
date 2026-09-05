# Source this to put the OSS CAD Suite (iverilog, vvp, yosys, nextpnr,
# icepack) on PATH, plus a mingw-w64 toolchain if winget installed one.
#
#     source tools/ossenv.sh
#     OSS_CAD_ROOT=/opt/oss-cad-suite source tools/ossenv.sh
#
# Get the suite from https://github.com/YosysHQ/oss-cad-suite-build/releases.
# On Windows its DLLs live in lib/, which is why that is on PATH too.

: "${OSS_CAD_ROOT:=/c/temp/tools/oss-cad-suite}"
export OSS_CAD_ROOT
export PATH="$OSS_CAD_ROOT/bin:$OSS_CAD_ROOT/lib:$PATH"
[ -f "$OSS_CAD_ROOT/etc/cacert.pem" ] && export SSL_CERT_FILE="$OSS_CAD_ROOT/etc/cacert.pem"

# Vivado, for the Arty A7-100T flow.  Override with VIVADO_ROOT.
: "${VIVADO_ROOT:=/c/s/AMDDesignTools/2026.1/Vivado}"
[ -d "$VIVADO_ROOT/bin" ] && export PATH="$PATH:$VIVADO_ROOT/bin"

# WinLibs mingw-w64, if `winget install BrechtSanders.WinLibs.POSIX.UCRT` put
# one here.  It supplies mingw32-make, which Windows otherwise lacks, and a
# C++ compiler for Verilator.
for _wl in "${LOCALAPPDATA:-$HOME/AppData/Local}"/Microsoft/WinGet/Packages/BrechtSanders.WinLibs.*/mingw64/bin; do
    [ -d "$_wl" ] && export PATH="$PATH:$_wl"
done
unset _wl
