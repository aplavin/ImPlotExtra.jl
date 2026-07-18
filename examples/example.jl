# examples/example.jl — run with:  julia --project=examples examples/example.jl   (needs a display/GPU)
#
# First-time setup of the examples env:
#   julia> import Pkg; Pkg.activate("examples"); Pkg.develop(path="."); Pkg.instantiate()
#
# Two windows:
#   • "image! demo"    — ImPlotExtra.image!, a performant PlotHeatmap replacement (matrix → GPU texture → one quad).
#   • "colorbar! demo" — ImPlotExtra.colorbar!, static and INTERACTIVE (scroll = zoom, left-drag = pan),
#                        linked to an image! through a shared `Ref` colorrange, incl. symmetric mode & log/SymLog.

using ImPlotExtra
using ImPlotExtra: SymLog
import GLFW, ModernGL                        # loads CImGui's GlfwOpenGL3 backend extension
import CImGui as ig
import ImPlot
using IntervalSets: (..)
using ColorSchemes: colorschemes
using ColorTypes: RGB

ig.set_backend(:GlfwOpenGL3)
ctx  = ig.CreateContext()
pctx = ImPlot.CreateContext(); ImPlot.SetImGuiContext(ctx)

const STATIC = Float32[sin(i/30) * cos(j/45) for i in 1:1024, j in 1:1024]   # large static matrix, range ≈ [-1,1]
const RGBIMG = [RGB(i/64, j/64, 0.5) for i in 1:64, j in 1:64]               # precomputed RGB image
const POS    = Float32[exp((i+j)/40) for i in 1:256, j in 1:256]             # strictly positive ⇒ log10 colorscale
const DIVERG = Float32[sinpi(i/64) * cospi(j/64) * 3 for i in 1:256, j in 1:256]  # signed ⇒ SymLog + symmetric

# INTERACTIVE colorranges — one Ref per bar, kept across frames; the bar mutates it, the image reads it.
const CR_LIN = Ref((-1.0, 1.0))
const CR_LOG = Ref((1.0, exp(512/40)))
const CR_SYM = Ref((-3.0, 3.0))
const CR_ANC = Ref((-3.0, 3.0))
const SYMSCALE = SymLog(0.3)

# draw an interactive `image!` + linked `colorbar!` sharing `cr`; returns nothing
function image_with_bar(id, data, cr; colormap, colorscale=identity, symmetric=nothing, anchor=nothing)
    if ImPlot.BeginPlot("##$id", "x", "y", ig.ImVec2(-70, 200))
        ImPlotExtra.image!(id, data; colormap, colorrange=cr[], colorscale)
        ImPlot.EndPlot()
    end
    ig.SameLine()
    ImPlotExtra.colorbar!("$(id)_bar", colormap, cr, colorscale, 200; symmetric, anchor)
end

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

    if ig.Begin("ImPlotExtra.colorbar! demo")
        ig.TextWrapped("Scroll over a bar to zoom, left-drag to pan — the linked image tracks it (shared `Ref` colorrange).")

        ig.SeparatorText("A — static bar (plain tuple colorrange; draw-only, no interaction)")
        if ImPlot.BeginPlot("##statbar", "x", "y", ig.ImVec2(-70, 160))
            ImPlotExtra.image!("statimg", STATIC; colormap=:viridis, colorrange=(-1.0, 1.0))
            ImPlot.EndPlot()
        end
        ig.SameLine()
        ImPlotExtra.colorbar!("stat_bar", :viridis, (-1.0, 1.0), identity, 160)

        ig.SeparatorText("B — interactive, linear scale (viridis) — scroll zooms about cursor, drag pans")
        image_with_bar("linimg", STATIC, CR_LIN; colormap=:viridis)

        ig.SeparatorText("C — interactive, log10 colorscale (plasma) — zoom stays uniform on the (log) bar")
        image_with_bar("logimg", POS, CR_LOG; colormap=:plasma, colorscale=log10)

        ig.SeparatorText("D — interactive, SymLog + SYMMETRIC about 0 (balance) — scroll zooms; pan disabled")
        image_with_bar("symimg", DIVERG, CR_SYM; colormap=:balance, colorscale=SYMSCALE, symmetric=0.0)

        ig.SeparatorText("E — interactive, SymLog + fixed ANCHOR at 0 (balance) — zoom pins 0; pan still works")
        image_with_bar("ancimg", DIVERG, CR_ANC; colormap=:balance, colorscale=SYMSCALE, anchor=0.0)
    end
    ig.End()
end
