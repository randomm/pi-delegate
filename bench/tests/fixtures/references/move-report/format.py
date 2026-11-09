"""Rendering helpers."""


def render(totals):
    lines = []
    for region in sorted(totals):
        lines.append(f"{region}:")
        for product in sorted(totals[region]):
            lines.append(f"  {product} {totals[region][product]:.2f}")
    return "\n".join(lines)
