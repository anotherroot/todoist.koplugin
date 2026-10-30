std = "luajit+busted"
max_line_length = false
exclude_files = { ".dev/" }
-- `__` is the throwaway loop variable in files that use gettext as `_`.
ignore = { "213/__" }
read_globals = { "G_reader_settings" }
-- KOReader methods often ignore self
self = false
