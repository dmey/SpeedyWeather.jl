"""
    timestep!()

Time step of a 2D field `input` (a `Lon x Lat x 2` array)

Perform one time step starting from F(1) and F(2) and using the following scheme:
Fnew = F(1) + DT * [ T_dyn(F(J2)) + T_phy(F(1)) ]
F(1) = (1-2*eps)*F(J1) + eps*[F(1)+Fnew]
F(2) = Fnew
Input:
If j1 == 1, j2 == 1 : forward time step (eps = 0)
If j1 == 1, j2 == 2 : initial leapfrog time step (eps = 0)
If j1 == 2, j2 == 2 : leapfrog time step with time filter (eps = ROB)
dt = time step

"""
function timestep!( A::AbstractArray{NF,3},             # a prognostic variable
                    tendency::AbstractArray{NF,2},      # its tendency
                    l1::Int,                            # leapfrog index for time filtering
                    G::GeoSpectral{NF},                 # struct with precomputed arrays for spectral transform
                    C::Constants{NF}                    # struct with constants used at runtime
                    ) where {NF<:AbstractFloat}

    nlon,nlat,nleapfrog = size(input)     # longitude, latitude, 2 leapfrog steps

    @boundscheck (nlon,nlat) == size(tendency) || throw(BoundsError())
    @boundscheck nleapfrog == 2 || throw(BoundsError())     # last dim is 2 for leapfrog
    @boundscheck l1 in [1,2] || throw(BoundsError())        # index l1 is calls leapfrog dim
    
    # get coefficients for the Robert and Williams' filter for 3rd order accuracy in time stepping
    @unpack robert_filter, williams_filter, Δt = C
    eps = l1 == 1 ? zero(NF) : robert_filter
    two = convert(NF,2)
    eps = one(NF) - two*eps

    # truncate the tendency to the spectral resolution
    # TODO this allocates memory, avoid?
    tendency = spectral_truncation(tendency,G)

    # LEAP FROG time step
    # TODO preallocate Anew
    Anew = A[:,:,1] + Δt*tendency

    # ROBERT TIME FILTER TO COMPRESS COMPUTATIONAL MODE
    # WILLIAMS' FILTER FOR 3RD ORDER ACCURACY
    williams_filter_eps = williams_filter*eps
    one_minus_williams_filter_eps = (one(NF) - williams_filter)*eps
    @inbounds for j in 1:nlat
        for i in 1:nlon
            # Robert's filter
            A[i,j,1] = A[i,j,l1] + williams_filter_eps*(A[i,j,1] - two*A[i,j,l1] + Anew[i,j])

            # Williams' filter
            A[i,j,2] = Anew[i,j] - one_minus_williams_filter_eps*(A[i,j,1] - two*A[i,j,l1] + Anew[i,j])
        end
    end
end

"""3D version that loops over all vertical layers."""
function timestep!( A::AbstractArray{NF,4},             # a prognostic variable
                    tendency::AbstractArray{NF,3},      # its tendency
                    j1::Int,                            # index for time filtering
                    C::Constants{NF}                    # struct containing all constants used at runtime
                    ) where {NF<:AbstractFloat}

    _,_,nlev,_ = size(A)        # A is of size nlon x nlat x nlev x 2

    for k in 1:nlev
        # extract vertical layers as views to not allocate any memory
        A_layer = view(A,:,:,k,:)
        tendency_layer = view(tendency,:,:,k)
        
        # make a timestep forward for each layer
        timestep!(A_layer,tendency_layer,j1,C)
    end
end

# Call initialization of semi-implicit scheme and perform initial time step
function first_step()
    initialize_implicit(half*Δt)

    step(1, 1, half*Δt)

    initialize_implicit(Δt)

    step(1, 2, Δt)

    initialize_implicit(2*Δt)
end


function step(j1, j2, Δt)
    vorU_tend = zeros(Complex{RealType}, mx, nx, nlev)
    divU_tend = zeros(Complex{RealType}, mx, nx, nlev)
    tem_tend  = zeros(Complex{RealType}, mx, nx, nlev)
    pₛ_tend   = zeros(Complex{RealType}, mx, nx)
    tr_tend   = zeros(Complex{RealType}, mx, nx, nlev, n_trace)
    ctmp      = zeros(Complex{RealType}, mx, nx, nlev)

    # =========================================================================
    # Compute tendencies of prognostic variables
    # =========================================================================

    get_tendencies!(vorU_tend, divU_tend, tem_tend, pₛ_tend, tr_tend, j2)

    # =========================================================================
    # Horizontal diffusion
    # =========================================================================

    # Diffusion of wind and temperature
    do_horizontal_diffusion_3d!(vorU[:,:,:,1], vorU_tend, dmp,  dmp1)
    do_horizontal_diffusion_3d!(divU[:,:,:,1], divU_tend, dmpd, dmp1d)

    for k in 1:nlev
        for m in 1:mx
            for n in 1:nx
                ctmp[m,n,k] = tem[m,n,k,1] + tcorh[m,n]*tcorv[k]
            end
        end
    end

    do_horizontal_diffusion_3d!(ctmp, tem_tend, dmp, dmp1)

    # Stratospheric diffusion and zonal wind damping
    sdrag = one/(tdrs*RealType(3600.0))
    for n in 1:nx
        vorU_tend[1,n,1] = vorU_tend[1,n,1] - sdrag*vorU[1,n,1,1]
        divU_tend[1,n,1] = divU_tend[1,n,1] - sdrag*divU[1,n,1,1]
    end

    do_horizontal_diffusion_3d!(vorU[:,:,:,1],  vorU_tend, dmps, dmp1s)
    do_horizontal_diffusion_3d!(divU[:,:,:,1],  divU_tend, dmps, dmp1s)
    do_horizontal_diffusion_3d!(ctmp, tem_tend,   dmps, dmp1s)

    # Diffusion of tracers
    for k in 1:nlev
        for m in 1:mx
            for n in 1:nx
                ctmp[m,n,k] = tr[m,n,k,1,1] + qcorh[m,n]*qcorv[k]
            end
        end
    end

    do_horizontal_diffusion_3d!(ctmp, @view(tr_tend[:,:,:,1]), dmpd, dmp1d)

    if ntracers > 1
        for i in 2:ntracers
            do_horizontal_diffusion_3d!(tr[:,:,:,1,itr], @view(tr_tend[:,:,:,itr]), dmp, dmp1)
        end
    end

    # =========================================================================
    # Time integration with Robert filter
    # =========================================================================

    if j1 == 1
        eps = zero
    else
        eps = rob
    end

    step_field_2d!(j1, Δt, eps, pₛ, pₛ_tend)
    step_field_3d!(j1, Δt, eps, vorU, vorU_tend)
    step_field_3d!(j1, Δt, eps, divU, divU_tend)
    step_field_3d!(j1, Δt, eps, tem, tem_tend)

    for itr in 1:n_trace
        step_field_3d!(j1, Δt, eps, @view(tr[:,:,:,:,itr]), tr_tend[:,:,:,itr])
    end
end