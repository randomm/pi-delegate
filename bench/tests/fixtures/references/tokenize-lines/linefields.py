"""Split a log line into fields.

Rules: ',' separates fields; '"' starts and ends a quoted field, so a
quoted ',' is literal; '""' inside a quoted field stands for one literal
'"'. Standard library only.
"""


def split_fields(line):
    fields = []
    cur = []
    in_quotes = False
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"':
            if in_quotes and i + 1 < n and line[i + 1] == '"':
                cur.append('"')
                i += 2
                continue
            in_quotes = not in_quotes
        elif c == "," and not in_quotes:
            fields.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    fields.append("".join(cur))
    return fields
