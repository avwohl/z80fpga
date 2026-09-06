# Getting a Vivado license

Vivado 2026.1 renamed the free tier and, for the first time, made it need a
license file. Any tutorial written before mid-2026 describes the arrangement
that came before — which is most of the board guides out there, for the Arty
and Nexys boards among others — so following one now leaves you hunting for a
download and a license option that no longer exist.

This is what the free license is called today, how to get it, and how to make
Vivado actually use the one you have.

## What changed

Through 2025.2 the free edition was Vivado ML Standard, and WebPACK before
that. It needed no license at all. AMD's licensing FAQ still says so:

> Does Vivado ML Standard Edition (2025.2 and previous versions) require a
> FLEX License? No, Vivado Standard Edition does not require a license.

From 2026.1 the editions are gone. There is one product, Vivado Design Suite,
and five license *tiers* — Basic, Core, Pro, Enterprise, Gold. The free one is
Basic, and unlike Standard it is a real FLEX license you have to obtain:

> Does Vivado BASIC (2026.1 and newer versions) required a FLEX License? Yes,
> Vivado BASIC need a valid annual license file in place. This license can be
> obtained free of charge from AMD Product Licensing website

It is also checked earlier than it used to be, which is why a missing license
now stops you at the splash screen rather than at `synth_design`:

> The biggest change in Vivado behavior with 2026.1 is that Vivado now checks
> for the license at the time of tool getting launched. This is unlike prior
> versions of Vivado, where the license check happens during the compilation
> step. If no valid license is found, then Vivado will not launch.

So an old guide is not wrong about its own era — it is describing 2025.2 or
earlier. If you would rather follow it as written, the escape hatch is to
install 2025.2 or older, where the free edition still needs nothing. On 2026.1
and later, read on.

## What to ask for

- **The tier** — Basic. Not "ML Standard": that name does not exist in 2026.1,
  so there is no install option and no licensing-portal row by that name. If
  you are scanning the portal for something that looks like the old free
  edition, you will not find it.
- **In the license file** — an `INCREMENT Vivado_Basic_Package` line, whose
  `VENDOR_STRING` contains `License_Tier:BASIC`.
- **At startup** — Vivado names the tier it settled on, and this is the
  quickest way to know you have it right:

```
INFO: [Common 17-3922] A valid Vivado Design Suite BASIC license has been detected.
```

## Does Basic cover this board?

For 7 Series, yes, all of it. UG973's *Device Availability by Subscription
Tier* gives Artix 7, Spartan 7, Kintex 7, Virtex 7 and Zynq 7000 as "All" in
the Basic column. That covers the Arty A7-100T this repo targets
(`xc7a100tcsg324-1`) and equally the Nexys A7, Basys 3, Cmod A7 and the rest
of the Digilent 7-series line.

Synthesis, implementation and plain bitstream generation do not appear in the
*Feature Availability by Subscription Tier* table at all, and that table says
"The features not listed below are available in all tiers without
restriction." An RTL-plus-XDC design that ends at a `.bit` — which is exactly
what this repo is — sits entirely inside the free tier.

What Basic does **not** give you, from that same table:

- **XSIM** — limited, 50K instance maximum.
- **ILA instantiation** — limited, 5 probes at 1024-bit maximum width. Debug
  insertion flows, System ILA and IBERT IP are not available at all.
- **Encrypted bitstream** — not available. Plain bitstream is unaffected.
- **DFX, incremental compile, RQA/RQS, Intelligent Design Runs** — not
  available.

Programming the board is fine: JTAG programming, indirect flash programming
and system/processor debug all read "Available" in the Basic column. None of
the restrictions above bites a design like this one until you want a serious
ILA.

## Getting one

UG973's *Create and Generate a License Key File* is the procedure. In short:

1. Sign in at <https://account.amd.com/en/forms/license/license-form.html> —
   the AMD Product Licensing site. You need an AMD account; it is free.
2. Choose the product licensing account.
3. Tick the Vivado Basic entitlement in the certificate-based entitlement
   table.
4. Click Generate License and enter your host ID. Node-locked licenses are one
   seat, locked to one machine, but uncounted on it — "there can be an
   unlimited number of simultaneous runs on the single machine".
