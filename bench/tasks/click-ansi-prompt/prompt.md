# ANSI codes not stripped from `click.confirm` / `click.prompt` after upgrading to Click 8.4

Failing unit tests after upgrading to Click 8.4.1. Using
`runner.invoke(cmd, color=False)` fixes most cases, but not commands that
use `click.confirm()`.

Repro:

```python
import click
from click.testing import CliRunner


@click.command()
def cmd_confirm():
    click.confirm(click.style('Hello World!', fg='green'), abort=True)


def test_confirm_strips_ansi_with_color_false():
    runner = CliRunner()
    result = runner.invoke(cmd_confirm, input="y", color=False)
    assert result.output == "Hello World! [y/N]: y\n"  # FAILS: ANSI codes present
```

With Click 8.3.3 the assertion passes. With Click 8.4.0/8.4.1 it fails:
the ANSI codes remain in `result.output`.

The ANSI codes should be stripped when running `click.confirm` (and
`click.prompt`), as they are for `click.echo`, when the stream does not
support colors.

Environment: Click 8.4.1, Python 3.13, macOS.

Fix this issue.

Work in the current repository. Implement the change the issue describes,
in the same spirit and scope. Do not add new dependencies, do not reformat
unrelated code. Do not commit — leave your changes in the working tree.
