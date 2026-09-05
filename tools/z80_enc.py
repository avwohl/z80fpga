"""Micro-operation field encodings.

This file is the single source of truth: `gen_z80.py` emits both the microcode
ROM and the SystemVerilog `localparam`s from it, so the RTL and the microcode
assembler cannot drift apart.

Execution model
---------------
A micro-operation is `{action, bus cycle}`.  The action is applied on the clock
edge that *enters* the micro-op - the same edge on which the previous bus cycle
retires - so an action can consume the byte the previous cycle just read (DIN)
and the bus cycle that follows in the same micro-op already sees the action's
result.  `BUS.NONE` micro-ops cost zero T-states, so the following micro-op's bus cycle
starts on the same edge; that following micro-op therefore may not carry an
action of its own, because one edge can apply only one.

`pd` is the post-destination: the byte a read cycle brings in is written to it
when the cycle retires, which is the datapath the real part uses for operand
and return-address fetches.
"""

# ---------------------------------------------------------------- bus cycles
BUS = dict(
    NONE=0,   # no bus cycle; the action costs zero T-states
    INT =1,   # internal cycle, 1 + tx T-states
    MR  =2,   # memory read,     3 + tx
    MW  =3,   # memory write,    3 + tx
    IOR =4,   # I/O read,        4 + tx
    IOW =5,   # I/O write,       4 + tx
)

# ------------------------------------------------------- 16-bit address source
ASRC = dict(
    PC  =0,
    SP  =1,
    HL  =2,    # prefix-aware: HL, IX or IY
    BC  =3,
    DE  =4,
    WZ  =5,
    RP  =6,    # pair selected by opcode[5:4]: BC/DE/HL*/SP
    AZ  =7,    # {A, Z} - the I/O address of IN A,(n) and OUT (n),A
    HLR =8,    # raw HL, never substituted (block moves)
    DER =9,    # raw DE
    RST =10,   # {8'h00, opcode[5:3], 3'b000}
    BCR =11,   # raw BC - the I/O address of IN r,(C) and the block I/O ops
    SPP1=12,   # SP + 1, leaving SP alone (EX (SP),HL)
)

# side effect applied to the register named by ASRC
AINC = dict(NONE=0, POSTINC=1, PREDEC=2, POSTDEC=3)

# ------------------------------------------------ 8-bit data source / dest
# 0..7 match the Z80 r[] table order so opcode bits can index it directly.
# Index 6 is the bus data latch: r[6] is "(HL)", and the memory-operand
# micro-programs route that byte through DIN, so the mapping stays honest.
# Writes to DIN are discarded, which is what "IN (C)" and "RLC (IX+d)" with
# the undocumented register field set to 6 need.
DAT = dict(
    B=0, C=1, D=2, E=3, H=4, L=5, DIN=6, A=7,
    F=8, W=9, Z=10, I=11, R=12,
    SPH=13, SPL=14, PCH=15, PCL=16,
    HRAW=17, LRAW=18,
    RLO=19,    # r[opcode[2:0]], prefix-aware (H -> IXH under DD)
    RHI=20,    # r[opcode[5:3]], prefix-aware
    RLOR=21,   # r[opcode[2:0]], never substituted
    RHIR=22,   # r[opcode[5:3]], never substituted
    RPH=23,    # high byte of pair opcode[5:4], BC/DE/HL*/SP table
    RPL=24,
    RQH=25,    # high byte of pair opcode[5:4], BC/DE/HL*/AF table
    RQL=26,
    TMP=27,
    ZERO=28,
    RLOT=30,   # r[opcode[2:0]] raw, but index 6 means TMP - the DD CB forms
               # write their result to both memory and r[z], and need a real
               # register to hold it when z is 6
    NONE=31,
)

