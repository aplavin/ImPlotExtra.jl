# image!() and its private helpers — see plan.

resolve_scheme(s::ColorScheme) = s
resolve_scheme(v::AbstractVector{<:Colorant}) = ColorScheme(collect(v))
function resolve_scheme(s::Symbol)
    haskey(ColorSchemes.colorschemes, s) || error("unknown colormap $(repr(s)); see `keys(ColorSchemes.colorschemes)`")
    ColorSchemes.colorschemes[s]
end
