struct ODEQuadratureAdjointSensitivityFunction{rateType,uType,uType2,UF,G,JC,GC,DG,TJ,SType,CV} <: SensitivityFunction
  uf::UF
  g::G
  J::TJ
  dg_val::uType
  jac_config::JC
  g_grad_config::GC
  sensealg::QuadratureAdjoint
  f_cache::rateType
  discrete::Bool
  y::uType2
  sol::SType
  dg::DG
  colorvec::CV
end

@noinline function ODEQuadratureAdjointSensitivityFunction(g,u0,p,sensealg,discrete,sol,dg,tspan,colorvec)
  numparams = length(p)
  numindvar = length(u0)
  # if there is an analytical Jacobian provided, we are not going to do automatic `jac*vec`
  f = sol.prob.f
  isautojacvec = DiffEqBase.has_jac(f) ? false : get_jacvec(sensealg)
  J = isautojacvec ? nothing : similar(u0, numindvar, numindvar)

  if !discrete
    if dg != nothing || isautojacvec
      pg = nothing
      pg_config = nothing
    else
      pg = UGradientWrapper(g,tspan[2],p)
      pg_config = build_grad_config(sensealg,pg,u0,p)
    end
  else
    pg = nothing
    pg_config = nothing
  end

  if isautojacvec
    jac_config = nothing
    uf = nothing
  else
    uf = DiffEqDiffTools.UJacobianWrapper(f,tspan[2],p)
    jac_config = build_jac_config(sensealg,uf,u0)
  end

  y = copy(sol(tspan[1])) # TODO: Has to start at interpolation value!
  dg_val = similar(u0, numindvar) # number of funcs size
  f_cache = deepcopy(u0)

  return ODEQuadratureAdjointSensitivityFunction(uf,pg,J,dg_val,
                                       jac_config,pg_config,
                                       sensealg,f_cache,
                                       discrete,y,sol,dg,
                                       colorvec)
end

# u = λ'
function (S::ODEQuadratureAdjointSensitivityFunction)(du,u,p,t)
  @unpack y, sol, J, uf, sensealg, f_cache, jac_config, discrete, dg, dg_val, g, g_grad_config = S
  idx = length(y)
  f = sol.prob.f
  isautojacvec = DiffEqBase.has_jac(f) ? false : get_jacvec(sensealg)
  sol(y,t)
  λ     = u
  dλ    = du

  if !isautojacvec
    if DiffEqBase.has_jac(f)
      f.jac(J,y,p,t) # Calculate the Jacobian into J
    else
      uf.t = t
      jacobian!(J, uf, y, f_cache, sensealg, jac_config)
    end
    mul!(dλ',λ',J)
  else
    _dy, back = Tracker.forward(y) do u
      if DiffEqBase.isinplace(sol.prob)
        out_ = map(zero, u)
        f(out_, u, p, t)
        Tracker.collect(out_)
      else
        vec(f(u, p, t))
      end
    end
    dλ[:] = Tracker.data(back(λ)[1])
  end

  dλ .*= -one(eltype(λ))

  if !discrete
    if dg != nothing
      dg(dg_val,y,p,t)
    else
      g.t = t
      gradient!(dg_val, g, y, sensealg, g_grad_config)
    end
    dλ .+= dg_val
  end

  nothing
end

# g is either g(t,u,p) or discrete g(t,u,i)
@noinline function ODEAdjointProblem(sol,sensealg::QuadratureAdjoint,g,
                                     t=nothing,dg=nothing,
                                     callback=CallbackSet())
  f = sol.prob.f
  tspan = (sol.prob.tspan[2],sol.prob.tspan[1])
  discrete = t != nothing

  p = sol.prob.p
  p === DiffEqBase.NullParameters() && error("Your model does not have parameters, and thus it is impossible to calculate the derivative of the solution with respect to the parameters. Your model must have parameters to use parameter sensitivity calculations!")

  u0 = zero(sol.prob.u0)

  len = length(u0)
  λ = similar(u0, len)
  sense = ODEQuadratureAdjointSensitivityFunction(g,u0,
                                        p,sensealg,discrete,
                                        sol,dg,tspan,f.colorvec)

  init_cb = t !== nothing && sol.prob.tspan[2] == t[end]
  cb = generate_callbacks(sense, g, λ, t, callback, init_cb)
  z0 = vec(zero(λ))
  ODEProblem(sense,z0,tspan,p,callback=cb)
