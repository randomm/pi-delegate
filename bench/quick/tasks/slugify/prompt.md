Implement `slugify(text)` in textutil.py: lowercase, strip accents (é -> e),
replace every run of non-alphanumeric characters with a single "-", and trim
leading/trailing "-". Empty or all-punctuation input gives "". Standard
library only. Do not commit.

Verification command: `python3 -c "from textutil import slugify; assert slugify('Hello, World!') == 'hello-world'"`
