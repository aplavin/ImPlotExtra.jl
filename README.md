# ImPlotExtra.jl

Performant image/heatmap display for ImPlot.jl: a large scalar matrix (colormapped) or an RGB(A) image is uploaded once as a GPU texture and drawn as a single quad — staying fast at high resolution, where `ImPlot.PlotHeatmap` slows down.

```julia
# inside an ImPlot.BeginPlot(...) / EndPlot() block, with a CImGui OpenGL backend active:
ImPlotExtra.image!("data", matrix)
```

See [`examples/example.jl`](examples/example.jl) for a runnable demo.
