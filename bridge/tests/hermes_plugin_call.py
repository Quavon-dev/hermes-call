"""Stand-in for Hermes in container tests: loads the installed plugin and calls call_owner like the agent would."""

import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hermes_call", sys.argv[1])
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)
tools = {}
plugin.register(type("Ctx", (), {"register_tool": lambda self, **kw: tools.update({kw["name"]: kw})})())
print(tools["call_owner"]["handler"]({"reason": sys.argv[2], "first_message": sys.argv[3]}))
