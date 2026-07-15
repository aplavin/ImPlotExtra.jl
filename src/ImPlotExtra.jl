module ImPlotExtra

import CImGui
const ig = CImGui
import ImPlot
import ColorSchemes
using ColorSchemes: ColorScheme
using ColorTypes: Colorant, RGBA, red, green, blue
using FixedPointNumbers: N0f8
using IntervalSets: AbstractInterval, leftendpoint, rightendpoint, (..)

function image! end         # forward declaration so the export is always bound (Aqua undefined_exports)
function colorbar! end
function tickvalues end
export image!, colorbar!, SymLog, BaseMulTicks, tickvalues, scale_ticks

include("image.jl")
include("colorbar.jl")

__init__() = ig.atrenderexit(_release_textures!)   # free cached textures on render-loop exit

end
