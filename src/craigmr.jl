# An implementation of CRAIG-MR for the solution of the
# (under/over-determined or square) linear system
#
#  Ax = b.
#
# The method seeks to solve the minimum-norm problem
#
#  min ‖x‖²  s.t. Ax = b,
#
# and is equivalent to applying the conjugate residual method
# to the linear system
#
#  AAᵀy = b.
#
# This method is equivalent to CRMR, and is described in
#
# M. Arioli and D. Orban, Iterative Methods for Symmetric
# Quasi-Definite Linear Systems, Part I: Theory.
# Cahier du GERAD G-2013-32, GERAD, Montreal QC, Canada, 2013.
#
# D. Orban, The Projected Golub-Kahan Process for Constrained
# Linear Least-Squares Problems. Cahier du GERAD G-2014-15,
# GERAD, Montreal QC, Canada, 2014.
#
# Dominique Orban, <dominique.orban@gerad.ca>
# Montreal, QC, May 2015.

export craigmr


"""Solve the consistent linear system

  Ax + √λs = b

using the CRAIG-MR method, where λ ≥ 0 is a regularization parameter.
This method is equivalent to applying the Conjugate Residuals method
to the normal equations of the second kind

  (AAᵀ + λI) y = b

but is more stable. When λ = 0, this method solves the minimum-norm problem

  min ‖x‖₂  s.t.  x ∈ argmin ‖Ax - b‖₂.

When λ > 0, this method solves the problem

  min ‖(x,s)‖₂  s.t. Ax + √λs = b.

Preconditioners M⁻¹ and N⁻¹ may be provided in the form of linear operators and are
assumed to be symmetric and positive definite.
Afterward CRAIGMR solves the symmetric and quasi-definite system

  [ -N   Aᵀ ] [ x ]   [ 0 ]
  [  A   M  ] [ y ] = [ b ],

which is equivalent to applying MINRES to (M + AN⁻¹Aᵀ)y = b.

CRAIGMR produces monotonic residuals ‖r‖₂.
It is formally equivalent to CRMR, though can be slightly more accurate,
and intricate to implement. Both the x- and y-parts of the solution are
returned.
"""
function craigmr(A :: AbstractLinearOperator, b :: AbstractVector{T};
                 M :: AbstractLinearOperator=opEye(),
                 N :: AbstractLinearOperator=opEye(),
                 λ :: Float64=0.0, atol :: Float64=1.0e-8, rtol :: Float64=1.0e-6,
                 itmax :: Int=0, verbose :: Bool=false) where T <: Number

  m, n = size(A);
  size(b, 1) == m || error("Inconsistent problem size");
  verbose && @printf("CRAIG-MR: system of %d equations in %d variables\n", m, n);

  # Tests M == Iₘ and N == Iₙ
  MisI = isa(M, opEye)
  NisI = isa(N, opEye)

  # Compute y such that AAᵀy = b. Then recover x = Aᵀy.
  x = zeros(T, n)
  y = zeros(T, m)
  Mu = copy(b)
  u = M * Mu
  β = sqrt(@kdot(m, u, Mu))
  β == 0.0 && return (x, y, SimpleStats(true, false, [0.0], T[], "x = 0 is a zero-residual solution"));

  # Initialize Golub-Kahan process.
  # β₁Mu₁ = b.
  @kscal!(m, 1.0/β, u)
  MisI || @kscal!(m, 1.0/β, Mu)
  # α₁Nv₁ = Aᵀu₁.
  Aᵀu = A.tprod(u)
  Nv = copy(Aᵀu)
  v = N * Nv
  α = sqrt(@kdot(n, v, Nv))
  Anorm² = α * α;

  verbose && @printf("%5s  %7s  %7s  %7s  %7s  %8s  %8s  %7s\n",
                     "Aprod", "‖r‖", "‖Aᵀr‖", "β", "α", "cos", "sin", "‖A‖²");
  verbose && @printf("%5d  %7.1e  %7.1e  %7.1e  %7.1e  %8.1e  %8.1e  %7.1e\n",
                     1, β, α, β, α, 0, 1, Anorm²);

  # Aᵀb = 0 so x = 0 is a minimum least-squares solution
  α == 0.0 && return (x, y, SimpleStats(true, false, [β], [0.0], "x = 0 is a minimum least-squares solution"));
  @kscal!(n, 1.0/α, v)
  NisI || @kscal!(n, 1.0/α, Nv)

  # Initialize other constants.
  ζbar = β;
  ρbar = α;
  θ = 0.0;
  rNorm = ζbar;
  rNorms = [rNorm];
  ArNorm = α;
  ArNorms = [ArNorm];

  ɛ_c = atol + rtol * rNorm;   # Stopping tolerance for consistent systems.
  ɛ_i = atol + rtol * ArNorm;  # Stopping tolerance for inconsistent systems.

  iter = 0;
  itmax == 0 && (itmax = m + n);

  wbar = copy(u)
  @kscal!(m, 1.0/α, wbar)
  w = zeros(T, m);

  status = "unknown";
  solved = rNorm <= ɛ_c
  inconsistent = (rNorm > 1.0e+2 * ɛ_c) & (ArNorm <= ɛ_i)
  tired  = iter >= itmax

  while ! (solved || inconsistent || tired)
    iter = iter + 1;

    # Generate next Golub-Kahan vectors.
    # 1. βₖ₊₁Muₖ₊₁ = Avₖ - αₖMuₖ
    Av = A * v
    @kaxpby!(m, 1.0, Av, -α, Mu)
    u = M * Mu
    β = sqrt(@kdot(m, u, Mu))
    if β ≠ 0.0
      @kscal!(m, 1.0/β, u)
      MisI || @kscal!(m, 1.0/β, Mu)
    end

    Anorm² = Anorm² + β * β;  # = ‖B_{k-1}‖²

    # Continue QR factorization
    #
    # Q [ Lₖ  β₁ e₁ ] = [ Rₖ   zₖ  ] :
    #   [ β    0    ]   [ 0   ζbar ]
    #
    #       k  k+1    k    k+1      k  k+1
    # k   [ c   s ] [ ρbar    ] = [ ρ  θ⁺    ]
    # k+1 [ s  -c ] [ β    α⁺ ]   [    ρbar⁺ ]
    #
    # so that we obtain
    #
    # [ c  s ] [ ζbar ] = [ ζ     ]
    # [ s -c ] [  0   ]   [ ζbar⁺ ]
    (c, s, ρ) = sym_givens(ρbar, β);
    ζ = c * ζbar;
    ζbar = s * ζbar;
    rNorm = abs(ζbar);
    push!(rNorms, rNorm);

    @kaxpby!(m, 1.0/ρ, wbar, -θ/ρ, w)  # w = (wbar - θ * w) / ρ;
    @kaxpy!(m, ζ, w, y)             # y = y + ζ * w;

    # 2. αₖ₊₁Nvₖ₊₁ = Aᵀuₖ₊₁ - βₖ₊₁Nvₖ
    Aᵀu = A.tprod(u)
    @kaxpby!(n, 1.0, Aᵀu, -β, Nv)
    v = N * Nv
    α = sqrt(@kdot(n, v, Nv))
    Anorm² = Anorm² + α * α;  # = ‖Lₖ‖
    ArNorm = α * β * abs(ζ/ρ);
    push!(ArNorms, ArNorm);

    verbose && @printf("%5d  %7.1e  %7.1e  %7.1e  %7.1e  %8.1e  %8.1e  %7.1e\n",
                       1 + 2 * iter, rNorm, ArNorm, β, α, c, s, Anorm²);

    if α ≠ 0.0
      @kscal!(n, 1.0/α, v)
      NisI || @kscal!(n, 1.0/α, Nv)
      @kaxpby!(m, 1.0/α, u, -β/α, wbar)  # wbar = (u - beta * wbar) / alpha;
    end
    θ = s * α;
    ρbar = -c * α;

    solved = rNorm <= ɛ_c
    inconsistent = (rNorm > 1.0e+2 * ɛ_c) & (ArNorm <= ɛ_i)
    tired  = iter >= itmax
  end

  Aᵀy = A.tprod(y)
  N⁻¹Aᵀy = N * Aᵀy
  @. x = N⁻¹Aᵀy

  status = tired ? "maximum number of iterations exceeded" : (solved ? "found approximate minimum-norm solution" : "found approximate minimum least-squares solution")
  stats = SimpleStats(solved, inconsistent, rNorms, ArNorms, status);
  return (x, y, stats)
end
