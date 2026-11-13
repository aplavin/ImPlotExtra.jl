@testitem "_contour_lines: radial field ⇒ closed circles" begin
    using IntervalSets: (..)
    z = [hypot(x, y) for x in range(-2, 2; length=81), y in range(-2, 2; length=81)]   # pixel centers 0.05 apart
    ls = ImPlotExtra._contour_lines(-2..2, -2..2, z, [0.5, 1.0])
    @test [l.level for l in ls] == [0.5, 1.0]
    for (l, r) in zip(ls, (0.5, 1.0))
        @test count(isnan, l.x) == 1 && isnan(l.x[end]) && isnan(l.y[end])   # one curve, NaN-terminated
        x, y = l.x[1:end-1], l.y[1:end-1]
        @test (x[1], y[1]) == (x[end], y[end])                               # closed loop
        @test all(ρ -> isapprox(ρ, r; atol=1e-3), hypot.(x, y))
        @test length(x) > 50                                                 # traced, not a stub
    end
end

@testitem "_contour_lines: placement like image!" begin
    using IntervalSets: (..)
    data = [i + j - 1 for i in 1:4, j in 1:3]       # data[i,j] at (i,j) ⇒ level 3.5 is the line x + y = 4.5
    l = only(ImPlotExtra._contour_lines(1..4, 1..3, data, [3.5]))
    @test l.x[1:end-1] ≈ [1.5, 2.0, 2.5, 3.0, 3.5]
    @test l.y[1:end-1] ≈ [3.0, 2.5, 2.0, 1.5, 1.0]
    # same line shifted by an explicit extent (first/last pixel centers)
    l0 = only(ImPlotExtra._contour_lines(0..3, 10..12, data, [3.5]))
    @test l0.x[1:end-1] ≈ [0.5, 1.0, 1.5, 2.0, 2.5]
    @test l0.y[1:end-1] ≈ [12.0, 11.5, 11.0, 10.5, 10.0]
end

@testitem "_contour_lines: curves NaN-separated" begin
    using IntervalSets: (..)
    # two cones of radius-0.5 level circles centered at (±1, 0)
    z = [max(1 - hypot(x + 1, y), 1 - hypot(x - 1, y)) for x in range(-2, 2; length=81), y in range(-1, 1; length=41)]
    l = only(ImPlotExtra._contour_lines(-2..2, -1..1, z, [0.5]))
    nans = findall(isnan, l.x)
    @test length(nans) == 2 && nans[2] == length(l.x) && isnan.(l.y[nans]) == [true, true]
    curves = [(l.x[a:b-1], l.y[a:b-1]) for (a, b) in zip([1; nans[1] + 1], nans)]
    @test sort([sum(x) / length(x) for (x, _) in curves]) ≈ [-1.0, 1.0] atol=1e-2
    for (x, y) in curves
        c = sum(x) > 0 ? 1 : -1
        @test all(ρ -> isapprox(ρ, 0.5; atol=1e-3), hypot.(x .- c, y))
    end
end

@testitem "_contour_lines: Integer vs vector levels" begin
    using IntervalSets: (..)
    data = [i + j for i in 0:4, j in 0:4] .+ 0.0     # finite range 0..8
    data[5, 5] = NaN                                   # ignored by the level count ⇒ max is 7
    @test [l.level for l in ImPlotExtra._contour_lines(1..5, 1..5, data, 6)] ≈ [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
    @test [l.level for l in ImPlotExtra._contour_lines(1..5, 1..5, data, 1)] ≈ [3.5]
    ls = ImPlotExtra._contour_lines(1..5, 1..5, data, [5.5, 100.0, 0.5])   # order kept, out-of-range ⇒ empty
    @test [l.level for l in ls] == [5.5, 100.0, 0.5]
    @test isempty(ls[2].x) && isempty(ls[2].y)
    @test !isempty(ls[1].x) && !isempty(ls[3].x)
    @test isempty(ImPlotExtra._contour_lines(1..5, 1..5, data, Float64[]))
    @test_throws Exception ImPlotExtra._contour_lines(1..2, 1..2, [NaN NaN; NaN NaN], 3)   # no finite values
    @test_throws MethodError ImPlotExtra._contour_lines(1..5, 1..5, data, 2.5)
end

@testitem "_level_colors" begin
    using ColorTypes: RGB, RGBA
    using ImPlotExtra: ImPlot
    lc = ImPlotExtra._level_colors
    V = ImPlotExtra.ig.ImVec4
    @test lc(nothing, nothing, 2) == [ImPlot.IMPLOT_AUTO_COL, ImPlot.IMPLOT_AUTO_COL]
    @test lc(RGB(1, 0, 0), nothing, 2) == [V(1, 0, 0, 1), V(1, 0, 0, 1)]
    @test lc(RGBA(0, 0, 1, 0.5), nothing, 1) == [V(0, 0, 1, 0.5)]
    @test lc(nothing, [RGB(0, 0, 0), RGB(1, 1, 1)], 3) == [V(0, 0, 0, 1), V(0.5, 0.5, 0.5, 1), V(1, 1, 1, 1)]
    @test lc(nothing, [RGB(0, 0, 0), RGB(1, 1, 1)], 1) == [V(0.5, 0.5, 0.5, 1)]       # single level ⇒ middle
    vir = lc(nothing, :viridis, 2)
    @test [vir[1].x, vir[1].y, vir[1].z] ≈ [0.267004, 0.004874, 0.329415] atol=1e-6  # viridis start
    @test [vir[2].x, vir[2].y, vir[2].z] ≈ [0.993248, 0.906157, 0.143936] atol=1e-6  # viridis end
    @test isempty(lc(nothing, :viridis, 0))
    @test_throws MethodError lc(RGB(1, 0, 0), :viridis, 2)      # conflicting color + colormap
    @test_throws MethodError lc(:red, nothing, 2)               # color must be a Colorant
    @test_throws Exception lc(nothing, :not_a_real_colormap_xyz, 2)
end
