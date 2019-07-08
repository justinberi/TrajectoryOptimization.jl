"Create a minimum time problem"
function minimum_time_problem(prob::Problem{T,Discrete},R_min_time::T=1.0,dt_max::T=1.0,dt_min::T=1.0e-3) where T
    # modify problem with time step control
    N = prob.N; n = prob.model.n; m = prob.model.m
    @assert all([prob.obj[k] isa QuadraticCost for k = 1:N]) #TODO generic cost

    # modify problem with slack control
    obj_mt = CostFunction[]
    for k = 1:N-1
        cost_mt = copy(prob.obj[k])
        push!(obj_mt,MinTimeCost(cost_mt,R_min_time))
    end
    cost_mt = copy(prob.obj[N])
    push!(obj_mt,MinTimeCost(cost_mt,R_min_time))

    model_min_time = add_min_time_controls(prob.model)
    constraints = mintime_constraints(prob,dt_max,dt_min)

    # con_prob = ConstraintSet[]
    # constrained = is_constrained(prob)
    # for k = 1:N-1
    #     con_mt = AbstractConstraint[]
    #     constrained ? append!(con_mt,update_constraint_set_jacobians(prob.constraints[k],prob.model.n,prob.model.n+1,prob.model.m)) : nothing
    #     push!(con_mt,con_min_time_bnd)
    #     k != 1 ? push!(con_mt,con_min_time_eq) : nothing
    #     push!(con_prob,con_mt)
    # end
    # constrained ? push!(con_prob,prob.constraints[N]) : push!(con_prob,Constraint[])

    # return con_prob, obj_mt
    update_problem(prob,model=model_min_time,obj=Objective(obj_mt),
        constraints=constraints,
        U=[[prob.U[k];sqrt(prob.dt)] for k = 1:prob.N-1],
        X=[[prob.X[k];sqrt(prob.dt)] for k = 1:prob.N],
        x0=[prob.x0;0.0])
end

function minimum_time_problem(prob::Problem{T,Continuous},R_min_time::T=1.0,dt_max::T=1.0,dt_min::T=1.0e-3) where T
    # modify problem with time step control
    N = prob.N; n = prob.model.n; m = prob.model.m
    @assert all([prob.obj[k] isa QuadraticCost for k = 1:N]) #TODO generic cost

    # modify problem with slack control
    obj_mt = CostFunction[]
    for k = 1:N-1
        cost_mt = copy(prob.obj[k])
        push!(obj_mt,MinTimeCost(cost_mt,R_min_time))
    end
    cost_mt = copy(prob.obj[N])
    push!(obj_mt,MinTimeCost(cost_mt,R_min_time))

    model_min_time = add_min_time_controls(prob.model)
    constraints = mintime_constraints(prob,dt_max,dt_min)

    # con_prob = ConstraintSet[]
    # constrained = is_constrained(prob)
    # for k = 1:N-1
    #     con_mt = AbstractConstraint[]
    #     constrained ? append!(con_mt,update_constraint_set_jacobians(prob.constraints[k],prob.model.n,prob.model.n+1,prob.model.m)) : nothing
    #     push!(con_mt,con_min_time_bnd)
    #     k != 1 ? push!(con_mt,con_min_time_eq) : nothing
    #     push!(con_prob,con_mt)
    # end
    # constrained ? push!(con_prob,prob.constraints[N]) : push!(con_prob,Constraint[])

    # return con_prob, obj_mt
    update_problem(prob,model=model_min_time,obj=Objective(obj_mt),
        constraints=constraints,
        U=[[prob.U[k];sqrt(prob.dt)] for k = 1:prob.N-1],
        X=[[prob.X[k];sqrt(prob.dt)] for k = 1:prob.N],
        x0=[prob.x0;0.0])
end

"Return the total duration of trajectory"
function total_time(prob::Problem{T}) where T
    m̄ = prob.model.m + 1
    tt = 0.0
    try
        tt = sum([prob.U[k][m̄] for k = 1:prob.N-1])
    catch
        tt = prob.dt*(prob.N-1)
    end
    return tt
end

"Add minimum time controls to dynamics "
function add_min_time_controls(model::Model{Nominal,Discrete})
    n = model.n; m = model.m
    n̄ = n+1; m̄ = m+1; n̄m̄ = n̄+m̄
    idx = merge(create_partition((m,1),(:u,:mintime)),(x=1:n,))
    idx2 = [idx.x...,(idx.u .+ n̄)...,n̄m̄]

    function f!(x₊::AbstractVector{T},x::AbstractVector{T},u::AbstractVector{T},dt::T) where T
        h = u[end]
        model.f(view(x₊,idx.x),x[idx.x],u[idx.u],h^2)
        x₊[n̄] = h
    end

    function ∇f!(Z::AbstractMatrix{T},x::AbstractVector{T},u::AbstractVector{T},dt::T) where T
        h = u[end]
        model.∇f(view(Z,idx.x,idx2),x[idx.x],u[idx.u],h^2)
        Z[idx.x,n̄m̄] .*= 2*h
        Z[n̄,n̄m̄] = 1.0
    end
    AnalyticalModel{Nominal,Discrete}(f!,∇f!,n̄,m̄,model.r,model.params,model.info)
