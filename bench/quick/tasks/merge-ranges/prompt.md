`merge` in ranges.py has bugs: ranges that touch (e.g. (1,2) and (2,3)) must
merge into (1,3), and a range fully inside another must not shrink it
(e.g. (1,10),(2,3) -> (1,10)). Fix it. Standard library only. Do not commit.

Verification command: `python3 -c "from ranges import merge; assert merge([(1, 2), (2, 3)]) == [(1, 3)]"`
