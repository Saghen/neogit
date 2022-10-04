local a = require("plenary.async")

local Buffer = require("neogit.lib.buffer")
local function trim_newlines(s)
  return (string.gsub(s, "^(.-)\n*$", "%1"))
end

local function remove_escape_codes(s)
  -- from: https://stackoverflow.com/questions/48948630/lua-ansi-escapes-pattern

  return s:gsub("[\27\155][][()#;?%d]*[A-PRZcf-ntqry=><~]", ""):gsub("[\r\n]", "")
end

---@class Process
---@field cwd string|nil
---@field cmd string[]
---@field env table<string, string>|nil
---@field verbose boolean If true, stdout will be written to the console buffer
---@field input string|nil
---@field result ProcessResult|nil
local Process = {}
Process.__index = Process

---@type { number: Process }
local processes = {}

---@class ProcessResult
---@field stdout string[]
---@field stderr string[]
---@field code number
---@field time number seconds
local ProcessResult = {}

---@param process Process
---@return Process
function Process:new(process)
  return setmetatable(process, self)
end

local preview_buffer = nil

local function create_preview_buffer()
  -- May be called multiple times due to scheduling
  if preview_buffer then
    return
  end

  local name = "Neogit log"
  local cur = vim.fn.bufnr(name)
  if cur and cur ~= -1 then
    vim.api.nvim_buf_delete(cur, { force = true })
  end

  local buffer = Buffer.create {
    name = name,
    bufhidden = "hide",
    filetype = "terminal",
    kind = "split",
    open = false,
    mappings = {
      n = {
        ["q"] = function(buffer)
          buffer:close(true)
        end,
      },
    },
    autocmds = {
      ["BufUnload"] = function()
        preview_buffer = nil
      end,
    },
  }

  local chan = vim.api.nvim_open_term(buffer.handle, {})

  preview_buffer = {
    chan = chan,
    buffer = buffer,
    current_span = nil,
  }
end

local function show_preview_buffer()
  if not preview_buffer then
    create_preview_buffer()
  end

  preview_buffer.buffer:show()
  -- vim.api.nvim_win_call(win, function()
  --   vim.cmd("normal! G")
  -- end)
end

local nvim_chan_send = vim.api.nvim_chan_send

---@param process Process
---@param data string
local function append_log(process, data)
  local function append()
    if preview_buffer.current_span ~= process.job then
      nvim_chan_send(preview_buffer.chan, string.format("\r\n> %s\r\n", table.concat(process.cmd, " ")))
      preview_buffer.current_span = process.job
    end

    -- Explicitly reset indent
    -- https://github.com/neovim/neovim/issues/14557
    data = data:gsub("\n", "\r\n")
    nvim_chan_send(preview_buffer.chan, data)
  end

  if not preview_buffer then
    vim.schedule(function()
      create_preview_buffer()
      append()
    end)
  else
    append()
  end
end

local hide_console = false
function Process.hide_preview_buffers()
  hide_console = true
  --- Stop all times from opening the buffer
  for _, v in pairs(processes) do
    v:stop_timer()
  end

  if preview_buffer then
    preview_buffer.buffer:hide()
  end
end

local config = require("neogit.config")
function Process:start_timer()
  if self.timer == nil then
    local timer = vim.loop.new_timer()
    timer:start(
      config.values.console_timeout,
      0,
      vim.schedule_wrap(function()
        self.timer = nil
        timer:stop()
        timer:close()
        if not self.result or self.result.code ~= 0 then
          if not self.verbose then
            append_log(self, table.concat(self.result.stdout, "\n"))
          end
          append_log(
            self,
            string.format("Command running for: %.2f ms", (vim.loop.hrtime() - self.start) / 1e6)
          )
          show_preview_buffer()
        end
      end)
    )
    self.timer = timer
  end
end

function Process:stop_timer()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

function Process.defer_show_preview_buffers()
  hide_console = false
  --- Start the timers again, making all proceses show the log buffer on a long
  --- running command
  for _, v in pairs(processes) do
    v:start_timer()
  end
end

--- Blocks until process completes
---@param timeout number|nil
---@return ProcessResult
function Process:wait(timeout)
  if not self.job then
    error("Process not started")
  end
  if timeout then
    vim.fn.jobwait({ self.job }, timeout)
  else
    vim.fn.jobwait { self.job }
  end
  assert(self.result ~= nil)
  return self.result
end

--- Spawn and await the process
--- Must be called inside a plenary async context
---@return ProcessResult
function Process:spawn_async()
  return a.wrap(Process.spawn, 2)(self)