5. Accept the agreement. The file arrives by email from
   `xilinx.notification@entitlenow.com`.

**Host ID** is a NIC MAC address, the C: drive serial number, or a dongle. The
Vivado License Manager lists the valid ones under *System Information*; from a
shell, `xlicdiag -v -o licdiag.txt` prints the same line FlexNet uses:

```
The FlexNet host ID of this machine is ""845c3199daa4 44f79f3b126b""
Only use ONE from the list of hostids.
```

`lmutil` gives the identical line, and is the only way to get the drive serial
(`lmhostid -vsn`) or a dongle ID (`lmhostid -flexid`), but it is **not** on
`PATH` — there is no wrapper for it beside `xlicdiag` and `vlm`, so call it by
full path under `Vivado\bin\unwrapped\win64.o\lmutil.exe`.

Those IDs come with the separators stripped and no adapter names, so map them
with `getmac /v /fo list` (or `ip link`) before choosing: `44f79f3b126b` above
is `44-F7-9F-3B-12-6B`, this machine's Wi-Fi card. Pick something built in that
will still be there next year, not a USB dock or a VPN adapter — and choose
only from the IDs FlexNet itself reports, which are fewer than `getmac` lists.
Locking to an ID FlexNet does not report gives a license that will not check
out, and correcting that spends one of your three reallocations.

**If there is no Basic row on "Create New Licenses"**, you have probably
already generated it: "A product is removed from the product entitlement table
after all seats are generated." A generated license lives under **Manage
Licenses**, where it can be re-downloaded or regenerated, not under Create New
Licenses. The rows that remain on Create New Licenses are the legacy
evaluation and no-charge certificates — ISE WebPACK, the pre-2015 Vivado HL
WebPACK, PetaLinux, the 60-day Enterprise evaluation. None of those is what
you want for a 7-series board, and the 60-day Enterprise evaluation in
particular is worth leaving alone: it expires, and Basic already covers this.

**Basic is annual.** AMD describes it as a free license with a mandatory free
annual renewal, so check the **expiry date** on your own `INCREMENT` lines —
the `dd-mmm-yyyy` field, not the `2027.09` version limit beside it — and put it
in the calendar.

**Do not delete a working license to start again.** Deleting seats hands the
entitlement back for reallocation, and that is rationed: "Administrators can
reallocate product entitlements five times per major release. End users can
reallocate product entitlements three times per major release", and "Before
the reallocation of entitlement occurs, you must first agree to an Affidavit
of Destruction." If the license is merely pointed at the wrong machine, the
Rehost option under Manage Licenses is the tool for that, not delete and
regenerate.

## Installing it

The Vivado License Manager does it for you: **Manage AMD Licenses** from the
start menu on Windows, or `vlm` on Linux, then *Getting a License* → *Load
License* → *Copy License*, and point it at the `.lic` file from the email.

That copies the file where the tools look for it on their own. UG973: "This
action copies the license file to the `%APPDATA%\XilinxLicense` (Windows) or
`<Home>/.Xilinx` directory of your computer where it is automatically found by
the AMD tools." Note the Windows directory is `XilinxLicense`, **not**
`Xilinx` — AMD's own FAQ still says `%APPDATA%\Xilinx` in places, and that is
stale. You can equally drop the file there yourself.

Then launch Vivado and read the tier off the banner quoted above.

## Vivado will not start

From 2026.1 the check happens at launch, so a licensing problem shows up as
Vivado never opening rather than as a synthesis error: "If no valid license is
found, then Vivado will not launch." Only the first of these was hit here; the
rest are the ordinary FLEX failure modes, in the order worth trying.

1. **Is Vivado even reading the file you edited?** On Windows that is decided
   by a search path rather than by `%APPDATA%`. See below.
2. **Does the host ID still exist?** Compare the `HOSTID=` field on the
   `INCREMENT` line against what the host-ID tools print today. An adapter that
   has been removed or disabled — a dock, a VPN adapter, Wi-Fi switched off —
   takes the license with it. The fix is Rehost under Manage Licenses, not
   delete and regenerate.