end

struct AdjointSensitivityIntegrand{pType,uType,rateType,S,AS,PF,PJC,PJT}
  sol::S
  adj_sol::AS
  p::pType
  y::uType
  λ::uType
  pf::PF
  f_cache::rateType
  pJ::PJT
  paramjac_config::PJC
  sensealg::QuadratureAdjoint
end

function AdjointSensitivityIntegrand(sol,adj_sol,sensealg)
  prob = sol.prob
  @unpack f, p, tspan, u0 = prob
  y = similar(sol.prob.u0)
  λ = similar(adj_sol.prob.u0)
  # we need to alias `y`
  pf = DiffEqDiffTools.ParamJacobianWrapper(f,tspan[1],y)
  f_cache = similar(y)
  isautojacvec = get_jacvec(sensealg)
  pJ = isautojacvec ? nothing : similar(u0,length(u0),length(p))

  if DiffEqBase.has_paramjac(f) || isautojacvec
    paramjac_config = nothing
  else
    paramjac_config = build_param_jac_config(sensealg,pf,y,p)
  end
  AdjointSensitivityIntegrand(sol,adj_sol,p,y,λ,pf,f_cache,pJ,paramjac_config,sensealg)
end

function (S::AdjointSensitivityIntegrand)(out,t)
  @unpack y, λ, pJ, pf, p, f_cache, paramjac_config, sensealg, sol, adj_sol = S
  f = sol.prob.f
  sol(y,t)
  adj_sol(λ,t)
  λ .*= -one(eltype(λ))
  isautojacvec = get_jacvec(sensealg)
  # y is aliased
  pf.t = t

  if !isautojacvec
    if DiffEqBase.has_paramjac(f)
      f.paramjac(pJ,y,p,t) # Calculate the parameter Jacobian into pJ
    else
      jacobian!(pJ, pf, p, f_cache, sensealg, paramjac_config)
    end
    mul!(out',λ',pJ)
  else
    _, back = Tracker.forward(y, p) do u, p
      if DiffEqBase.isinplace(sol.prob)
        out_ = map(zero, u)
        f(out_, u, p, t)
        Tracker.collect(out_)
      else
        vec(f(u, p, t))
      end
    end
    out[:] = vec(Tracker.data(back(λ)[2]))
  end
  out'
end

function (S::AdjointSensitivityIntegrand)(t)
  out = similar(S.p)
  S(out,t)
end

function _adjoint_sensitivities_u0(sol,sensealg::QuadratureAdjoint,args...;kwargs...)
  error("Can't get sensitivities of u0 with quadrature.")
end

function _adjoint_sensitivities(sol,sensealg::QuadratureAdjoint,alg,g,
                                t=nothing,dg=nothing;
                                abstol=1e-6,reltol=1e-3,
                                iabstol=abstol, ireltol=reltol,
                                kwargs...)
  adj_prob = ODEAdjointProblem(sol,sensealg,g,t,dg)
  adj_sol = solve(adj_prob,alg;abstol=abstol,reltol=reltol,
                               save_everystep=true,save_start=true,kwargs...)
  integrand = AdjointSensitivityIntegrand(sol,adj_sol,sensealg)

  if t === nothing
    res,err = quadgk(integrand,sol.prob.tspan[1],sol.prob.tspan[2],
                   atol=iabstol,rtol=ireltol)
  else
    res = zero(integrand.p)'
    for i in 1:length(t)-1
      res .+= quadgk(integrand,t[i],t[i+1],
                     atol=iabstol,rtol=ireltol)[1]
    end
    if t[1] != sol.prob.tspan[1]
      res .+= quadgk(integrand,sol.prob.tspan[1],t[1],
                     atol=iabstol,rtol=ireltol)[1]
    end
  end
  res
end
