# hydrowf-tools

CWL v1.2 descriptions of the containerized tools hydrowf runs (NextGen and FIM),
and the pipelines built from them.

## Layout

| Path | Contents |
|---|---|
| `nextgen/<tool>/` | `<tool>.cwl`, `tests/job.yml`, `README.md` |
| `fim/<tool>/` | same, for FIM tools |
| `pipelines/` | CWL Workflows that chain tools |
| `hints/` | the `hydrowf:` hint vocabulary and the supported CWL subset |

## Conventions

- One CommandLineTool per folder; the folder name, file name and `id` match.
- Only the CWL subset in [hints/README.md](hints/README.md). No JavaScript.
- Images are pinned by version tag or digest, never `:latest`.
- Upstream first: fix bugs in the tool's own repo; this repo only describes how to run it.
- Every tool has a `tests/job.yml` that runs with `cwltool`. Test data is not committed.

## Validate and run

```sh
uv tool install cwltool
cwltool --validate nextgen/ngiab-teehr/ngiab-teehr.cwl
cd nextgen/ngiab-teehr/tests && cwltoo
```
