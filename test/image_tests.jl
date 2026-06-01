@testitem "resolve_scheme" begin
    using ColorSchemes: ColorScheme, colorschemes
    using ColorTypes: RGB
    rs = ImPlotExtra.resolve_scheme
    @test rs(:viridis) === colorschemes[:viridis]
    @test rs(colorschemes[:plasma]) === colorschemes[:plasma]
    cs = rs([RGB(0,0,0), RGB(1,1,1)])
    @test cs isa ColorScheme && length(cs.colors) == 2
    @test_throws Exception rs(:not_a_real_colormap_xyz)
end
