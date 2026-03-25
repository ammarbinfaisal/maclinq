#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

KARABINER_DIR="${KARABINER_DIR:-${HOME}/.config/karabiner}"
ASSET_DIR="${KARABINER_DIR}/assets/complex_modifications"
CONFIG_PATH="${KARABINER_DIR}/karabiner.json"
SOURCE_ASSET="${ROOT_DIR}/karabiner/maclinq-toggle.json"
TARGET_ASSET="${ASSET_DIR}/maclinq-toggle.json"

if [[ ! -f "${SOURCE_ASSET}" ]]; then
  printf 'install-karabiner-maclinq: missing source asset: %s\n' "${SOURCE_ASSET}" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  printf 'install-karabiner-maclinq: missing Karabiner config: %s\n' "${CONFIG_PATH}" >&2
  exit 1
fi

mkdir -p "${ASSET_DIR}"
cp "${SOURCE_ASSET}" "${TARGET_ASSET}"

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="${CONFIG_PATH}.bak.${BACKUP_SUFFIX}"
cp "${CONFIG_PATH}" "${BACKUP_PATH}"

export CONFIG_PATH
export SOURCE_ASSET

python3 <<'PY'
import json
import os
import sys

config_path = os.environ["CONFIG_PATH"]
source_asset = os.environ["SOURCE_ASSET"]

with open(source_asset, "r", encoding="utf-8") as f:
    asset = json.load(f)

rules_to_install = asset.get("rules", [])
if not rules_to_install:
    raise SystemExit("install-karabiner-maclinq: source asset has no rules")

with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

profiles = config.get("profiles", [])
if not profiles:
    raise SystemExit("install-karabiner-maclinq: karabiner.json has no profiles")

selected_profile = next((p for p in profiles if p.get("selected")), profiles[0])
selected_profile_name = selected_profile.get("name", "<unnamed>")

complex_modifications = selected_profile.setdefault("complex_modifications", {})
existing_rules = complex_modifications.setdefault("rules", [])

existing_by_description = {
    rule.get("description"): idx
    for idx, rule in enumerate(existing_rules)
    if isinstance(rule, dict) and rule.get("description")
}

installed = 0
updated = 0
for rule in rules_to_install:
    description = rule.get("description")
    if not description:
        raise SystemExit("install-karabiner-maclinq: encountered rule without description")
    if description in existing_by_description:
        existing_rules[existing_by_description[description]] = rule
        updated += 1
    else:
        existing_rules.append(rule)
        installed += 1

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=4)
    f.write("\n")

print(f"selected_profile={selected_profile_name}")
print(f"installed={installed}")
print(f"updated={updated}")
PY

printf 'asset_installed=%s\n' "${TARGET_ASSET}"
printf 'config_updated=%s\n' "${CONFIG_PATH}"
printf 'config_backup=%s\n' "${BACKUP_PATH}"
