using DiffEqSensitivity, SafeTestsets
using Test

const GROUP = get(ENV, "GROUP", "All")
const is_APPVEYOR = Sys.iswindows() && haskey(ENV,"APPVEYOR")
const is_TRAVIS = haskey(ENV,"TRAVIS")

@time begin
if GROUP == "All" || GROUP == "Core" || GROUP == "Downstream"
    @safetestset "Forward Sensitivity" begin include("forward.jl") end
    @safetestset "Adjoint Sensitivity" begin include("adjoint.jl") end
    @safetestset "Morris Method" begin include("morris_method.jl") end
    @safetestset "Sobol Method" begin include("sobol_method.jl") end
    @safetestset "DGSM Method" begin include("DGSM.jl") end
    @safetestset "eFAST Method" begin include("eFAST_method.jl") end
end

if GROUP == "DiffEqFlux"
    using Pkg
    if is_TRAVIS
      using Pkg
      Pkg.add("DiffEqFlux")
    end
    Pkg.test("DiffEqFlux")
end
end