# -------------------------------------------------------------------- ALU ops
# The ALU takes the accumulator as operand A and DAT[ds] as operand B.
ALU = dict(
    NOP=0,       # move ds -> dd, no flag change
    ADD=1, ADC=2, SUB=3, SBC=4, AND=5, XOR=6, OR=7, CP=8,
    INC=9, DEC=10,
    RLC=11, RRC=12, RL=13, RR=14, SLA=15, SRA=16, SLL=17, SRL=18,
    BIT=19, RES=20, SET=21,
    RLCA=22, RRCA=23, RLA=24, RRA=25,
    DAA=26, CPL=27, SCF=28, CCF=29, NEG=30,
    INF=31,      # IN r,(C): S/Z/P from the byte, H=N=0, C untouched
    LDAIR=32,    # LD A,I and LD A,R: like INF, but P/V is IFF2
    RLDM=33,     # RLD, the half that goes back to memory
    RLDA=34,     # RLD, the half that goes to A
    RRDM=35,
    RRDA=36,
    BITM=37,     # BIT b,(HL): the undocumented X/Y come from W, not the operand
)

# ------------------------------------------------- 16-bit / composite actions
EOP = dict(
    NONE=0,
    INC_RP=1, DEC_RP=2,      # pair opcode[5:4], BC/DE/HL*/SP
    ADD_HL=3,                # HL* += rp,  ADD HL,rr flags,  WZ = HL*+1
    ADC_HL=4, SBC_HL=5,      # ED-prefixed, full flags
    JR=6,                    # PC += sext(DIN); WZ = PC
    DISP=7,                  # WZ = HL* + sext(DIN)   - the (IX+d) address
    HL_WZ=8,                 # HL* = WZ
    PC_WZ=9,                 # PC = WZ
    PC_HL=11,                # PC = HL*
    SP_HL=12,                # SP = HL*
    PC_RST=13,               # PC = WZ = {8'h00, opcode[5:3], 3'b000}
    LDI=14, LDD=15,          # HL+-1, DE+-1, BC-1, and the LDx flags
    CPI=16, CPD=17,
    INI=18, IND=19,
    OUTI=20, OUTD=21,
    REPEAT=22,               # block repeat: PC -= 2, WZ = PC + 1
    WZ_BC_INC=23,            # WZ = BC + 1
    WZ_A1=24,                # WZ = (this micro-op's own bus address) + 1
    WZ_WRA=25,               # WZ = {A, (this micro-op's own bus address + 1)[7:0]}
    WZ_HL1=27,               # WZ = HL* + 1             - RLD / RRD
    DEC_B=28,                # B -= 1, no flags         - DJNZ, OUTI
)

# ------------------------------------------------------------- misc controls
CTL = dict(
    NONE=0,
    EX_DE_HL=1,
    EXX=2,
    EX_AF=3,
    DI=4,
    EI=5,
    SET_IM=6,       # IM from opcode[5:3]
    HALT=7,
    RETN=8,         # IFF1 = IFF2
    SET_P=9,        # remember that LD A,I / LD A,R was the last instruction
)

FW = dict(NONE=0, ALU=1)   # does this micro-op write the flags register?

NX = dict(
    NEXT=0,      # fall through
    END=1,       # instruction complete, start the next opcode fetch
    CC=2,        # end here unless cc[opcode[5:3]] holds
    NZ_B=3,      # DJNZ: end here if B == 0
    CCJ=4,       # like CC, but the condition is cc[{1'b0, opcode[4:3]}]
    BLK=5,       # block op: end here unless the repeat condition still holds
)

FIELDS = [  # assembled low bits first
    ("bus",  3),
    ("tx",   3),
    ("asrc", 4),
    ("ainc", 2),
    ("ds",   5),
    ("dd",   5),
    ("pd",   5),
    ("wsrc", 5),
    ("alu",  6),
    ("fw",   1),
    ("eop",  5),
    ("ctl",  4),
    ("nx",   3),
]
UWIDTH = sum(w for _, w in FIELDS)

ENUMS = dict(BUS=BUS, ASRC=ASRC, AINC=AINC, DAT=DAT, ALU=ALU, EOP=EOP,
             CTL=CTL, FW=FW, NX=NX)
