# Empty output from `HelpFormatter.write_usage` for a program without arguments

If no `args` are passed to `HelpFormatter.write_usage`, the Usage line is
not printed.

### Reproduction

```python
import click

f = click.HelpFormatter()
f.write_usage("program")
print(f.getvalue())
```

### Expected output

```
Usage: program
```

### Actual output

(an empty line)

### Environment

- Python version: 3.12.3
- Click version: 8.3.1

### Additional information

We use `click` for a CLI program with interactive mode. We are about to
use `click.HelpFormatter` to print help for internal commands, some of
which do not accept any arguments (`exit`, for example).

Fix this issue.

Work in the current repository. Implement the change the issue describes,
in the same spirit and scope. Do not add new dependencies, do not reformat
unrelated code. Do not commit — leave your changes in the working tree.
