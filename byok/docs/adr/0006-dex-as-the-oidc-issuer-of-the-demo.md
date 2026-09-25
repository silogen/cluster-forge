---
status: accepted
date: 2026-09-11
---

# Dex is the OIDC issuer of the demo profiles, not Keycloak

The `demo` and `demo-cpu` profiles run Dex as the OIDC issuer: one Pod, one
static user `devuser@<domain>`, one client `aiwb`, and its state in memory.
The `aiwb-demo-secrets` package makes the client secret, the demo password
and its bcrypt hash. AIWB logs in through the `oidc` block of its chart.

The first demo profile of 2026-09-10 ran Keycloak, because the aiwb chart of
that time knew Keycloak only. silogen/core#4643 gives the aiwb chart a generic
`oidc` block. The demo moved to Dex on 2026-09-11 with a chart built from that
branch, and the released chart 2.0.3 holds the block.

## Considered options

- Keep Keycloak. Rejected: it is the largest part of a demo that exists to be
  small. On the Kaytoo VM of 2026-09-11, Keycloak requested 250 mCPU and
  512 MiB where Dex requests 20 mCPU and 64 MiB, used 837 MiB of memory, and
  needed a second PostgreSQL database. Its image is about 470 MiB where the
  Dex image is 44 MiB.
- No issuer, with AIWB in a mode without login. Rejected: AIWB has no such
  mode, and the demo exists to show the login path.

## Consequences

- A restart of the Dex Pod ends every session, because the state is in
  memory. This is acceptable for a demo and not for a production
  installation.
- The demo shows the stock Dex login page. A branded page is future work.
- A customer replaces the `dex` package with their own issuer and sets the
  `oidc` block of the aiwb package in the profile. Nothing else in the demo
  knows Dex.
- The `keycloak` values block of the aiwb chart still exists, and the `oidc`
  block derives its defaults from it. EAI-5551 is related.
