#!/usr/bin/env python3
"""Run the unchanged release scripts against this sandbox using the local CLI login."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
repo = "cruz-evan/release-cadence-sandbox"
actual = subprocess.check_output(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cwd=root, text=True).strip()
if actual != repo:
    raise SystemExit(f"Refusing unexpected repository: {actual}")
args = sys.argv[1:]
if not args or args[0] not in ["cut", "start", "beta", "finish", "refresh", "finalize"]:
    raise SystemExit("Usage: python3 sandbox.py cut|start|beta|finish|refresh|finalize [script arguments]")
script = {"refresh": "refresh_release_notes.dart", "finalize": "finalize_release.dart"}.get(args[0], "release_train.dart")
script_args = args[1:] if args[0] in ["refresh", "finalize"] else args
info = json.loads(subprocess.check_output(["gh", "repo", "view", "--json", "isPrivate"], cwd=root, text=True))
if not info["isPrivate"]:
    raise SystemExit("Refusing to run against a public repository")
env = os.environ.copy()
env.update(GITHUB_REPOSITORY=repo, GH_TOKEN=subprocess.check_output(["gh", "auth", "token"], text=True).strip(), GITHUB_EVENT_NAME="sandbox-local")
env.pop("GITHUB_TOKEN", None)
sys.exit(subprocess.call([env.get("DART", "dart"), "build_scripts/" + script, *script_args], cwd=root, env=env))
