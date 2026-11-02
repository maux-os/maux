#!/usr/bin/env python3
"""Independent CPU oracle for NAS's native mode-row probe.

The assembly is extracted from nas.pla and exercised at relocated origins,
page-crossing row blocks, every eval-stack position, duplicate modes, XC
gating, empty blocks, and opcode $FF. Expected values come from a small
Python row model, not from the implementation.
"""
from pathlib import Path
import ast
import re
import random
import subprocess
import tempfile

from py65.devices.mpu6502 import MPU

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/asm/nas.pla").read_text()


def block(name):
    match = re.search(r"^asm " + name + r"\([^\n]*\n(.*?)^end$",
                      SOURCE, re.M | re.S)
    if not match:
        raise RuntimeError(f"missing asm block {name}")
    return match.group(1)


def w16(memory, address, value):
    memory[address] = value & 0xFF
    memory[address + 1] = (value >> 8) & 0xFF


def expected(rows, mode, xc):
    for row_mode, opcode, extension in rows:
        if row_mode == mode:
            return opcode if not extension or xc else 0xFFFF
    return 0xFFFF


def optab_rows():
    """Read the checked-in six-byte rows into an independent row model."""
    body = SOURCE.split("const NOPTAB = 178", 1)[1].split(
        "// Directive name literals", 1)[0]
    modes = {name: int(value) for name, value in re.findall(
        r"^const (M_\w+)\s*=\s*(\d+)", SOURCE, re.M)}
    values = []
    for line in body.splitlines():
        line = line.split("//", 1)[0].strip()
        if not line.startswith("byte"):
            continue
        rhs = line.split("=", 1)[1]
        for token in rhs.split(","):
            token = token.strip()
            if not token:
                continue
            if token in modes:
                values.append(modes[token])
            elif token.startswith("$"):
                values.append(int(token[1:], 16))
            elif token.startswith("'"):
                values.append(ord(ast.literal_eval(token)))
            else:
                values.append(int(token))
    assert len(values) == 178 * 6, len(values)
    return [tuple(values[offset:offset + 6])
            for offset in range(0, len(values), 6)]


def optab_groups():
    groups = {}
    for c0, c1, c2, mode, opcode, extension in optab_rows():
        groups.setdefault(bytes((c0, c1, c2)), []).append(
            (mode, opcode, extension))
    return groups


def seeded_memory(seed):
    memory = [0] * 65536
    seeded = random.Random(seed)
    for start, end in ((0xA0, 0x100), (0xE0, 0xEA),
                       (0x1E8, 0x200)):
        for cell in range(start, end):
            memory[cell] = seeded.randrange(1, 256)
    return memory


def invoke(memory, address, args, want, stack_x):
    cpu = MPU(memory=memory)
    cpu.pc, cpu.x, cpu.sp = address, stack_x, 0xF0
    memory[0x1F1:0x1F3] = [0xFF, 0x2F]
    for index, value in enumerate(reversed(args)):
        memory[0xA0 + stack_x + index] = (value >> 8) & 0xFF
        memory[0xC0 + stack_x + index] = value & 0xFF
    before = memory.copy()
    arg_cells = set()
    for index in range(len(args)):
        arg_cells.add(0xA0 + stack_x + index)
        arg_cells.add(0xC0 + stack_x + index)
    guard_cells = set(range(0xA0, 0xE0)) | set(range(0xC0, 0x100))
    guard_cells |= set(range(0xE0, 0xEA))       # IFP and following ZP
    guard_cells |= set(range(0x1E8, 0x1F1))     # below return address
    guard_cells |= set(range(0x1F3, 0x200))     # above return address
    guard_cells -= {0xE7, 0xE8}                # native VM scratch pair
    guard_cells -= arg_cells
    guards = {cell: memory[cell] for cell in guard_cells}
    for _ in range(2000):
        cpu.step()
        if cpu.pc == 0x3000:
            break
    else:
        raise AssertionError("modeprobe failed to return")
    result_slot = stack_x + len(args) - 1
    got = (memory[0xC0 + result_slot] |
           memory[0xA0 + result_slot] << 8)
    assert got == want, (args, hex(got), hex(want))
    assert cpu.x == result_slot and cpu.sp == 0xF2
    allowed = set(range(6, 10)) | {0x9E, 0xE7, 0xE8, 0x1F0}
    allowed |= set(range(0xA0 + stack_x, 0xA0 + stack_x + len(args)))
    allowed |= set(range(0xC0 + stack_x, 0xC0 + stack_x + len(args)))
    changed = {i for i, (old, new) in enumerate(zip(before, memory))
               if old != new}
    assert changed <= allowed, ("unexpected memory writes", changed - allowed)
    bad_guards = [cell for cell, value in guards.items()
                  if memory[cell] != value]
    assert not bad_guards, ("stack/IFP guard changed", bad_guards)


