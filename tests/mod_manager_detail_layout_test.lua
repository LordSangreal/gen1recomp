-- ManagerState.detailLayout: the action rows never land on the footer line.
--
-- The bug this pins: a mod that declares options has five detail rows
-- (DISABLE, OPTIONS.., FOR .., GH .., BACK).  Laid out downward from a fixed
-- row 11 the fifth one landed on row 15, where drawFooter writes
-- "A:CHOOSE B:BACK", and the two strings drew on top of each other.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local S = require("tests.harness").suite("mod manager detail layout")
local eq = S.eq
local check = S.check

local ManagerState = require("src.mods.ManagerState")

local DESC_ROW, FOOTER_ROW = 6, 15

-- The rows actually drawn, as tile-y values, for a given row count.
local function rowsAt(count, cursor)
  local at = ManagerState.detailLayout(count, cursor)
  local ys, y = {}, at.top
  for _ = at.first, math.min(at.first + at.fits - 1, count) do
    ys[#ys + 1] = y
    y = y + 1
  end
  return ys, at
end

-- Four rows is the pre-existing shape (no options declared); it must keep
-- drawing exactly where it always did, or this "fix" is a regression.
local ys, at = rowsAt(4, 1)
eq(at.top, 11, "four rows still start on row 11")
eq(at.visible, 5, "four rows still leave five description lines")
eq(#ys, 4, "four rows all drawn")
eq(ys[#ys], 14, "last of four sits just above the footer")

-- Five rows is the reported bug.
ys, at = rowsAt(5, 1)
eq(#ys, 5, "five rows all drawn")
eq(ys[#ys], 14, "fifth row stops above the footer instead of on it")
eq(at.visible, 4, "the description gives up one line to make room")

-- The invariant, over every count a detailRows call can produce.
for count = 1, 12 do
  for cursor = 1, count do
    local seen, layout = rowsAt(count, cursor)
    for _, y in ipairs(seen) do
      check(y < FOOTER_ROW,
        ("row of %d (cursor %d) drew on the footer line"):format(count, cursor))
      check(y > DESC_ROW,
        ("row of %d (cursor %d) drew over the description"):format(count, cursor))
    end
    check(layout.visible >= 1,
      ("count %d left no description line at all"):format(count))
    -- a row block that cannot hold everything must still hold the cursor,
    -- otherwise the player moves onto a row they cannot see
    check(cursor >= layout.first and cursor < layout.first + layout.fits,
      ("cursor %d of %d scrolled out of view"):format(cursor, count))
  end
end

-- The description keeps its own top line wherever the block ends up.
for count = 1, 12 do
  local layout = ManagerState.detailLayout(count, 1)
  eq(DESC_ROW + layout.visible, layout.top,
    ("count %d leaves a gap or an overlap between description and rows")
      :format(count))
end

S.finish()
