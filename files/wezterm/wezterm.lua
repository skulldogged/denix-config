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
      overrides.enable_tab_bar = false
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

local act = wezterm.action

local keybinds = {
  {
    key = 'c',
    mods = 'CTRL|SHIFT',
    action = act.CopyTo('Clipboard'),
  },
  {
    key = 'v',
    mods = 'CTRL|SHIFT',
    action = act.PasteFrom('Clipboard'),
  },
  {
    key = 'f',
    mods = 'CTRL|SHIFT',
    action = act.Search('CurrentSelectionOrEmptyString'),
  },
  {
    key = '=',
    mods = 'CTRL|SHIFT',
    action = act.IncreaseFontSize,
  },
  {
    key = '-',
    mods = 'CTRL|SHIFT',
    action = act.DecreaseFontSize,
  },
  {
    key = '0',
    mods = 'CTRL|SHIFT',
    action = act.ResetFontSize,
  },
  {
    key = 'r',
    mods = 'CTRL|SHIFT',
    action = act.ReloadConfiguration,
  },
  {
    key = 't',
    mods = 'CTRL|SHIFT|ALT',
    action = act.SpawnCommandInNewWindow({
      args = { 'fish' },
      cwd = wezterm.home_dir,
    }),
  },
}

local config = {
  adjust_window_size_when_changing_font_size = false,
  check_for_updates = false,
  color_scheme = 'Catppuccin Mocha',
  cursor_blink_ease_in = 'Constant',
  cursor_blink_ease_out = 'Constant',
  cursor_blink_rate = 500,
  default_cursor_style = 'BlinkingBar',
  default_prog = { 'herdr' },
  disable_default_key_bindings = true,
  enable_kitty_graphics = true,
  enable_scroll_bar = false,
  enable_tab_bar = false,
  enable_wayland = true,
  font_size = 10,
  font = wezterm.font_with_fallback({
    { family = 'Maple Mono NF', weight = 'Regular' },
    'Twitter Color Emoji',
  }),
  front_end = 'WebGpu',
  webgpu_power_preference = 'HighPerformance',
  keys = keybinds,
  use_fancy_tab_bar = false,
  window_background_opacity = 0.8,
  window_decorations = 'NONE',
  warn_about_missing_glyphs = false,
  window_padding = { left = 0, right = 0, top = 0, bottom = 0 },
}

for k, v in pairs(config) do
  c[k] = v
end

return c
