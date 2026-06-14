local M = {}

local git = require("neogit.lib.git")
local config = require("neogit.config")

local function notify_error(message)
  vim.schedule(function()
    vim.notify("diffs: " .. message, vim.log.levels.ERROR)
  end)
end

local function setup_on_close(opts)
  if opts.on_close then
    vim.api.nvim_create_autocmd({ "BufEnter" }, {
      buffer = opts.on_close.handle,
      once = true,
      callback = opts.on_close.fn,
    })
  end
end

local function get_commands()
  local ok, commands = pcall(require, "diffs.commands")
  if not ok then
    notify_error("failed to load diffs.commands (" .. tostring(commands) .. ")")
    return nil
  end

  local missing = {}
  for _, fn in ipairs { "diff_section", "diff_file", "review" } do
    if type(commands[fn]) ~= "function" then
      table.insert(missing, "diffs.commands." .. fn)
    end
  end

  if #missing > 0 then
    notify_error("unsupported diffs.nvim API; missing: " .. table.concat(missing, ", "))
    return nil
  end

  return commands
end

---Normalize a selected reference (branch, tag, stash, oid). The name is used
---verbatim aside from trimming and pulling out a `stash@{n}` ref when present.
---@param item_name string
---@return string|nil
local function normalize_ref(item_name)
  if type(item_name) ~= "string" then
    return nil
  end

  local trimmed = vim.trim(item_name)
  if trimmed == "" then
    return nil
  end

  -- stash refs come through as `stash@{n}: <message>`
  local stash_ref = trimmed:match("(stash@{%d+})")
  if stash_ref then
    return stash_ref
  end

  return trimmed
end

---Extract a commit oid from a log/recent item name, which may carry trailing
---decoration such as the commit subject.
---@param item_name string
---@return string|nil
local function extract_commit(item_name)
  if type(item_name) ~= "string" then
    return nil
  end

  return vim.trim(item_name):match("[0-9a-fA-F]+")
end

---Parse a `a..b` / `a...b` range expression into a diffs.nvim review spec.
---@param range string
---@return { base: string, target: string, mode: string }|nil
local function parse_range(range)
  if type(range) ~= "string" then
    return nil
  end

  local base, target = range:match("^(.-)%.%.%.(.+)$")
  if base then
    if base == "" or target == "" then
      return nil
    end
    return { base = base, target = target, mode = "merge-base" }
  end

  base, target = range:match("^(.-)%.%.(.+)$")
  if base then
    if base == "" or target == "" then
      return nil
    end
    return { base = base, target = target, mode = "direct" }
  end

  return nil
end

---@param section_name string
---@param item_name    string|string[]|nil
---@param opts         table|nil
function M.open(section_name, item_name, opts)
  opts = opts or {}

  local commands = get_commands()
  if not commands then
    return
  end

  setup_on_close(opts)

  local repo_root = git.repo.worktree_root
  if type(repo_root) ~= "string" or repo_root == "" then
    notify_error("git root is unavailable")
    return
  end

  local viewer_opts = config.values.diff_viewer_opts or {}
  -- diffs.nvim opens a vsplit when `vertical` is true, otherwise a horizontal
  -- split. Honor Neogit's `diff_viewer_opts.split` setting (defaults to "vertical").
  local vertical = viewer_opts.split ~= "horizontal"
  -- Use stacked layout (single rail) by default; override via diff_viewer_opts.rail_style.
  local rail_style = viewer_opts.rail_style or "single"

  local function do_review(spec)
    spec.repo = repo_root
    spec.vertical = vertical
    return commands.review(spec, { rail_style = rail_style })
  end

  local function do_diff_file(path, file_opts)
    file_opts = file_opts or {}
    file_opts.vertical = vertical
    file_opts.rail_style = rail_style
    return commands.diff_file(path, file_opts)
  end

  local function do_diff_section(staged)
    return commands.diff_section(repo_root, { staged = staged, vertical = vertical, rail_style = rail_style })
  end

  -- selene: allow(if_same_then_else)
  if section_name == "staged" or section_name == "unstaged" or section_name == "merge" then
    local staged = section_name == "staged"
    if type(item_name) == "string" and item_name ~= "" then
      do_diff_file(repo_root .. "/" .. item_name, { staged = staged })
    else
      do_diff_section(staged)
    end
  elseif
    section_name == "recent"
    or section_name == "log"
    or (section_name and section_name:match("unmerged$"))
  then
    if type(item_name) == "table" then
      local from = normalize_ref(item_name[1])
      local to = normalize_ref(item_name[#item_name])
      if not from or not to then
        notify_error("invalid commit range selection")
        return
      end
      do_review { base = from, target = to, mode = "direct" }
    elseif type(item_name) == "string" then
      local commit = extract_commit(item_name)
      if not commit then
        notify_error("could not determine commit from selection")
        return
      end
      do_review { base = commit .. "^", target = commit, mode = "direct" }
    end
  elseif section_name == "range" and type(item_name) == "string" then
    local range = parse_range(item_name)
    if not range then
      notify_error(("invalid range '%s'"):format(item_name))
      return
    end
    do_review { base = range.base, target = range.target, mode = range.mode }
  elseif (section_name == "stashes" or section_name == "commit") and type(item_name) == "string" then
    local ref = normalize_ref(item_name)
    if not ref then
      notify_error("could not determine reference from selection")
      return
    end
    do_review { base = ref .. "^", target = ref, mode = "direct" }
  elseif section_name == "conflict" and item_name then
    local file_path = type(item_name) == "string" and item_name or item_name[1]
    if not file_path then
      notify_error("missing conflict file path")
      return
    end
    do_diff_file(repo_root .. "/" .. file_path, { unmerged = true })
  elseif
    section_name == "conflict"
    or section_name == "worktree"
    or (section_name == nil and item_name == nil)
  then
    -- All uncommitted changes against HEAD; routed through review so every
    -- changed file lands in the quickfix and location lists.
    do_review { base = "HEAD" }
  elseif section_name == nil and type(item_name) == "string" then
    local ref = normalize_ref(item_name)
    if not ref then
      notify_error("could not determine reference from selection")
      return
    end
    do_review { base = ref .. "^", target = ref, mode = "direct" }
  end
end

return M
