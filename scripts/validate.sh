#!/usr/bin/env bash
# Renders every chart with its default values and with each ci/*-values.yaml
# file, and validates the output with kubeconform, CRDs included (CNPG
# Cluster, InfisicalSecret, HTTPRoute, ...; schemas from the CRDs-catalog).
#
# Usage: scripts/validate.sh [chart-dir...]   (default: every chart)
#
# Needs helm, kubeconform and python3 with PyYAML.
set -euo pipefail
cd "$(dirname "$0")/.."

crd_schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

if [ $# -gt 0 ]; then
  charts=("$@")
else
  charts=(charts/*/)
fi

for dir in "${charts[@]}"; do
  dir=${dir%/}
  if grep -q '^dependencies:' "$dir/Chart.yaml"; then
    helm dependency build "$dir" > /dev/null
  fi

  # The defaults and each ci file on their own, so that an optional path
  # (external services, infisical, ...) does not hide the default one.
  sets=("")
  for f in "$dir"/ci/*-values.yaml; do
    [ -e "$f" ] && sets+=("$f")
  done

  for f in "${sets[@]}"; do
    args=()
    [ -n "$f" ] && args+=(--values "$f")
    echo "==> $dir ${f:-(defaults)}"
    # strip-nulls.py drops null fields first, as the API server does (the
    # CNPG subchart renders an empty `postgresql:` key).
    helm template release "$dir" ${args[@]+"${args[@]}"} \
      | python3 scripts/strip-nulls.py \
      | kubeconform -strict -summary \
          -schema-location default \
          -schema-location "$crd_schemas"
  done
done
