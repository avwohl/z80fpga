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

# The suite ships its own python3 (in lib/ on Windows), and once the suite is
# on PATH that python3 shadows yours.  Keep the Makefile on yours: the pip
# packages (pyserial, ftd2xx, um80) are installed there, and the suite's
# Windows python3 is a MinGW 3.11 whose timed socket calls fail with "unable
# to select on socket" once a handle value passes FD_SETSIZE -- which made
# tools/test_z80dbg_bridge.py fail or pass depending on handle numbers.
if [ -z "${PYTHON:-}" ]; then
    for _py in python3 python; do
        _p=$(command -v "$_py" 2>/dev/null) || continue
        case "$_p" in "$OSS_CAD_ROOT"/*) continue ;; esac
        "$_p" -c "" >/dev/null 2>&1 || continue   # the Store's python3 stub
        export PYTHON="$_p"
        break
    done
    unset _py _p
fi

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
