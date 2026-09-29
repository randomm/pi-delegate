# Fix `copy`, `deepcopy` and `pickle` of `Sentinel` members

Just a small issue I encountered on Python 3.10, where `Enum` has no
`__deepcopy__`. Now that every parameter has a sentinel, `copy.deepcopy()`
of any `Option`, `Argument` or `Command` fails on Python 3.10. And
`pickle` fails on every Python version.

Fix this issue.

Work in the current repository (checked out at the parent of the
historical fix). Make the change the fix made, in the same spirit and
scope. Do not add new dependencies, do not reformat unrelated code. Do
not commit — leave your changes in the working tree.
