#!/bin/sh
# Runs a one-off command in the Philomena app image with the app's full
# environment, as a Kubernetes Job cloned from the chart's "cron" CronJob
# (same image, environment, Secret, mounts and pull secrets). For anything
# that should outlive a `kubectl exec` session, or that has to run while the
# app is scaled down:
#
#   scripts/philomena-task.sh search-status philomena eval 'Philomena.Release.search_status()'
#   scripts/philomena-task.sh reindex philomena eval 'Philomena.Release.migrate_search()'
#
# `philomena eval` runs code without starting the application: the functions
# in Philomena.Release start it themselves, anything else needs an
# `Application.ensure_all_started(:philomena);` in front.
#
# Environment:
#   NAMESPACE     namespace of the release (default: philomena)
#   RELEASE       fullname of the release (default: philomena); the Job is
#                 cloned from the CronJob "$RELEASE-cron" (needs cron.enabled;
#                 cron.suspend is fine)
#   TASK_CPU      CPU limit of the task (default: 4). Reindexing runs one
#                 batch per CPU, so raise it for the big jobs.
#   TASK_MEMORY   memory limit of the task (default: 4Gi)
#
# Needs only kubectl. Follow and clean up with:
#   kubectl -n <namespace> logs -f job/<name>
#   kubectl -n <namespace> delete job/<name>
# (finished task Jobs are removed after a week on their own)
set -eu

usage="usage: philomena-task.sh <job name> <command> [args...]"
name=${1:?$usage}
shift
[ $# -gt 0 ] || { echo "$usage" >&2; exit 2; }

namespace=${NAMESPACE:-philomena}
cronjob=${RELEASE:-philomena}-cron
cpu=${TASK_CPU:-4}
memory=${TASK_MEMORY:-4Gi}

json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

command=""
for arg in "$@"; do
  command="$command${command:+,}$(json_string "$arg")"
done

patch=$(cat <<JSON
[
  {"op": "replace", "path": "/spec/template/spec/containers/0/command", "value": [$command]},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "RELEASE_NODE", "value": "philomena_task_0"}},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources",
   "value": {"requests": {"cpu": "250m", "memory": "512Mi"}, "limits": {"cpu": $(json_string "$cpu"), "memory": $(json_string "$memory")}}},
  {"op": "replace", "path": "/spec/backoffLimit", "value": 0},
  {"op": "remove", "path": "/spec/activeDeadlineSeconds"},
  {"op": "add", "path": "/spec/ttlSecondsAfterFinished", "value": 604800},
  {"op": "remove", "path": "/metadata/ownerReferences"}
]
JSON
)

# Without the owner reference the CronJob does not count the task as one of
# its own runs (history limits, concurrencyPolicy).
kubectl -n "$namespace" create job "$name" --from="cronjob/$cronjob" --dry-run=client -o json |
  kubectl patch --local -f - --type=json -p "$patch" -o json |
  kubectl -n "$namespace" apply -f -

echo "Started. Follow with: kubectl -n $namespace logs -f job/$name" >&2
