import Test: @test
using SafeTestsets

# TODO(five): Add actual tests for SciML operations
@safetestset "sciml" begin include("sciml.jl") end 

# TODO(five): Add actual tests for scheduler API
@test 2 == 2