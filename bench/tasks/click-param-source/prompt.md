# `get_parameter_source()` returns `None` during type conversion and in eager callbacks

Starting with 8.4, `get_parameter_source()` returns `None`.

Repro:

```python
import click

class Source(click.ParamType):
    name = "source"
    def convert(self, value, param, ctx):
        return {'value': value, 'source': ctx.get_parameter_source(param.name)}

@click.command
@click.option('--default', type=Source(), default='/tmp/file')
@click.option('--nodefault', type=Source())
def main(default, nodefault):
    print("default:", default)
    print("nodefault:", nodefault)

if __name__ == '__main__':
    main()
```

Output:

```console
$ python source.py
default: {'value': '/tmp/file', 'source': None}
nodefault: None
$ python source.py --default cli --nodefault cli
default: {'value': 'cli', 'source': None}
nodefault: {'value': 'cli', 'source': None}
```

With 8.3.x, `source` was `ParameterSource.DEFAULT` for the default value
and `ParameterSource.COMMANDLINE` for the command-line value.

Environment: Click 8.4.0 (seems to happen on all versions, on both macOS
and Linux).

Fix this issue.

Work in the current repository. Implement the change the issue describes,
in the same spirit and scope. Do not add new dependencies, do not reformat
unrelated code. Do not commit — leave your changes in the working tree.
