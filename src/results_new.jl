struct BackwardPassNew{T<:AbstractFloat}
    Qx::VectorTrajectory{T}
    Qu::VectorTrajectory{T}
    Qxx::MatrixTrajectory{T}
    Qux::MatrixTrajectory{T}
    Quu::MatrixTrajectory{T}
    Qux_reg::MatrixTrajectory{T}
    Quu_reg::MatrixTrajectory{T}
end

function BackwardPassNew(p::Problem{T}) where T
    n = p.model.n; m = p.model.m; N = p.N

    Qx = [zeros(T,n) for i = 1:N-1]
    Qu = [zeros(T,m) for i = 1:N-1]
    Qxx = [zeros(T,n,n) for i = 1:N-1]
    Qux = [zeros(T,m,n) for i = 1:N-1]
    Quu = [zeros(T,m,m) for i = 1:N-1]

    Qux_reg = [zeros(T,m,n) for i = 1:N-1]
    Quu_reg = [zeros(T,m,m) for i = 1:N-1]

    BackwardPassNew{T}(Qx,Qu,Qxx,Qux,Quu,Qux_reg,Quu_reg)
end

function copy(bp::BackwardPassNew{T}) where T
    BackwardPassNew{T}(deepcopy(bp.Qx),deepcopy(bp.Qu),deepcopy(bp.Qxx),deepcopy(bp.Qux),deepcopy(bp.Quu),deepcopy(bp.Qux_reg),deepcopy(bp.Quu_reg))
end

function reset!(bp::BackwardPassNew)
    N = length(bp.Qx)
    for k = 1:N-1
        bp.Qx[k] = zero(bp.Qx[k]); bp.Qu[k] = zero(bp.Qu[k]); bp.Qxx[k] = zero(bp.Qxx[k]); bp.Quu[k] = zero(bp.Quu[k]); bp.Qux[k] = zero(bp.Qux[k])
        bp.Quu_reg[k] = zero(bp.Quu_reg[k]); bp.Qux_reg[k] = zero(bp.Qux_reg[k])
    end
end

abstract type Results{T<:AbstractFloat} end

"$(TYPEDEF) Iterative LQR results"
struct iLQRResults{T} <: Results{T}
    X̄::VectorTrajectory{T} # states (n,N)
    Ū::VectorTrajectory{T} # controls (m,N-1)

    K::MatrixTrajectory{T}  # State feedback gains (m,n,N-1)
    d::VectorTrajectory{T}  # Feedforward gains (m,N-1)

    S::MatrixTrajectory{T}  # Cost-to-go Hessian (n,n,N)
    s::VectorTrajectory{T}  # Cost-to-go gradient (n,N)

    ∇F::PartedMatTrajectory{T} # discrete dynamics jacobian (block) (n,n+m+1,N)

    ρ::Vector{T} # Regularization
    dρ::Vector{T} # Regularization rate of change

    bp::BackwardPassNew{T}
end

function iLQRResults(p::Problem{T}) where T
    n = p.model.n; m = p.model.m; N = p.N

    X̄  = [zeros(T,n)   for i = 1:N]
    Ū  = [zeros(T,m)   for i = 1:N-1]

    K  = [zeros(T,m,n) for i = 1:N-1]
    d  = [zeros(T,m)   for i = 1:N-1]

    S  = [zeros(T,n,n) for i = 1:N]
    s  = [zeros(T,n)   for i = 1:N]

    ∇F = [zeros(T,n,n+m+1) for i = 1:N-1]

    ρ = zeros(T,1)
    dρ = zeros(T,1)

    bp = BackwardPassNew(p)

    iLQRResults{T}(X̄,Ū,K,d,S,s,∇F,ρ,dρ,bp)
end

function copy(r::iLQRResults{T}) where T
    iLQRResults{T}(copy(r.X̄),copy(r.Ū),copy(r.K),copy(r.d),copy(r.S),copy(r.s),copy(r.∇F),copy(r.ρ),copy(r.dρ),copy(r.bp))
end

"$(TYPEDEF) Augmented Lagrangian results"
struct ALResults{T} <: Results{T}
    C::PartedVecTrajectory{T}      # Constraint values [(p,N-1) (p_N)]
    C_prev::PartedVecTrajectory{T} # Previous constraint values [(p,N-1) (p_N)]
    ∇C::PartedMatTrajectory{T}   # Constraint jacobians [(p,n+m,N-1) (p_N,n)]
    λ::PartedVecTrajectory{T}      # Lagrange multipliers [(p,N-1) (p_N)]
    Iμ::DiagonalTrajectory{T}     # Penalty matrix [(p,p,N-1) (p_N,p_N)]
    active_set::PartedVecTrajectory{Bool} # active set [(p,N-1) (p_N)]
end

function ALResults(prob::Problem{T}) where T
    n = prob.model.n; m = prob.model.m; N = prob.N
    p = num_stage_constraints(prob.constraints)
    p_N = num_terminal_constraints(prob.constraints)

    c_stage = stage(prob.constraints)
    c_term = terminal(prob.constraints)
    c_part = create_partition(c_stage)
    c_part2 = create_partition2(c_stage,n,m)

    C = [BlockArray(zeros(T,p),c_part) for k = 1:N-1]
    C_prev = [BlockArray(zeros(T,p),c_part) for k = 1:N-1]
    ∇C = [BlockArray(zeros(T,p,n+m),c_part2) for k = 1:N-1]
    λ = [BlockArray(zeros(T,p),c_part) for k = 1:N-1]
    Iμ = [i != N ? Diagonal(ones(T,p)) : Diagonal(ones(T,p_N)) for i = 1:N]
    active_set = [BlockArray(ones(Bool,p),c_part) for k = 1:N-1]
    push!(C,BlockVector(T,c_term))
    push!(C_prev,BlockVector(T,c_term))
    push!(∇C,BlockMatrix(T,c_term,n,m))
    push!(λ,BlockVector(T,c_term))
    push!(active_set,BlockVector(Bool,c_term))

    ALResults{T}(C,C_prev,∇C,λ,Iμ,active_set)
end

function copy(r::ALResults{T}) where T
    ALResults{T}(deepcopy(r.C),deepcopy(r.C_prev),deepcopy(r.∇C),deepcopy(r.λ),deepcopy(r.Iμ),deepcopy(r.active_set))
end