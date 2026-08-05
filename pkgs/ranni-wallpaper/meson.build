project(
  'ranni-wallpaper',
  ['c', 'cpp'],
  version: '0.1.0',
  meson_version: '>=1.4.0',
  default_options: [
    'cpp_std=c++23',
    'warning_level=3',
    'buildtype=release',
    'b_lto=true',
  ],
)

add_project_arguments('-D_GNU_SOURCE', language: ['c', 'cpp'])

wayland_client = dependency('wayland-client')
egl = dependency('egl')
gles = dependency('glesv2')
gbm = dependency('gbm')
lz4 = dependency('liblz4')
wayland_protocols = dependency('wayland-protocols', native: true)
wlr_protocols = dependency('wlr-protocols', native: true)
wayland_scanner = find_program('wayland-scanner', native: true)

wayland_protocols_dir = wayland_protocols.get_variable(pkgconfig: 'pkgdatadir')
wlr_protocols_dir = wlr_protocols.get_variable(pkgconfig: 'pkgdatadir')
xdg_shell_xml = join_paths(
  wayland_protocols_dir,
  'stable',
  'xdg-shell',
  'xdg-shell.xml',
)
layer_shell_xml = join_paths(
  wlr_protocols_dir,
  'unstable',
  'wlr-layer-shell-unstable-v1.xml',
)

xdg_shell_source = custom_target(
  'xdg-shell-private-code',
  input: xdg_shell_xml,
  output: 'xdg-shell-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

layer_shell_header = custom_target(
  'wlr-layer-shell-client-header',
  input: layer_shell_xml,
  output: 'wlr-layer-shell-unstable-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)

layer_shell_source = custom_target(
  'wlr-layer-shell-private-code',
  input: layer_shell_xml,
  output: 'wlr-layer-shell-unstable-v1-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

executable(
  'ranni-wallpaper',
  [
    'src/main.cpp',
    'src/particle_system.cpp',
    'src/wallpaper_asset.cpp',
    xdg_shell_source,
    layer_shell_header,
    layer_shell_source,
  ],
  dependencies: [wayland_client, egl, gles, gbm, lz4],
  cpp_args: ['-Wconversion', '-Wsign-conversion'],
  install: true,
)
