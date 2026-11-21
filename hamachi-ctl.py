#!/usr/bin/env python3
"""Small JSON bridge between the Omarchy bar widget and the hamachi CLI.

  hamachi-ctl.py status                 -> JSON with state, networks, peers
  hamachi-ctl.py login|logout
  hamachi-ctl.py go-online|go-offline <network-id>
  hamachi-ctl.py join|create <network-id>   (password in $HAMACHI_PASS)
  hamachi-ctl.py leave|delete <network-id>
  hamachi-ctl.py set-nick <nickname>
  hamachi-ctl.py start-daemon           -> pkexec systemctl start logmein-hamachi
"""
import json, os, re, shutil, subprocess, sys, time

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
PEER_RE = re.compile(r"^\s+([*x!?])?\s*(\d{3}-\d{3}-\d{3})\s+(.*)$")
NET_RE = re.compile(r"^\s*([*x!?])?\s*\[([^\]]{1,64})\]\s*(.*)$")


def run(args, timeout=15, stdin_text=""):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           input=stdin_text + "\n")
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except OSError as e:
        return 127, str(e)


def clip(s, n=80):
    return str(s).strip()[:n]


def parse_info(text):
    info = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        info[k.strip().lower()] = v.strip()
    return info


def parse_list(text):
    networks = []
    for line in text.splitlines()[:500]:
        m = PEER_RE.match(line)
        if m and networks:
            mark, pid, rest = m.groups()
            fields = [f for f in re.split(r"\s{2,}", rest.strip()) if f]
            nick = fields[0] if fields and not IPV4_RE.match(fields[0]) else ""
            ip = next((f for f in fields if IPV4_RE.match(f)), "")
            conn = next((f for f in fields if f.startswith("direct") or f.startswith("via")), "")
            if len(networks[-1]["peers"]) < 256:
                networks[-1]["peers"].append({
                    "id": pid, "nick": clip(nick, 64), "ip": ip,
                    "online": mark == "*", "warn": mark in ("x", "!"),
                    "conn": clip(conn, 32),
                })
            continue
        m = NET_RE.match(line)
        if m:
            mark, nid, rest = m.groups()
            name, _, tail = rest.partition("capacity:")
            cap = tail.split(",", 1)[0].strip() if tail else ""
            owner = tail.split("owner:", 1)[1].strip() if "owner:" in tail else ""
            networks.append({
                "id": clip(nid, 64), "name": clip(name or nid, 64),
                "owner": clip(owner, 64), "isOwner": owner.lower().startswith("this computer"),
                "online": mark == "*", "capacity": clip(cap, 16), "peers": [],
            })
    return networks[:64]


def status():
    out = {"installed": bool(shutil.which("hamachi")), "daemon": False,
           "permission": True, "online": False, "status": "", "clientId": "",
           "address": "", "nickname": "", "networks": [], "error": ""}
    if not out["installed"]:
        return out
    rc, _ = run(["systemctl", "is-active", "--quiet", "logmein-hamachi"], 5)
    out["daemon"] = rc == 0
    if not out["daemon"]:
        return out
    rc, text = run(["hamachi"])
    if "permission" in text.lower():
        out["permission"] = False
        return out
    info = parse_info(text)
    out["status"] = clip(info.get("status", ""), 32)
    out["online"] = out["status"] == "logged in"
    out["clientId"] = clip(info.get("client id", ""), 16)
    out["address"] = clip(info.get("address", "").split()[0] if info.get("address") else "", 40)
    out["nickname"] = clip(info.get("nickname", ""), 64)
    if out["online"]:
        rc, text = run(["hamachi", "list"])
        out["networks"] = parse_list(text)
    return out


def hamachi_action(args, secret=""):
    """Run a hamachi action; it always exits 0, so read '.. failed' from output."""
    for attempt in range(3):
        rc, text = run(["hamachi"] + args, 30, secret)
        if "busy" not in text or attempt == 2:
            break
        time.sleep(2)
    text = text.replace("Password:", "").strip()
    # hamachi always exits 0; success lines end in ".. ok", failures in ".. failed, <reason>".
    # Do not grep for words like "error": network IDs and nicknames are echoed back.
    failed = rc != 0 or ".. failed" in text or not re.search(r"\.{2,}\s*ok\b", text)
    return not failed, text


def valid_text(v, n=64):
    return bool(v) and len(v) <= n and not v.startswith("-") and "\n" not in v


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    arg = argv[2] if len(argv) > 2 else ""
    secret = os.environ.get("HAMACHI_PASS", "")
    if cmd == "status":
        print(json.dumps(status()))
        return 0
    if cmd in ("login", "logout"):
        ok, text = hamachi_action([cmd])
    elif cmd in ("go-online", "go-offline", "leave", "delete") and ID_RE.match(arg):
        ok, text = hamachi_action([cmd, arg])
    elif cmd == "join" and ID_RE.match(arg):
        # Password goes over stdin (hamachi prompts for it), never argv.
        ok, text = hamachi_action(["do-join", arg], secret)
    elif cmd == "create" and ID_RE.match(arg):
        ok, text = hamachi_action(["create", arg], secret)
    elif cmd == "set-nick" and valid_text(arg):
        ok, text = hamachi_action(["set-nick", arg])
    elif cmd == "start-daemon":
        rc, text = run(["pkexec", "systemctl", "start", "logmein-hamachi"], 120)
        ok = rc == 0
    else:
        print(json.dumps({"ok": False, "error": "bad command"}))
        return 2
    print(json.dumps({"ok": ok, "message": clip(text, 200)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