end

function add_min_time_controls(model::Model{Nominal,Continuous})
    m̄ = model.m+1;

    AnalyticalModel{Nominal,Continuous}(model.f!,model.∇f!,model.n,m̄,model.r,model.params,model.info)
end

function mintime_equality(n::Int,m::Int)
    n̄ = n+1; m̄ = m+1; idx_h = n+m+2
    ∇con_eq = zeros(1,idx_h)
    ∇con_eq[1,idx_h] = 1.0
    ∇con_eq[1,n̄] = -1.0

    function con_eq(v,x,u)
        v[1] = u[end] - x[end]
    end

    jac_eq(C,x,u) = copyto!(C, ∇con_eq)
    Constraint{Equality}(con_eq, jac_eq, 1, :min_time_eq, [collect(1:n̄), collect(1:m̄)], :stage, :xu)
end

function mintime_constraints(prob::Problem, dt_max::T=1.0, dt_min::T=1e-3) where T
    n,m,N = size(prob)
    mt_eq = mintime_equality(n,m)
    PC = copy(prob.constraints)
    mt_bnd = BoundConstraint(1,1, u_max=sqrt(dt_max), u_min=sqrt(dt_min))
    bnd0 = BoundConstraint(n,m)
    for k = 1:N
        bnd = remove_bounds!(PC[k])
        if isempty(bnd)
            bnd = bnd0
        else
            bnd = bnd[1]
        end
        bnd2 = combine(bnd,mt_bnd)
        PC[k] = update_constraint_set_jacobians(PC[k], n, n+1, m)
        PC[k] += bnd2
        if 1 < k < N
            PC[k] += mt_eq
        end
    end
    return PC
end

# Minimum Time Cost function
struct MinTimeCost{T} <: CostFunction
    cost::C where C <:CostFunction
    R_min_time::T
end

stage_cost(cost::MinTimeCost, x::Vector{T}, u::Vector{T}, h::T) where T = stage_cost(cost.cost,x[1:end-1],u[1:end-1],h) + cost.R_min_time*u[end]^2
stage_cost(cost::MinTimeCost, xN::Vector{T}) where T = stage_cost(cost.cost,xN[1:end-1])

get_sizes(cost::MinTimeCost) = get_sizes(cost.cost) .+ 1
copy(cost::MinTimeCost) = MinTimeCost(copy(cost.cost),copy(cost.R_min_time))

function cost_expansion!(Q::Expansion{T}, cost::MinTimeCost,
        x::AbstractVector{T}, u::AbstractVector{T}, _dt::T) where T

    @assert cost.cost isa QuadraticCost
    n,m = get_sizes(cost.cost)
    idx = (x=1:n,u=1:m)
    R_min_time = cost.R_min_time
    τ = u[end]
    dt = τ^2
    Qx = cost.cost.Q*x[idx.x] + cost.cost.q + cost.cost.H'*u[idx.u]
    Qu = cost.cost.R*u[idx.u] + cost.cost.r + cost.cost.H*x[idx.x]
    Q.x[idx.x] .= Qx*dt
    Q.u[idx.u] .= Qu*dt
    Q.xx[idx.x,idx.x] .= cost.cost.Q*dt
    Q.uu[idx.u,idx.u] .= cost.cost.R*dt
    Q.ux[idx.u,idx.x] .= cost.cost.H*dt

    ℓ1 = stage_cost(cost.cost,x[idx.x],u[idx.u],dt)
    tmp = 2.0*τ*Qu

    Q.u[end] = τ*(2.0*ℓ1 + R_min_time)
    Q.uu[idx.u,end] = tmp
    Q.uu[end,idx.u] = tmp'
    Q.uu[end,end] = (2.0*ℓ1 + R_min_time)
    Q.ux[end,idx.x] = 2.0*τ*Qx'

    Q.x[end] = R_min_time*x[end]
    Q.xx[end,end] = R_min_time

    return nothing
end

function cost_expansion!(S::Expansion{T}, cost::MinTimeCost, xN::Vector{T}) where T
    n, = get_sizes(cost.cost)
    R_min_time = cost.R_min_time

    idx = 1:n
    S.xx[idx,idx] = cost.cost.Q
    S.x[idx] = cost.cost.Q*xN[idx] + cost.cost.q
    S.xx[end,end] = R_min_time
    S.x[end] = R_min_time*xN[end]

    return nothing
end