def run(code, address, rng):
    total = 0
    positions = set()
    cases = [
        ([], 3, 0, 0xFFFF),
        ([(3, 0x00, 0)], 3, 0, 0x00),
        ([(3, 0x12, 0)], 3, 0, 0x12),
        ([(3, 0xFF, 0)], 3, 0, 0xFF),
        ([(3, 0x12, 1)], 3, 0, 0xFFFF),
        ([(3, 0x12, 1)], 3, 1, 0x12),
        ([(3, 0x12, 1), (3, 0x34, 0)], 3, 1, 0x12),
        ([(3, 0x12, 1), (3, 0x34, 0)], 3, 0, 0xFFFF),
        ([(3, 0x56, 1)], 3, 0x0100, 0x56),
        ([(2, 0x21, 0), (4, 0x43, 1)], 4, 0, 0xFFFF),
    ]
    for index in range(120):
        rows = [(rng % 15, (index * 37) & 0xFF, index & 1)]
        if index & 2:
            rows.append(((index + 3) % 15, 0xFF, 0))
        cases.append((rows, (index * 7) % 15, (index >> 2) & 1,
                      expected(rows, (index * 7) % 15, (index >> 2) & 1)))
        rng = (rng * 1103515245 + 12345) & 0x7FFFFFFF

    for rows in optab_groups().values():
        for mode in range(15):
            for xc in (0, 1, 0x0100):
                cases.append((rows, mode, xc, expected(rows, mode, xc)))

    for index, (rows, mode, xc, want) in enumerate(cases):
        table = 0x80FE
        memory = seeded_memory(index + address)
        memory[address:address + len(code)] = code
        pointer = table + (index % 3) * 0x100
        for row, values in enumerate(rows):
            base = pointer + row * 6
            memory[base:base + 6] = [0x41, 0x42, 0x43,
                                      values[0], values[1], values[2]]
        try:
            stack_x = (index * 7) % 29
            positions.add(stack_x)
            invoke(memory, address, [pointer, len(rows), mode, xc], want,
                   stack_x)
        except AssertionError as error:
            raise AssertionError((index, rows, mode, xc, want, error)) from error
        total += 1

    assert positions == set(range(29)), positions

    # Gate teeth: replacing the helper entry with RTS must be observed.
    memory = seeded_memory(address + 9001)
    memory[address:address + len(code)] = code
    memory[0x80FE:0x8104] = [0x41, 0x42, 0x43, 3, 0x22, 0]
    memory[address] = 0x60
    try:
        invoke(memory, address, [0x80FE, 1, 3, 0], 0x22, 0)
    except AssertionError:
        pass
    else:
        raise AssertionError("deliberately broken helper escaped detection")
    return total


def main():
    equates = block("findcr").split("        LDA", 1)[0]
    with tempfile.TemporaryDirectory(prefix="nas-mode-native-") as tmp:
        tmp = Path(tmp)
        asm = tmp / "modeprobe.a"
        binary = tmp / "modeprobe.bin"
        asm.write_text(equates + "\nmodeprobe\n" + block("modeprobe") + "\n")
        total = 0
        for origin in (0x4000, 0x41F9):
            subprocess.run(["acme", "--setpc", str(origin), "-o",
                            str(binary), str(asm)], check=True)
            total += run(binary.read_bytes(), origin, 618)
        print(f"PASS: {total} CPU-oracle cases; relocated modeprobe; full "
              "optab/duplicate/sentinel/page/stack/IFP guards; sabotage rejected")


if __name__ == "__main__":
    main()
