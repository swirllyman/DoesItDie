"""Runs tools/test_locale.lua under Lua 5.1, the version WoW uses (lupa's lua51 module).

    pip install lupa
    python tools/test_locale.py [path/to/DoesItDie.lua]
"""
import os
import sys

from lupa import lua51

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

lua = lua51.LuaRuntime()
g = lua.globals()
g.TEST_ROOT = ROOT.replace("\\", "/")
g.TEST_NO_EXIT = True
if len(sys.argv) > 1:
    g.TEST_SOURCE = sys.argv[1]
print(lua.eval("_VERSION"))
with open(os.path.join(ROOT, "tools", "test_locale.lua"), encoding="utf-8") as f:
    failed = lua.execute(f.read())
sys.exit(1 if failed else 0)
