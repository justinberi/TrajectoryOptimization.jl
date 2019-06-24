"Simulate state trajectory with feedback control"
function rollout!(prob::Problem{T,Discrete},solver::iLQRSolver{T},alpha::T=1.0) where T
    X = prob.X; U = prob.U
    K = solver.K; d = solver.d; X̄ = solver.X̄; Ū = solver.Ū

    initial_condition!(prob,solver,alpha)

    for k = 2:prob.N
        # Calculate state trajectory difference
        δx = state_diff(prob,solver,k-1)

        # Calculate updated control
        Ū[k-1] = U[k-1] + K[k-1]*δx + alpha*d[k-1]

        # Propagate dynamics
        try
            evaluate!(X̄[k], prob.model, X̄[k-1], Ū[k-1], prob.dt)
        catch
            return false
        end

        # Check that rollout has not diverged
        if ~(norm(X̄[k],Inf) < solver.opts.max_state_value && norm(Ū[k-1],Inf) < solver.opts.max_control_value)
            return false
        end
    end
    return true
end

function rollout!(prob::Problem{T,Discrete}) where T
    N = prob.N
    if !all(isfinite.(prob.X[1]))
        initial_condition!(prob)
        rollout!(prob.X, prob.model, prob.U, prob.dt)
    end
end

function rollout!(X::AbstractVectorTrajectory, model::Model{M,Discrete}, U::AbstractVectorTrajectory, dt) where {M,T}
    N = length(X)
    for k = 1:N-1
        evaluate!(X[k+1], model, X[k], U[k], dt)
    end
end

function rollout(model::Model{M,Discrete}, x0::Vector, U::AbstractVectorTrajectory, dt) where M
    n = model.n
    N = length(U)+1
    X = [zero(x0) for k = 1:N]
    X[1] = x0
    rollout!(X, model, U, dt)
    return X
end
rollout(prob::Problem{T,Discrete}) where T = rollout(prob.model, prob.x0, prob.U, prob.dt)

function initial_condition!(prob::Problem{T},X::Vector{T}=prob.X[1]) where T
    n = prob.model.n
    X[1:n] = copy(prob.x0)
end

function initial_condition!(prob::Problem{T},solver::iLQRSolver{T},alpha::T=1.0) where T
    m = prob.model.m; n = prob.model.n

    initial_condition!(prob,solver.X̄[1])

    # Modified initial state
    m̄ = length(prob.U[1])
    if m̄ != m
        m_dif = m̄ - m
        n̄ = n - m_dif

        δx = state_diff(prob,solver,1)
        solver.X̄[1][n̄ .+ (1:m_dif)] = (prob.U[1] + solver.K[1]*δx + alpha*solver.d[1])[m .+ (1:m_dif)]
    end
end

function state_diff(prob::Problem{T,Discrete},solver::iLQRSolver{T},k::Int) where T
    if true
        return solver.X̄[k] - prob.X[k]
    else
        nothing #TODO quaternion
    end
end

function rollout_reverse!(prob::Problem{T,Discrete},xf::AbstractVector{T}) where T
    N = prob.N
    f = prob.model.f
    dt = prob.dt

    X = prob.X; U = prob.U

    X[N] = copy(xf)

    for k = N-1:-1:1
        f(X[k],X[k+1],U[k],-dt)
    end
end
