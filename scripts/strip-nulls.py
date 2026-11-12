#!/usr/bin/env python3
"""Drop null-valued keys from a multi-document YAML stream (stdin -> stdout).

The API server prunes nulls for non-nullable CRD fields, but schema
validators reject them; some subcharts (e.g. CNPG's `cluster`) render empty
keys like `postgresql:`. Run rendered manifests through this before
kubeconform so validation matches what the cluster accepts.
"""
import sys

import yaml


def strip(node):
    if isinstance(node, dict):
        return {k: strip(v) for k, v in node.items() if v is not None}
    if isinstance(node, list):
        return [strip(v) for v in node]
    return node


docs = [strip(d) for d in yaml.safe_load_all(sys.stdin) if d is not None]
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
