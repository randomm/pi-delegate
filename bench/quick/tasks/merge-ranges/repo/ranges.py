def merge(ranges):
    """Merge overlapping or touching (start, end) integer ranges."""
    out = []
    for start, end in sorted(ranges):
        if out and start < out[-1][1]:
            out[-1] = (out[-1][0], end)
        else:
            out.append((start, end))
    return out