3. **Have the dates passed?** The expiry and the version limit are separate;
   see [Checking it](#checking-it). Basic is annual, so the expiry is the one
   that comes round.
4. **Only then suspect the tier**, below. That failure looks different: Vivado
   does launch, and announces the wrong tier.

### Which license file Vivado actually reads

Editing the file under `%APPDATA%` can appear to do nothing, because that is
not necessarily the file Vivado reads. It works down a search path and takes
the first license it finds. From the FAQ:

> 1 All the places listed by the environment variable XILINXD_LICENSE_FILE, if
> set. 2 Location cached for XILINXD_LICENSE_FILE in the registry
> ("HKLM\Software\FLEXlm License Manager") 3 All the places listed by the
> environment variable LM_LICENSE_FILE, if set. 4 %APPDATA%\Xilinx\*.lic

Two catches in that list. Row 4 is the *old* location — 2026.1's installer
writes to `%APPDATA%\XilinxLicense`. And row 2 names `HKLM`, but on 2026.1 here
the value was under `HKCU` and no `HKLM` key existed at all; check both.
Environment variables outrank everything below them, so read those first:

```powershell
$env:XILINXD_LICENSE_FILE
$env:LM_LICENSE_FILE
(Get-ItemProperty 'HKCU:\Software\FLEXlm License Manager' `
    -Name XILINXD_LICENSE_FILE -ErrorAction SilentlyContinue).XILINXD_LICENSE_FILE
```

That registry value is a semicolon-separated list which Vivado rewrites as it
goes, putting new entries at the front — including the directory you first
downloaded a license into. An earlier entry shadows the installed copy, and an
entry naming a directory rather than a file is searched alphabetically
("Directories will be searched for \*.lic"), so which license wins is decided
by what it happens to be called. That is what bit here: a stale download
directory sat ahead of the installed file, and editing the installed file
changed nothing until the list was read.

The safe fix is the environment variable. It is searched ahead of the registry
and touches nothing else:

```powershell
$env:XILINXD_LICENSE_FILE = "$env:APPDATA\XilinxLicense\Xilinx.lic"  # this shell
setx XILINXD_LICENSE_FILE "$env:APPDATA\XilinxLicense\Xilinx.lic"    # and after
```

```bash
export XILINXD_LICENSE_FILE=$HOME/.Xilinx/Xilinx.lic                 # Linux
```

Think hard before overwriting the registry value instead. It is shared by every
AMD tool on the machine, its entries "may be files, directories, and/or
PORT@HOST values", and a `port@server` entry is someone's floating license
server — overwrite it and their licensing goes with it, and there is no undo.
Save it first, and note that `Set-ItemProperty` fails outright on a machine
where the key was never created:

```powershell
$k = 'HKCU:\Software\FLEXlm License Manager'
(Get-ItemProperty $k -Name XILINXD_LICENSE_FILE).XILINXD_LICENSE_FILE |
    Out-File "$env:USERPROFILE\xilinxd_license_file.bak"
New-ItemProperty -Path $k -Name XILINXD_LICENSE_FILE -PropertyType String -Force `
    -Value "$env:APPDATA\XilinxLicense\Xilinx.lic"
```

It does not stay collapsed, either. Set to exactly one path here and read back
to confirm, it had a bare directory in front of the file again a few
`vivado -mode batch` runs later. Treat it as something to re-read rather than
something you fix once — which is the other reason to prefer the environment
variable.

## The trap: more than one tier in one file

If AMD has issued your account more than one tier, they can arrive in a single
`Xilinx.lic`, and then which one you get is decided by file order rather than
by what your design needs. The FAQ is blunt about it:

> Scenario 2: Node-locked licenses — Multiple tier licenses combined into a
> single license file. Administrators cannot reorder priority in this setup;
> the checkout behavior defaults to the first license feature listed in the
> file. AMD recommendation: Do NOT combine multiple tiers but instead split
> the license file by tier, and direct users to the needed tier via
> XILINXD_LICENSE_FILE. Do NOT specify only a directory; specify the
> appropriate directory/folder in XILINXD_LICENSE_FILE to make the search
> order to be alphabetical with respect to the license file names.

Observed on 2026.1 with a file holding an Alveo tier ahead of Basic: Vivado
announces `ALVEO`, and then

