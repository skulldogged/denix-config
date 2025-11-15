local c = wezterm.config_builder()

wezterm.on('user-var-changed', function(window, pane, name, value)
  local overrides = window:get_config_overrides() or {}
  if name == 'ZEN_MODE' then
    local incremental = value:find('+')
    local number_value = tonumber(value)
    if incremental ~= nil then
      while number_value > 0 do
        window:perform_action(wezterm.action.IncreaseFontSize, pane)
        number_value = number_value - 1
      end
      overrides.enable_tab_bar = false
    elseif number_value < 0 then
      window:perform_action(wezterm.action.ResetFontSize, pane)
      overrides.font_size = nil
      overrides.enable_tab_bar = true
    else
      overrides.font_size = number_value
      overrides.enable_tab_bar = false
    end
  end
  window:set_config_overrides(overrides)
end)

wezterm.on('format-window-title', function(tab, pane, tabs, panes, config)
  local zoomed = ''

  if tab.active_pane.is_zoomed then
    zoomed = '[Z] '
  end

  local index = ''

  if #tabs > 1 then
    index = string.format('[%d/%d] ', tab.tab_index + 1, #tabs)
  end

  return 'WezTerm - ' .. zoomed .. index .. tab.active_pane.title
end)

wezterm.plugin.require('https://github.com/nekowinston/wezterm-bar').apply_to_config(c, {
  position = 'bottom',
  max_width = 32,
  dividers = 'slant_right',
  indicator = {
    leader = {
      enabled = true,
      off = ' ',
      on = ' ',
    },
    mode = {
      enabled = true,
      names = {
        resize_mode = 'RESIZE',
        copy_mode = 'VISUAL',
        search_mode = 'SEARCH',
      },
    },
  },
  tabs = {
    numerals = 'arabic',
    pane_count = 'subscript',
    brackets = {
      active = { '', ':' },
      inactive = { '', ':' },
    },
  },
  clock = {
    enabled = true,
    format = '%l:%M %p',
  },
})

local act = wezterm.action

local keybinds = {
  {
    key = 'Enter',
    mods = 'CTRL|SHIFT',
    action = act.SplitHorizontal({ domain = 'CurrentPaneDomain' }),
  },
  {
    key = 'h',
    mods = 'CTRL|SHIFT',
    action = act.ActivatePaneDirection('Left'),
  },
  {
    key = 'l',
    mods = 'CTRL|SHIFT',
    action = act.ActivatePaneDirection('Right'),
  },
  {
    key = 'k',
    mods = 'CTRL|SHIFT',
    action = act.ActivatePaneDirection('Up'),
  },
  {
    key = 'j',
    mods = 'CTRL|SHIFT',
    action = act.ActivatePaneDirection('Down'),
  },
  {
    key = 't',
    mods = 'CTRL|SHIFT',
    action = act.SpawnCommandInNewTab({ cwd = wezterm.home_dir }),
  },
}

local config = {
  adjust_window_size_when_changing_font_size = false,
  color_scheme = 'Catppuccin Mocha',
  cursor_blink_ease_in = 'Constant',
  cursor_blink_ease_out = 'Constant',
  cursor_blink_rate = 500,
  default_cursor_style = 'BlinkingBar',
  enable_scroll_bar = false,
  font = wezterm.font('Maple Mono NF'),
  font_size = 14,
  front_end = 'WebGpu',
  hide_tab_bar_if_only_one_tab = true,
  keys = keybinds,
  macos_window_background_blur = 32,
  use_fancy_tab_bar = false,
  webgpu_power_preference = 'HighPerformance',
  window_background_opacity = 0.85,
  window_decorations = 'RESIZE',
  window_padding = { left = 0, right = 0, top = 0, bottom = 0 },
}

for k, v in pairs(config) do
  c[k] = v
end

return c
