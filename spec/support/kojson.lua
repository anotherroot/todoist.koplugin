-- Puts KOReader's Lua libraries on the path so modules can require("json")
-- outside KOReader. scripts/test.sh sets KOREADER_DIR.
-- Returns { json = module } or { why = "reason it couldn't be loaded" }.
local koreader_dir = os.getenv("KOREADER_DIR")
if not koreader_dir then return { why = "KOREADER_DIR not set" } end
package.path = koreader_dir .. "/common/?.lua;" .. package.path
package.cpath = koreader_dir .. "/common/?.so;" .. koreader_dir .. "/libs/?.so;" .. package.cpath
local ok, json = pcall(require, "json")
if not ok then return { why = tostring(json) } end
return { json = json }
