# Legacy EDP repository migration record

Updated: 2026-08-29

`Evolution404/edp` is the sole development repository for EDP Drive, EDP Studio, and EDPCore.
The former repositories were merged without squashing their main histories. Additional tag-only and pull-request-only history was attached to the monorepo with history-only merges that did not change the current source tree.

## Former repositories

### Evolution404/edp-usb-vault

Final `main` head:

```text
3100474c36d6c618466ff5fcc8e564f1700a7a82
```

Imported tags:

```text
installer-preview -> ff29f75ca40bc18cce171d2ddb07555a4fdf90de
latest            -> a9692550863c755bb4617c8205f0b9783f151c5b
v0.1.0
v0.2.0
v0.4.0            -> 7b13eab6d0b2818a0c2767804fc600bec70ac0db
```

Historical pull requests:

```text
#1 CLOSED  Installer preview: one-click macFUSE bundle
head  ff29f75ca40bc18cce171d2ddb07555a4fdf90de

#2 MERGED  Pin approved FSKit runtime contract
head  31bfe13dfea769a61c6d3e2fdcf5fb63560f7dd5
merge 18dddcb0d03ce55c5e54a89e0f0d7cd326511d81

#3 MERGED  Test the production FSKit aligned read loop
head  40d16c495029912cd4f85bdcf6f8166cb060fd1c
merge f8aec291e2d6eae86062e5a87dd81896d13463e7
```

The PR #2 and #3 head histories were explicitly attached to the monorepo because the original merges were squash-style and did not otherwise preserve every intermediate PR commit as an ancestor of `main`.

The old repository had no GitHub Releases and no Issues. Historical GitHub Actions artifacts were not copied into the monorepo; they were transient CI outputs from superseded test/runtime paths and are reproducible or obsolete. Source history, tags, golden fixtures, current build scripts, and relevant implementation history are preserved in Git.

### Evolution404/edp-core

Final `main` head:

```text
f7d8f25612d1446b0b690d8932062a8ece1c571f
```

No Issues, Releases, pull requests, or unique tags required separate migration. The entire history is an ancestor of the monorepo.

### Evolution404/edpopen

Final `main` head:

```text
24fdfd4ac30f66e1fd6c33e1347ceb1e3740d6a8
```

Historical pull request:

```text
#1 MERGED  修复 macOS 26 raw disk 授权并收口安全写入链
head/merge d2626f523fb4e3c9c479ab5ec0a7893baacf90a7
```

The repository had no Issues or Releases. Its production Rust/Tauri implementation was later retired from the current tree, but its history remains available in the monorepo Git graph.

## Current monorepo identities

```text
EDP Drive App                  com.edp.drive
EDP Drive embedded Service     com.edp.drive.service

EDP Studio App                 com.edp.studio
EDP Studio Raw Broker / Mach   com.edp.studio.rawbroker
```

The three products now share one repository and one `main` branch:

```text
Apps/Drive
Apps/Studio
Packages/EDPCore
```

The original repository names are not development sources after this migration.
