import Test: @test
using SafeTestsets

@safetestset "sciml" begin include("sciml.jl") end 
