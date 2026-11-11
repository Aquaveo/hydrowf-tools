# hydrowf hints and supported CWL

Namespace: `hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#`

## Supported CWL v1.2 subset

- `CommandLineTool`, and `Workflow` with plain steps
- Requirements: `DockerRequirement`, `ResourceRequirement`, `EnvVarRequirement`,
  `NetworkAccess`, `InitialWorkDirRequirement` (plain listing)
- Types: `File`, `Directory`, `string`, `int`, `float`, `boolean`, `enum`, arrays of these
- `inputBinding`, `outputBinding.glob`, `format`, parameter references such as `$(inputs.x.basename)`
- `outputBinding.glob` is an exact path, no wildcards: an Argo output artifact needs one path

Not supported: `InlineJavascriptRequirement`, `ExpressionTool`, `when`,
`secondaryFiles` patterns, `scatter`.

### Images with an ENTRYPOINT

cwltool keeps the image's ENTRYPOINT, so for those images the CWL has no `baseCommand`
and `arguments` go to the ENTRYPOINT (see `nextgen/ngiab-run`). The Argo translator
does the same: it sets the container's `command` to the image's ENTRYPOINT (or to
`baseCommand` if the image has none) and puts the rest in `args`. Argo's executor needs
the command; with `args` only, it asks the registry for the ENTRYPOINT, which fails for
images that are only local.

## Hints

| Hint | Fields | Purpose |
|---|---|---|
| `hydrowf:UI` | `category`, `icon` | Where the tool appears in the pipeline builder palette |
| `hydrowf:Publish` | `output`, `target` (`parquet` or `stac`), `table` | What the publish step does with an output |
| `hydrowf:port` | a type name, e.g. `ngen.run` | Set on an input or output; the canvas only connects matching ports. Needed for Directories, which can't carry `format`. |

cwltool prints a warning for each `hydrowf:` hint it doesn't know. That's expected.