```
WARNING: [Device 21-9575] Your current selected license is ALVEO. This license
doesn't cover the device you selected.
ERROR: [Coretcl 2-106] Specified part could not be found.
```

The error names the part, so it reads like a missing device family — and it can
genuinely be one, because the installer lets you deselect device families, and
a machine without Artix-7 raises the same error under a perfectly good Basic
license. Two things tell the causes apart.

The cheap one is the startup banner: `BASIC` with no `[Device 21-9575]` warning
exonerates the license, and the installer is where to look instead. The precise
one is how many parts Vivado will admit to at all:

```tcl
llength [get_parts]                                ;# 0 = wrong tier, whole list hidden
llength [get_parts -filter {FAMILY == artix7}]     ;# 0 with a non-zero total = family absent
get_parts xc7a100tcsg324-1                         ;# empty either way
```

On the wrong tier the total is zero — the tier hides the entire device list,
not just your part. With Basic selected on the same install it ran to a few
hundred, 175 of them Artix-7. A non-zero total with none of your family in it
is the installer's doing, not the license's: re-run the installer, or *Add
Design Tools or Devices*, and add the family.

Do not read anything into the total itself. It is not stable even for one
license file: the same file that listed 361 parts here listed 289 a few hours
later, having quietly dropped the Kintex UltraScale+ family, with that family's
data still sitting on disk and nothing reinstalled in between. Zero versus
non-zero is the signal; the number is not. (This install exposed `aartix7`,
`artix7`, `artix7l` and `qartix7` as separate families; `artix7` is the one
holding `xc7a100tcsg324-1`.)

Putting the Basic increments first in the file is enough to change which tier
is taken — that was tried here and it works — but AMD's own advice, one tier
per file pointed at explicitly, is the version that will not surprise you
later. Copy the original to `Xilinx_basic.lic` and delete every `INCREMENT`
whose `VENDOR_STRING` names a tier other than `BASIC`, along with the matching
`PACKAGE` line. An `INCREMENT` is one logical line wrapped across several
physical ones with a trailing `\`, so remove the whole block down to its last
continued line, and change nothing inside the blocks that stay — each carries
its own signature, and whole-block deletion leaves the rest valid. A file
trimmed this way checked out as `BASIC` here. Then point
`XILINXD_LICENSE_FILE` at it, as above.

## Checking it

These run inside a Vivado that started. One that will not start at all is the
section above.

```tcl
# vivado -mode batch -source check.tcl
puts [llength [get_parts]]                            ;# 0 = wrong tier
puts [llength [get_parts -filter {FAMILY == artix7}]] ;# 0 but total non-zero = family absent
puts [get_parts xc7a100tcsg324-1]                     ;# the part you actually want
```

```
xlicdiag -v -o licdiag.txt   # environment, host IDs, version limit, and what it searched
```

A license carries two dates and both have to hold. The **version limit** — the
`2027.09` field on each `INCREMENT` line — is a tool-release cutoff rather than
an expiry: "The license will enable any version of the tool released before the
Version Limit", so `2027.09` covers 2026.1 comfortably. The **expiry date**
beside it is the hard stop, and since 2026.1 checks at launch, an expired Basic
license means Vivado does not start at all, whatever the version limit says. On
the license here the two land in the same month — version limit `2027.09`,
expiry `05-sep-2027` — and it is the expiry that bites. Diary it; regenerating
is free.

## Sources

- AMD, *Licensing FAQ* —
  <https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/licensing-faq.html>
- UG973, *Device Availability by Subscription Tier* —
  <https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Device-Availability-by-Subscription-Tier>
- UG973, *Feature Availability by Subscription Tier* —
  <https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Feature-Availability-by-Subscription-Tier>
- UG973, *Create and Generate a License Key File* —
  <https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Create-and-Generate-a-License-Key-File>
- UG973, *Install Certificate-Based Node-Locked License Key File* —
  <https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Install-Certificate-Based-Node-Locked-License-Key-File>
- UG973, *Reclaiming Deleted License Components* —
  <https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Reclaiming-Deleted-License-Components>

Everything quoted above was read from those pages in September 2026. The
observed Vivado messages are from 2026.1 (SW Build 6511674) on Windows 11,
building [boards/arty_a7_100t](../boards/arty_a7_100t/README.md).
