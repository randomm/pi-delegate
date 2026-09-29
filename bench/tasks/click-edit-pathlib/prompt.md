# Add support of `pathlib.Path` to `edit`

`click.edit` does not accept a `pathlib.Path` as `filename`:

```
Argument of type "Path" cannot be assigned to parameter "filename" of
type "str | None" in function "edit"
```

Easy workaround with `click.edit(filename=str(path))`, but it would be
nice if `str` were not required.

Make `click.edit` accept `pathlib.Path` (in addition to `str`) as the
filename argument.

Work in the current repository. Implement the change the issue describes,
in the same spirit and scope. Do not add new dependencies, do not reformat
unrelated code. Do not commit — leave your changes in the working tree.
