`split_fields` in linefields.py is buggy. The escape branch for a doubled
quote (`""` inside a quoted field) consumes only one of the two quote
characters (`i += 1` then `continue`, so the second `"` is read back on the
next loop turn): the orphan quote flips `in_quotes` off, the rest of the
quoted field leaks out with its commas, and a later `"` re-enters the quoted
state. Fix the branch to consume **both** quote characters (advance past the
pair) and keep the field in the quoted state. Do not change behaviour for
any input without doubled quotes. Standard library only. Do not commit.

Verification command: `python3 -c "from linefields import split_fields; q = chr(34); assert split_fields('a,' + q + 'b' + q*2 + 'c' + q + ',d') == ['a', 'b' + q + 'c', 'd']"`
