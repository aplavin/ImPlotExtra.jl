# ImPlotExtra.jl

Extra features for [ImPlot.jl](https://github.com/JuliaImGui/ImPlot.jl):

- `image!` — fast image/heatmap display. A large scalar matrix (colormapped) or an
  RGB(A) image is uploaded once as a GPU texture and drawn as a single quad, so it
  stays fast at resolutions where `ImPlot`'s `PlotHeatmap` slows down.
- `contour!` — contour lines (iso-lines) of a matrix, which ImPlot lacks. Traced by
  [Contour.jl](https://github.com/JuliaGeometry/Contour.jl) only when inputs change, drawn
  with one line per level; levels by count or explicit values, one color or a colormap.
- `colorbar!` — a colorbar for arbitrary nonlinear colorscales (e.g. logarithmic),
  with correct tick locations and labels. It is interactive: scroll to zoom, drag to
  pan the displayed range.

See the docstrings for details and arguments, and [`examples/example.jl`](examples/example.jl)
for a runnable demo.