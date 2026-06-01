module ImPlotExtra

import CImGui
const ig = CImGui
import ImPlot
import ModernGL as GL
import ColorSchemes
using ColorSchemes: ColorScheme
using ColorTypes: Colorant, RGBA
using FixedPointNumbers: N0f8
using IntervalSets: AbstractInterval, leftendpoint, rightendpoint, (..)

function image! end         # forward declaration so the export is always bound (Aqua undefined_exports)
export image!

include("image.jl")

end
