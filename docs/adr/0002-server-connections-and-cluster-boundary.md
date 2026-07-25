# ADR 0002: Server connections and cluster boundary

## Status

Accepted

## Context

Local machines, remote servers, and single-user Kubeflow pods all run a
Kubecode Runtime that the user can operate directly. Slurm is different: it is
a scheduler reached through an SSH host and its native commands, and does not
itself host a Kubecode control plane.

## Decision

The client has one Server model with three lifecycle modes:

- `local_managed` launches and stops a bundled loopback Runtime.
- `ssh_managed` will launch or attach to a Runtime through the user's SSH
  configuration and carry the same API over a tunnel.
- `https_attached` will connect to an already managed Runtime, including a
  Kubeflow deployment behind its platform authentication boundary.

Only `local_managed` is user-visible in the first macOS release. All modes use
the same versioned resources and capability discovery. They must not fork the
Project, Session, Team, file, Git, or terminal data model.

Slurm remains outside the client and Runtime domain model. Claude Code, Codex,
or OpenCode can operate it through a provider-native Agent skill using the
user's `ssh_config` and commands such as `squeue`, `sacct`, `sbatch`, and
`scancel`. Kubecode does not store cluster credentials, mirror scheduler state,
or introduce Slurm-specific API routes.

iOS and iPadOS companions will attach to an existing authenticated Runtime for
monitoring, notifications, approvals, task control, and lightweight prompts.
They will not launch local provider processes or manage Slurm directly.

## Consequences

Local, remote, and Kubeflow usage remain one product instead of three backend
implementations. SSH and HTTPS can be added without changing workspace
semantics. Scheduler capability evolves with provider skills, while mobile
clients stay small and control-oriented.
