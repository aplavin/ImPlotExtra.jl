module ImPlotExtra

import CImGui
const ig = CImGui
import ImPlot
import ColorSchemes
using ColorSchemes: ColorScheme
using ColorTypes: Colorant, RGBA, red, green, blue, alpha
using FixedPointNumbers: N0f8
using IntervalSets: AbstractInterval, leftendpoint, rightendpoint, (..)

function image! end         # forward declaration so the export is always bound (Aqua undefined_exports)
function contour! end
function colorbar! end
function tickvalues end
function setup_axis_scale! end
export image!, contour!, colorbar!, SymLog, BaseMulTicks, tickvalues, scale_ticks, setup_axis_scale!

include("image.jl")
include("contour.jl")
include("colorbar.jl")
include("axis_scale.jl")

__init__() = foreach(c -> ig.atrenderexit(() -> _release!(c)), (_IMAGE_CACHE, _CONTOUR_CACHE))   # free caches on render-loop exit

end
