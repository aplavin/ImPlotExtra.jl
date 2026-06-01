# examples/example.jl — run with:  julia --project=examples examples/example.jl   (needs a display/GPU)
#
# First-time setup of the examples env:
#   julia> import Pkg; Pkg.activate("examples"); Pkg.develop(path="."); Pkg.instantiate()
#
# Demonstrates ImPlotExtra.image! — a performant replacement for ImPlot.PlotHeatmap that
# uploads the matrix once as a GPU texture and draws a single quad.

using ImPlotExtra
import GLFW, ModernGL                        # loads CImGui's GlfwOpenGL3 backend extension
import CImGui as ig
import ImPlot
using IntervalSets: (..)
using ColorSchemes: colorschemes
using ColorTypes: RGB

ig.set_backend(:GlfwOpenGL3)
ctx  = ig.CreateContext()
pctx = ImPlot.CreateContext(); ImPlot.SetImGuiContext(ctx)

const STATIC = Float32[sin(i/30) * cos(j/45) for i in 1:1024, j in 1:1024]   # variant 1: large static matrix
const RGBIMG = [RGB(i/64, j/64, 0.5) for i in 1:64, j in 1:64]               # variant 3: precomputed RGB image

ig.render(ctx; on_exit = () -> ImPlot.DestroyContext(pctx)) do
    if ig.Begin("ImPlotExtra.image! demo")
        t = ig.GetTime()

        ig.SeparatorText("1 — large scalar matrix, viridis (single quad; pan/zoom is free)")
        if ImPlot.BeginPlot("##static", "x", "y", ig.ImVec2(-1, 200))
            ImPlotExtra.image!("static", STATIC; colormap=:viridis)          # cached: uploaded once
            ImPlot.EndPlot()
        end

        ig.SeparatorText("2 — animated field: extent 0..10, colorrange, sqrt colorscale, magma")
        anim = Float32[abs(sin(i/20 + t) + cos(j/25 - t)) for i in 1:256, j in 1:256]  # fresh array ⇒ re-uploads
        if ImPlot.BeginPlot("##anim", "x", "y", ig.ImVec2(-1, 200))
            ImPlotExtra.image!("anim", 0..10, 0..10, anim;
                               colormap=colorschemes[:magma], colorrange=(0.0, 2.0), colorscale=sqrt)
            ImPlot.EndPlot()
        end

        ig.SeparatorText("3 — direct RGB image (no colormap), nearest filtering")
        if ImPlot.BeginPlot("##rgb", "x", "y", ig.ImVec2(-1, 200))
            ImPlotExtra.image!("rgb", RGBIMG; interpolate=false)
            ImPlot.EndPlot()
        end
    end
    ig.End()
end
