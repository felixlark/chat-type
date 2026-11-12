"""Read personal names through wechat-decrypt's get_contacts tool; stdout is names only."""
import contextlib
import importlib.util
import json
from pathlib import Path
import re
import sys


def personal_names(text):
    names = []
    for line in text.splitlines():
        fields = re.split(r"  (?:备注|昵称): ", line)
        if len(fields) < 2:
            continue
        username = fields[0]
        if "@chatroom" in username or username.startswith("gh_"):
            continue
        if username in {"notifymessage", "medianote", "filehelper", "fmessage", "weixin", "newsapp", "brandsessionholder", "qqmail", "qmessage", "floatbottle"}:
            continue
        names.extend(value.strip() for value in fields[1:] if value.strip())
    return names


def read_names(provider):
    # Import this precise installed provider; never search for a same-named module.
    sys.path.insert(0, str(provider.parent))
    spec = importlib.util.spec_from_file_location("mcp_server", provider)
    module = importlib.util.module_from_spec(spec)
    sys.modules["mcp_server"] = module
    with contextlib.redirect_stdout(sys.stderr):
        spec.loader.exec_module(module)
        call = getattr(module.get_contacts, "fn", module.get_contacts)
        probe = call(query="", limit=1)
        match = re.search(r"共 (\d+) 个匹配", probe) or re.search(r"找到 (\d+) 个联系人", probe)
        if not match:
            raise ValueError("contacts metadata unavailable")
        count = int(match.group(1))
        text = call(query="", limit=count)
    header = re.search(r"找到 (\d+) 个联系人", text)
    if not header or int(header.group(1)) != count or "当前仅显示" in text:
        raise ValueError("incomplete contacts response")
    return {"complete": True, "names": personal_names(text)}


if __name__ == "__main__":
    try:
        print(json.dumps(read_names(Path(sys.argv[1]).resolve()), ensure_ascii=False))
    except Exception as error:
        # Exception types identify the failing boundary without exposing provider output or keys.
        print(json.dumps({"failure": type(error).__name__}))
        sys.exit(1)
