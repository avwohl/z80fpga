# QuickLogic Qomu (EOS S3)

**The core does not fit on this board, and no configuration of it will.**
This note exists so the question does not have to be re-opened.

The Qomu carries an EOS S3, which pairs a Cortex-M4F with a small eFPGA
fabric: **891 logic cells**, 8 KB of fabric RAM, and two multipliers. The
smallest whole SoC in this tree is the one in
[../c0_microsd/README.md](../c0_microsd/README.md), and it measures **5076 of
an iCE40UP5K's 5280 logic cells** -- nearly six times the Qomu's fabric, with
the RAM in SPRAM rather than in cells. The core on its own is a few hundred
cells less than that, which does not change the arithmetic: this file used to
quote "about 4700 four-input LUTs and 420 flip-flops" and cite that README for
them, and no such pair of numbers is in it. Cutting it down to fit would mean giving up
the microcode ROM, the second register set, or the index registers — at which
point it is not a Z80 any more.

## What the Qomu is good for here

Two things, neither of them on the roadmap yet:

- **A peripheral for a Z80 that lives elsewhere.** The eFPGA is a reasonable
  home for a UART, a bank-register decoder, or an SD-card interface driven by
  the M4F, talking to a Z80 on another board.
- **Running an emulator rather than the core.** The M4F can run
  [avwohl/cpmemu](https://github.com/avwohl/cpmemu)'s `qkz80` interpreter
  directly. That is a software port, not a gateware one.

If a very small Z80 is ever wanted for its own sake, the shape that fits a
part this size is a bit-serial datapath with a multi-cycle ALU — a different
core, sharing only the instruction description in `tools/`.