end

--- Spawn and block until the process completes
---@return ProcessResult
function Process:spawn_blocking()
  self:spawn()
  return self:wait()
end

---Spawns a process in the background and returns immediately
---@param cb fun(ProcessResult)|nil
---@return boolean success
function Process:spawn(cb)
  ---@type ProcessResult
  local res = {
    stdout = { "" },
    stderr = { "" },
  }

  assert(self.job == nil, "Process started twice")
  -- An empty table is treated as an array
  self.env = self.env or {}
  self.env.TERM = "xterm-256color"

  local start = vim.loop.hrtime()
  self.start = start
  self.result = res

  local function on_stdout(_, data)
    local d = remove_escape_codes(data[1])
    res.stdout[#res.stdout] = res.stdout[#res.stdout] .. d

    for i = 2, #data do
      d = remove_escape_codes(data[i])

      table.insert(res.stdout, d)
    end

    if self.verbose then
      append_log(self, table.concat(data))
    end
  end

  local function on_stderr(_, data)
    local d = remove_escape_codes(data[1])
    res.stderr[#res.stderr] = res.stderr[#res.stderr] .. d

    for i = 2, #data do
      d = remove_escape_codes(data[i])
      table.insert(res.stderr, d)
    end

    append_log(self, table.concat(data))
  end

  local function on_exit(_, code)
    print("Finished command: ", vim.inspect(self.cmd))
    res.stdout = vim.tbl_filter(function(v)
      return v ~= ""
    end, res.stdout)

    res.stderr = vim.tbl_filter(function(v)
      return v ~= ""
    end, res.stderr)

    res.code = code
    res.time = (vim.loop.hrtime() - start) / 1e6

    -- Remove self
    processes[self.job] = nil
    self.result = res
    self:stop_timer()

    if self.verbose and code ~= 0 and not hide_console then
      vim.schedule(show_preview_buffer)
    end

    if cb then
      cb(res)
    end
  end
  print("Running command: ", vim.inspect(self))

  local job = vim.fn.jobstart(self.cmd, {
    cwd = self.cwd,
    env = self.env,
    -- Fake a small standard terminal
    pty = true,
    width = 80,
    height = 24,
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
  })

  if job <= 0 then
    error("Failed to start process: ", vim.inspect(self))
    return false
  end

  processes[job] = self
  self.job = job

  if not hide_console then
    self:start_timer()
  end

  -- local params = {
  --   stdio = { stdin, stdout, stderr },
  -- }
  -- if options.env then
  --   params.env = {}
  --   -- setting 'env' completely overrides the parent environment, so we need to
  --   -- append all variables that are necessary for git to work in addition to
  --   -- all variables from passed object.
  --   table.insert(params.env, string.format("%s=%s", "HOME", os.getenv("HOME")))
  --   table.insert(params.env, string.format("%s=%s", "GNUPGHOME", os.getenv("GNUPGHOME") or ""))
  --   table.insert(params.env, string.format("%s=%s", "NVIM", vim.v.servername))
  --   table.insert(params.env, string.format("%s=%s", "PATH", os.getenv("PATH")))
  --   table.insert(params.env, string.format("%s=%s", "SSH_AUTH_SOCK", os.getenv("SSH_AUTH_SOCK") or ""))
  --   table.insert(params.env, string.format("%s=%s", "SSH_AGENT_PID", os.getenv("SSH_AGENT_PID") or ""))
  --   for k, v in pairs(options.env) do
  --     table.insert(params.env, string.format("%s=%s", k, v))
  --   end
  -- end

  --handle, err = vim.loop.spawn(options.cmd, params, function(code, _)
  --  handle:close()

  --  return_code = code
  --  process.code = code
  --  -- Remove process
  --  processes[process.handle] = nil
  --  if process.timer then
  --    process:stop_timer()
  --  end
  --  if verbose and code ~= 0 and not hide_console then
  --    vim.schedule(show_preview_buffer)
  --  end
  --  process_closed = true
  --  raise_if_fully_closed()
  --end)
  ----print('started process', vim.inspect(params), '->', handle, err, '@'..(params.cwd or '')..'@', options.input)
  --if not handle then
  --  stdout:close()
  --  stderr:close()
  --  stdin:close()
  --  error(err)
  --end

  if self.input ~= nil then
    assert(type(self.input) == "string")
    vim.api.nvim_chan_send(job, self.input)
  end

  vim.fn.chanclose(job, "stdin")

  return true
end

return Process
