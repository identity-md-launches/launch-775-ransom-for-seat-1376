#!/usr/bin/env python3
"""Offline task-specific schema, artifact, compiler, and opcode checks. Run after forge build."""
import json
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "launch.json").read_text())
assert set(manifest) == {"kind", "hook", "token", "pool", "notes"}
assert manifest["kind"] == "univ4_hook"
hook = manifest["hook"]
assert set(hook) == {"contract", "constructorArgs", "permissions"}
assert hook["contract"] == "ManumissionHook"
assert hook["constructorArgs"] == ["$poolManager"]
flags = {"afterInitialize": 0x1000, "beforeSwap": 0x80, "afterSwap": 0x40,
         "beforeSwapReturnDelta": 0x8, "afterSwapReturnDelta": 0x4}
assert set(hook["permissions"]) == set(flags) and len(hook["permissions"]) == 5
assert sum(flags[x] for x in hook["permissions"]) == 0x10CC
assert manifest["token"] == {"contract": "ManumissionToken", "name": "Ransom for Seat 1376",
                             "symbol": "FREE1376", "decimals": 18}
pool = manifest["pool"]
assert set(pool) == {"pairedCurrency", "fee", "tickSpacing", "initialPrice"}
assert pool["pairedCurrency"] == "0x" + "0" * 40
assert pool["fee"] == 3000 and pool["tickSpacing"] == 60
assert isinstance(pool["initialPrice"], str)
assert re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", pool["initialPrice"])
assert isinstance(manifest["notes"], str) and len(manifest["notes"]) <= 4000
assert "CREATOR" in manifest["notes"] and "requester" in manifest["notes"]

config = tomllib.loads((ROOT / "foundry.toml").read_text())["profile"]["default"]
for name, expected in {"solc": "0.8.26", "evm_version": "cancun", "optimizer": True,
                       "optimizer_runs": 200, "via_ir": False, "bytecode_hash": "none",
                       "cbor_metadata": False, "ffi": False}.items():
    assert config[name] == expected, name
assert not config.get("fs_permissions")

for name, constructor in [("ManumissionToken", []), ("ManumissionHook", ["address"])]:
    artifact = json.loads((ROOT / "out" / (name + ".sol") / (name + ".json")).read_text())
    ctor = next(x for x in artifact["abi"] if x["type"] == "constructor")
    assert [x["type"] for x in ctor["inputs"]] == constructor
    code = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(code) <= 24576
    offset = 0
    while offset < len(code):
        opcode = code[offset]
        assert opcode not in (0xF2, 0xF4, 0xFF), (name, offset, hex(opcode))
        offset += 1 + (opcode - 0x5F if 0x60 <= opcode <= 0x7F else 0)
    print(f"{name}: constructor matches; runtime {len(code)} bytes; forbidden opcodes 0")
print("launch.json schema and flags 0x10CC, compiler configuration: OK")
