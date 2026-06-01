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

@testitem "_colorrange" begin
    using Unitful: @u_str
    cr = ImPlotExtra._colorrange
    @test cr([1.0 2.0; 3.0 4.0], nothing) == (1.0, 4.0)
    @test cr([1.0 NaN; Inf 4.0], nothing) == (1.0, 4.0)          # skips non-finite
    @test cr([1.0 2.0], (0.0, 10.0)) == (0.0, 10.0)               # explicit passthrough
    @test cr([1.0u"m" 5.0u"m"], nothing) == (1.0u"m", 5.0u"m")    # Unitful
    @test_throws Exception cr([NaN NaN], nothing)                 # no finite values
end
