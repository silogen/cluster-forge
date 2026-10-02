# Manual Helm installation guides

These guides install AMD Enterprise AI with Helm and `kubectl` only. They do
not use ArgoCD, and they do not use cluster-bloom. Use one when you must
install by hand, or when you must know which chart supplies which component.

Two guides are here. They install different products, so read this page first
and go to one of them.

```
┌──────────────────────┬──────────────────────────────┬──────────────────────┐
│ Directory            │ What it installs             │ Who it is for        │
├──────────────────────┼──────────────────────────────┼──────────────────────┤
│ aiwb-standalone/     │ AI Workbench (AIWB) and the  │ A user who wants the │
│                      │ components it needs. Each    │ workbench, and who   │
│                      │ component is pluggable, so   │ substitutes a        │
│                      │ you can substitute your own  │ component with an    │
│                      │ identity provider, database  │ existing one.        │
│                      │ or object store.             │                      │
├──────────────────────┼──────────────────────────────┼──────────────────────┤
│ full-platform/       │ AI Resource Manager (AIRM)   │ A user who serves    │
│                      │ and AIWB together, with the  │ models on AMD GPUs,  │
│                      │ GPU stack: the AMD GPU       │ and who needs the    │
│                      │ Operator, Kueue, Kaiwo,      │ multi-tenant control │
│                      │ KServe and the AIM engine.   │ plane.               │
└──────────────────────┴──────────────────────────────┴──────────────────────┘
```

## Which guide do I need?

Go to `full-platform/` when you must serve a model on an AMD GPU. AIRM
schedules the GPU work, and AIWB alone cannot do it.

Go to `aiwb-standalone/` when you want the workbench user interface on a
cluster that has no GPU, or when you add AIWB to a platform that already
schedules the GPU work.

## Where to start in each guide

| Directory          | Start here                                      |
|--------------------|-------------------------------------------------|
| `aiwb-standalone/` | [README.md](aiwb-standalone/README.md)          |
| `full-platform/`   | [INSTALL.md](full-platform/INSTALL.md)          |

`full-platform/` also has [UNINSTALL.md](full-platform/UNINSTALL.md). A
`helm uninstall` alone leaves custom resources, finalizers and persistent
volumes behind, so read that document before you remove the platform.
