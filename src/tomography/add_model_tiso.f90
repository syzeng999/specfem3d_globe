!=====================================================================
!
!          S p e c f e m 3 D  G l o b e  V e r s i o n  6 . 0
!          --------------------------------------------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                        Princeton University, USA
!                and CNRS / University of Marseille, France
!                 (there are currently many more authors!)
! (c) Princeton University and CNRS / University of Marseille, April 2014
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================

! add_model_globe_tiso
!
! this program can be used to update TRANSVERSE ISOTROPIC model files
! based on smoothed event kernels.
! the kernels are given for tranverse isotropic parameters (bulk_c,bulk_betav,bulk_betah,eta).
!
! the algorithm uses a steepest descent method with a step length
! determined by the given maximum update percentage.
!
! input:
!    - step_fac : step length to update the models, f.e. 0.03 for plusminus 3%
!
! setup:
!
!- INPUT_MODEL/  contains:
!       proc000***_reg1_vsv.bin &
!       proc000***_reg1_vsh.bin &
!       proc000***_reg1_vpv.bin &
!       proc000***_reg1_vph.bin &
!       proc000***_reg1_eta.bin &
!       proc000***_reg1_rho.bin
!
!- INPUT_GRADIENT/ contains:
!       proc000***_reg1_bulk_c_kernel_smooth.bin &
!       proc000***_reg1_bulk_betav_kernel_smooth.bin &
!       proc000***_reg1_bulk_betah_kernel_smooth.bin &
!       proc000***_reg1_eta_kernel_smooth.bin
!
!- topo/ contains:
!       proc000***_reg1_solver_data_1.bin
!
! new models are stored in
!- OUTPUT_MODEL/ as
!   proc000***_reg1_vpv_new.bin &
!   proc000***_reg1_vph_new.bin &
!   proc000***_reg1_vsv_new.bin &
!   proc000***_reg1_vsh_new.bin &
!   proc000***_reg1_eta_new.bin &
!   proc000***_reg1_rho_new.bin
!
! USAGE: ./add_model_globe_tiso 0.3

module model_update_tiso

  use constants,only: CUSTOM_REAL,NGLLX,NGLLY,NGLLZ,NX_BATHY,NY_BATHY,IIN,IOUT, &
    FOUR_THIRDS,R_EARTH_KM,GAUSSALPHA,GAUSSBETA

  implicit none

  include 'OUTPUT_FILES/values_from_mesher.h'

  ! ======================================================

  ! density scaling factor with shear perturbations
  ! see e.g. Montagner & Anderson (1989), Panning & Romanowicz (2006)
  real(kind=CUSTOM_REAL),parameter :: RHO_SCALING = 0.33_CUSTOM_REAL

  ! constraint on eta model
  real(kind=CUSTOM_REAL),parameter :: LIMIT_ETA_MIN = 0.5_CUSTOM_REAL
  real(kind=CUSTOM_REAL),parameter :: LIMIT_ETA_MAX = 1.5_CUSTOM_REAL

  ! ======================================================

  integer, parameter :: NSPEC = NSPEC_CRUST_MANTLE
  integer, parameter :: NGLOB = NGLOB_CRUST_MANTLE

  ! transverse isotropic model files
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: &
        model_vpv,model_vph,model_vsv,model_vsh,model_eta,model_rho
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: &
        model_vpv_new,model_vph_new,model_vsv_new,model_vsh_new,model_eta_new,model_rho_new

  ! model updates
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: &
        model_dbulk,model_dbetah,model_dbetav,model_deta

  ! kernels
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: &
        kernel_bulk,kernel_betav,kernel_betah,kernel_eta

  ! volume
  real(kind=CUSTOM_REAL), dimension(NGLOB) :: x, y, z

  integer, dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: ibool
  integer, dimension(NSPEC) :: idoubling
  logical, dimension(NSPEC) :: ispec_is_tiso

  ! gradient vector norm ( v^T * v )
  real(kind=CUSTOM_REAL) :: norm_bulk,norm_betav,norm_betah,norm_eta
  real(kind=CUSTOM_REAL) :: norm_bulk_sum,norm_betav_sum, &
    norm_betah_sum,norm_eta_sum

  ! model update length
  real(kind=CUSTOM_REAL) :: step_fac,step_length

  real(kind=CUSTOM_REAL) :: min_vpv,min_vph,min_vsv,min_vsh, &
    max_vpv,max_vph,max_vsv,max_vsh,min_eta,max_eta,min_bulk,max_bulk, &
    min_rho,max_rho,minmax(4)

  real(kind=CUSTOM_REAL) :: betav1,betah1,betav0,betah0,rho1,rho0, &
    betaiso1,betaiso0,eta1,eta0,alphav1,alphav0,alphah1,alphah0
  real(kind=CUSTOM_REAL) :: dbetaiso,dbulk

  integer :: nfile, myrank, sizeprocs,  ier
  integer :: i, j, k,ispec, iglob, ishell, n, it, j1, ib, npts_sem, ios
  character(len=150) :: sline, m_file, fname


end module model_update_tiso

!
!-------------------------------------------------------------------------------------------------
!

program add_model

  use model_update_tiso

  implicit none

  ! ============ program starts here =====================

  ! initializes arrays
  call initialize()

  ! reads in parameters needed
  call read_parameters()

  ! reads in current transverse isotropic model files: vpv.. & vsv.. & eta & rho
  call read_model()

  ! reads in smoothed kernels: bulk, betav, betah, eta
  call read_kernels()

  ! calculates gradient
  ! steepest descent method
  call get_gradient()

  ! compute new model in terms of alpha, beta, eta and rho
  ! (see also Carl's Latex notes)

  ! model update:
  !   transverse isotropic update only in layer Moho to 220 (where SPECFEM3D_GLOBE considers TISO)
  !   everywhere else uses an isotropic update
  do ispec = 1, NSPEC
    do k = 1, NGLLZ
      do j = 1, NGLLY
        do i = 1, NGLLX

          ! initial model values
          eta0 = model_eta(i,j,k,ispec)
          betav0 = model_vsv(i,j,k,ispec)
          betah0 = model_vsh(i,j,k,ispec)
          rho0 = model_rho(i,j,k,ispec)
          alphav0 = model_vpv(i,j,k,ispec)
          alphah0 = model_vph(i,j,k,ispec)

          eta1 = 0._CUSTOM_REAL
          betav1 = 0._CUSTOM_REAL
          betah1 = 0._CUSTOM_REAL
          rho1 = 0._CUSTOM_REAL
          alphav1 = 0._CUSTOM_REAL
          alphah1 = 0._CUSTOM_REAL

          ! do not use transverse isotropy except if element is between d220 and Moho
!          if (.not. ( idoubling(ispec)==IFLAG_220_80 .or. idoubling(ispec)==IFLAG_80_MOHO) ) then
          if (.not. ispec_is_tiso(ispec)) then
            ! isotropic model update

            ! no eta perturbation, since eta = 1 in isotropic media
            eta1 = eta0

            ! shear values
            ! isotropic kernel K_beta = K_betav + K_betah
            ! with same scaling step_length the model update dbeta_iso = dbetav + dbetah
            ! note:
            !   this step length can be twice as big as that given by the input
            dbetaiso = model_dbetav(i,j,k,ispec) + model_dbetah(i,j,k,ispec)
            betav1 = betav0 * exp( dbetaiso )
            betah1 = betah0 * exp( dbetaiso )
            ! note: betah is probably not really used in isotropic layers
            !         (see SPECFEM3D_GLOBE/get_model.f90)

            ! density: uses scaling relation with isotropic shear perturbations
            !               dln rho = RHO_SCALING * dln betaiso
            rho1 = rho0 * exp( RHO_SCALING * dbetaiso )

            ! alpha values
            dbulk = model_dbulk(i,j,k,ispec)
            alphav1 = sqrt( alphav0**2 * exp(2.0*dbulk) + FOUR_THIRDS * betav0**2 * ( &
                                exp(2.0*dbetaiso) - exp(2.0*dbulk) ) )
            alphah1 = sqrt( alphah0**2 * exp(2.0*dbulk) + FOUR_THIRDS * betah0**2 * ( &
                                exp(2.0*dbetaiso) - exp(2.0*dbulk) ) )
            ! note: alphah probably not used in SPECFEM3D_GLOBE

          else

            ! transverse isotropic model update

            ! eta value : limits updated values for eta range constraint
            eta1 = eta0 * exp( model_deta(i,j,k,ispec) )
            if (eta1 < LIMIT_ETA_MIN ) eta1 = LIMIT_ETA_MIN
            if (eta1 > LIMIT_ETA_MAX ) eta1 = LIMIT_ETA_MAX

            ! shear values
            betav1 = betav0 * exp( model_dbetav(i,j,k,ispec) )
            betah1 = betah0 * exp( model_dbetah(i,j,k,ispec) )

            ! density: uses scaling relation with Voigt average of shear perturbations
            betaiso0 = sqrt(  ( 2.0 * betav0**2 + betah0**2 ) / 3.0 )
            betaiso1 = sqrt(  ( 2.0 * betav1**2 + betah1**2 ) / 3.0 )
            dbetaiso = log( betaiso1 / betaiso0 )
            rho1 = rho0 * exp( RHO_SCALING * dbetaiso )

            ! alpha values
            dbulk = model_dbulk(i,j,k,ispec)
            alphav1 = sqrt( alphav0**2 * exp(2.0*dbulk) &
                            + FOUR_THIRDS * betav0**2 * ( &
                                exp(2.0*model_dbetav(i,j,k,ispec)) - exp(2.0*dbulk) ) )
            alphah1 = sqrt( alphah0**2 * exp(2.0*dbulk) &
                            + FOUR_THIRDS * betah0**2 * ( &
                                exp(2.0*model_dbetah(i,j,k,ispec)) - exp(2.0*dbulk) ) )

          endif


          ! stores new model values
          model_vpv_new(i,j,k,ispec) = alphav1
          model_vph_new(i,j,k,ispec) = alphah1
          model_vsv_new(i,j,k,ispec) = betav1
          model_vsh_new(i,j,k,ispec) = betah1
          model_eta_new(i,j,k,ispec) = eta1
          model_rho_new(i,j,k,ispec) = rho1

        enddo
      enddo
    enddo
  enddo

  ! stores new model in files
  call store_new_model()

  ! stores relative model perturbations
  call store_perturbations()

  ! computes volume element associated with points, calculates kernel integral for statistics
  call compute_volume()

  ! stop all the MPI processes, and exit
  call finalize_mpi()

end program add_model

!
!-------------------------------------------------------------------------------------------------
!

subroutine initialize()

! initializes arrays

  use model_update_tiso
  implicit none

  ! initialize the MPI communicator and start the NPROCTOT MPI processes
  call init_mpi()
  call world_size(sizeprocs)
  call world_rank(myrank)

  if (sizeprocs /= nchunks_val*nproc_xi_val*nproc_eta_val ) then
    print*,'sizeprocs:',sizeprocs,nchunks_val,nproc_xi_val,nproc_eta_val
    call exit_mpi(myrank,'Error number sizeprocs')
  endif

  ! model
  model_vpv = 0.0_CUSTOM_REAL
  model_vph = 0.0_CUSTOM_REAL
  model_vsv = 0.0_CUSTOM_REAL
  model_vsh = 0.0_CUSTOM_REAL
  model_eta = 0.0_CUSTOM_REAL
  model_rho = 0.0_CUSTOM_REAL

  model_vpv_new = 0.0_CUSTOM_REAL
  model_vph_new = 0.0_CUSTOM_REAL
  model_vsv_new = 0.0_CUSTOM_REAL
  model_vsh_new = 0.0_CUSTOM_REAL
  model_eta_new = 0.0_CUSTOM_REAL
  model_rho_new = 0.0_CUSTOM_REAL

  ! model updates
  model_dbulk = 0.0_CUSTOM_REAL
  model_dbetah = 0.0_CUSTOM_REAL
  model_dbetav = 0.0_CUSTOM_REAL
  model_deta = 0.0_CUSTOM_REAL

  ! gradients
  kernel_bulk = 0.0_CUSTOM_REAL
  kernel_betav = 0.0_CUSTOM_REAL
  kernel_betah = 0.0_CUSTOM_REAL
  kernel_eta = 0.0_CUSTOM_REAL

end subroutine initialize

!
!-------------------------------------------------------------------------------------------------
!

subroutine read_parameters()

! reads in parameters needed

  use model_update_tiso
  implicit none
  character(len=150) :: s_step_fac

  ! subjective step length to multiply to the gradient
  !step_fac = 0.03

  call getarg(1,s_step_fac)

  if (trim(s_step_fac) == '') then
    call exit_MPI(myrank,'Usage: add_model_globe_tiso step_factor')
  endif

  ! read in parameter information
  read(s_step_fac,*) step_fac
  !if (abs(step_fac) < 1.e-10) then
  !  print*,'Error: step factor ',step_fac
  !  call exit_MPI(myrank,'Error step factor')
  !endif

  if (myrank == 0) then
    print*,'defaults'
    print*,'  NPROC_XI , NPROC_ETA: ',nproc_xi_val,nproc_eta_val
    print*,'  NCHUNKS: ',nchunks_val
    print*
    print*,'model update for vsv,vsh,vpv,vph,eta,rho:'
    print*,'  step_fac = ',step_fac
    print*

  endif


end subroutine read_parameters

!
!-------------------------------------------------------------------------------------------------
!

subroutine read_model()

! reads in current transverse isotropic model: vpv.. & vsv.. & eta & rho

  use model_update_tiso

  implicit none

  integer :: ival

  ! vpv model
  write(m_file,'(a,i6.6,a)') 'INPUT_MODEL/proc',myrank,'_reg1_vpv.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) model_vpv(:,:,:,1:nspec)
  close(IIN)

  ! vph model
  write(m_file,'(a,i6.6,a)') 'INPUT_MODEL/proc',myrank,'_reg1_vph.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) model_vph(:,:,:,1:nspec)
  close(IIN)

  ! vsv model
  write(m_file,'(a,i6.6,a)') 'INPUT_MODEL/proc',myrank,'_reg1_vsv.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) model_vsv(:,:,:,1:nspec)
  close(IIN)

  ! vsh model
  write(m_file,'(a,i6.6,a)') 'INPUT_MODEL/proc',myrank,'_reg1_vsh.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) model_vsh(:,:,:,1:nspec)
  close(IIN)

  ! eta model
  write(m_file,'(a,i6.6,a)') 'INPUT_MODEL/proc',myrank,'_reg1_eta.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) model_eta(:,:,:,1:nspec)
  close(IIN)

  ! rho model
  write(m_file,'(a,i6.6,a)') 'INPUT_MODEL/proc',myrank,'_reg1_rho.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) model_rho(:,:,:,1:nspec)
  close(IIN)

  ! statistics
  call min_all_cr(minval(model_vpv),min_vpv)
  call max_all_cr(maxval(model_vpv),max_vpv)

  call min_all_cr(minval(model_vph),min_vph)
  call max_all_cr(maxval(model_vph),max_vph)

  call min_all_cr(minval(model_vsv),min_vsv)
  call max_all_cr(maxval(model_vsv),max_vsv)

  call min_all_cr(minval(model_vsh),min_vsh)
  call max_all_cr(maxval(model_vsh),max_vsh)

  call min_all_cr(minval(model_eta),min_eta)
  call max_all_cr(maxval(model_eta),max_eta)

  call min_all_cr(minval(model_rho),min_rho)
  call max_all_cr(maxval(model_rho),max_rho)

  if (myrank == 0) then
    print*,'initial models:'
    print*,'  vpv min/max: ',min_vpv,max_vpv
    print*,'  vph min/max: ',min_vph,max_vph
    print*,'  vsv min/max: ',min_vsv,max_vsv
    print*,'  vsh min/max: ',min_vsh,max_vsh
    print*,'  eta min/max: ',min_eta,max_eta
    print*,'  rho min/max: ',min_rho,max_rho
    print*
  endif

  ! global addressing
  write(m_file,'(a,i6.6,a)') 'topo/proc',myrank,'_reg1_solver_data.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif

  read(IIN) ival ! nspec
  if (ival /= nspec) call exit_mpi(myrank,'Error invalid nspec value in solver_data.bin')
  read(IIN) ival ! nglob
  if (ival /= nglob) call exit_mpi(myrank,'Error invalid nglob value in solver_data.bin')

  read(IIN) x(1:nglob)
  read(IIN) y(1:nglob)
  read(IIN) z(1:nglob)
  read(IIN) ibool(:,:,:,1:nspec)
  read(IIN) idoubling(1:nspec)
  read(IIN) ispec_is_tiso(1:nspec)
  close(IIN)

end subroutine read_model

!
!-------------------------------------------------------------------------------------------------
!

subroutine read_kernels()

! reads in smoothed kernels: bulk, betav, betah, eta

  use model_update_tiso
  implicit none

  ! bulk kernel
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_bulk_c_kernel_smooth.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) kernel_bulk(:,:,:,1:nspec)
  close(IIN)

  ! betav kernel
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_bulk_betav_kernel_smooth.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) kernel_betav(:,:,:,1:nspec)
  close(IIN)

  ! betah kernel
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_bulk_betah_kernel_smooth.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) kernel_betah(:,:,:,1:nspec)
  close(IIN)

  ! eta kernel
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_eta_kernel_smooth.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif
  read(IIN) kernel_eta(:,:,:,1:nspec)
  close(IIN)


  ! statistics
  call min_all_cr(minval(kernel_bulk),min_bulk)
  call max_all_cr(maxval(kernel_bulk),max_bulk)

  call min_all_cr(minval(kernel_betah),min_vsh)
  call max_all_cr(maxval(kernel_betah),max_vsh)

  call min_all_cr(minval(kernel_betav),min_vsv)
  call max_all_cr(maxval(kernel_betav),max_vsv)

  call min_all_cr(minval(kernel_eta),min_eta)
  call max_all_cr(maxval(kernel_eta),max_eta)

  if (myrank == 0) then
    print*,'initial kernels:'
    print*,'  bulk min/max : ',min_bulk,max_bulk
    print*,'  betav min/max: ',min_vsv,max_vsv
    print*,'  betah min/max: ',min_vsh,max_vsh
    print*,'  eta min/max  : ',min_eta,max_eta
    print*
  endif

end subroutine read_kernels


!
!-------------------------------------------------------------------------------------------------
!

subroutine get_gradient()

! calculates gradient by steepest descent method

  use model_update_tiso
  implicit none
  ! local parameters
  real(kind=CUSTOM_REAL):: r,max,depth_max

  ! ------------------------------------------------------------------------

  ! sets maximum update in this depth range
  logical,parameter :: use_depth_maximum = .true.
  ! normalized radii
  real(kind=CUSTOM_REAL),parameter :: R_top = (6371.0 - 50.0 ) / R_EARTH_KM ! shallow depth
  real(kind=CUSTOM_REAL),parameter :: R_bottom = (6371.0 - 100.0 ) / R_EARTH_KM ! deep depth

  ! ------------------------------------------------------------------------

  ! initializes kernel maximum
  max = 0._CUSTOM_REAL

  ! gradient in negative direction for steepest descent
  do ispec = 1, NSPEC
    do k = 1, NGLLZ
      do j = 1, NGLLY
        do i = 1, NGLLX

            ! for bulk
            model_dbulk(i,j,k,ispec) = - kernel_bulk(i,j,k,ispec)

            ! for shear
            model_dbetav(i,j,k,ispec) = - kernel_betav(i,j,k,ispec)
            model_dbetah(i,j,k,ispec) = - kernel_betah(i,j,k,ispec)

            ! for eta
            model_deta(i,j,k,ispec) = - kernel_eta(i,j,k,ispec)

            ! determines maximum kernel betav value within given radius
            if (use_depth_maximum) then
              ! get radius of point
              iglob = ibool(i,j,k,ispec)
              r = sqrt( x(iglob)*x(iglob) + y(iglob)*y(iglob) + z(iglob)*z(iglob) )

              ! stores maximum kernel betav value in this depth slice, since betav is most likely dominating
              if (r < R_top .and. r > R_bottom) then
                ! kernel betav value
                max_vsv = abs( kernel_betav(i,j,k,ispec) )
                if (max < max_vsv) then
                  max = max_vsv
                  depth_max = r
                endif
              endif
            endif

        enddo
      enddo
    enddo
  enddo

  ! stores model_dbulk, ... arrays
  call store_kernel_updates()

  ! statistics
  call min_all_cr(minval(model_dbulk),min_bulk)
  call max_all_cr(maxval(model_dbulk),max_bulk)

  call min_all_cr(minval(model_dbetav),min_vsv)
  call max_all_cr(maxval(model_dbetav),max_vsv)

  call min_all_cr(minval(model_dbetah),min_vsh)
  call max_all_cr(maxval(model_dbetah),max_vsh)

  call min_all_cr(minval(model_deta),min_eta)
  call max_all_cr(maxval(model_deta),max_eta)

  if (myrank == 0) then
    print*,'initial gradients:'
    print*,'  bulk min/max : ',min_bulk,max_bulk
    print*,'  betav min/max: ',min_vsv,max_vsv
    print*,'  betah min/max: ',min_vsh,max_vsh
    print*,'  eta min/max  : ',min_eta,max_eta
    print*
  endif

  ! determines maximum kernel betav value within given radius
  if (use_depth_maximum) then
    ! maximum of all processes stored in max_vsv
    call max_all_cr(max,max_vsv)
    max = max_vsv
    depth_max = 6371.0 *( 1.0 - depth_max )
  endif

  ! determines step length
  ! based on maximum gradient value (either vsv or vsh)
  if (myrank == 0) then

    ! determines maximum kernel betav value within given radius
    if (use_depth_maximum) then
      print*,'  using depth maximum between 50km and 100km: ',max
      print*,'  approximate depth maximum: ',depth_max
      print*
    else
      ! maximum gradient values
      minmax(1) = abs(min_vsv)
      minmax(2) = abs(max_vsv)
      minmax(3) = abs(min_vsh)
      minmax(4) = abs(max_vsh)

      ! maximum value of all kernel maxima
      max = maxval(minmax)
      print*,'  using maximum: ',max
      print*
    endif

    ! chooses step length such that it becomes the desired, given step factor as inputted
    step_length = step_fac/max

    print*,'  step length : ',step_length
    print*

  endif
  call bcast_all_singlecr(step_length)


  ! gradient length sqrt( v^T * v )
  norm_bulk = sum( model_dbulk * model_dbulk )
  norm_betav = sum( model_dbetav * model_dbetav )
  norm_betah = sum( model_dbetah * model_dbetah )
  norm_eta = sum( model_deta * model_deta )

  call sum_all_cr(norm_bulk,norm_bulk_sum)
  call sum_all_cr(norm_betav,norm_betav_sum)
  call sum_all_cr(norm_betah,norm_betah_sum)
  call sum_all_cr(norm_eta,norm_eta_sum)

  norm_bulk = sqrt(norm_bulk_sum)
  norm_betav = sqrt(norm_betav_sum)
  norm_betah = sqrt(norm_betah_sum)
  norm_eta = sqrt(norm_eta_sum)

  if (myrank == 0) then
    print*,'norm model updates:'
    print*,'  bulk : ',norm_bulk
    print*,'  betav: ',norm_betav
    print*,'  betah: ',norm_betah
    print*,'  eta  : ',norm_eta
    print*
  endif

  ! multiply model updates by a subjective factor that will change the step
  model_dbulk(:,:,:,:) = step_length * model_dbulk(:,:,:,:)
  model_dbetav(:,:,:,:) = step_length * model_dbetav(:,:,:,:)
  model_dbetah(:,:,:,:) = step_length * model_dbetah(:,:,:,:)
  model_deta(:,:,:,:) = step_length * model_deta(:,:,:,:)


  ! statistics
  call min_all_cr(minval(model_dbulk),min_bulk)
  call max_all_cr(maxval(model_dbulk),max_bulk)

  call min_all_cr(minval(model_dbetav),min_vsv)
  call max_all_cr(maxval(model_dbetav),max_vsv)

  call min_all_cr(minval(model_dbetah),min_vsh)
  call max_all_cr(maxval(model_dbetah),max_vsh)

  call min_all_cr(minval(model_deta),min_eta)
  call max_all_cr(maxval(model_deta),max_eta)

  if (myrank == 0) then
    print*,'scaled gradients:'
    print*,'  bulk min/max : ',min_bulk,max_bulk
    print*,'  betav min/max: ',min_vsv,max_vsv
    print*,'  betah min/max: ',min_vsh,max_vsh
    print*,'  eta min/max  : ',min_eta,max_eta
    print*
  endif

end subroutine get_gradient

!
!-------------------------------------------------------------------------------------------------
!

subroutine store_kernel_updates()

! file output for new model

  use model_update_tiso
  implicit none

  ! kernel updates
  fname = 'dbulk_c'
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_dbulk
  close(IOUT)

  fname = 'dbetav'
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_dbetav
  close(IOUT)

  fname = 'dbetah'
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_dbetah
  close(IOUT)

  fname = 'deta'
  write(m_file,'(a,i6.6,a)') 'INPUT_GRADIENT/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_deta
  close(IOUT)

end subroutine store_kernel_updates

!
!-------------------------------------------------------------------------------------------------
!

subroutine store_new_model()

! file output for new model

  use model_update_tiso
  implicit none

  ! vpv model
  call max_all_cr(maxval(model_vpv_new),max_vpv)
  call min_all_cr(minval(model_vpv_new),min_vpv)
  fname = 'vpv_new'
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_vpv_new
  close(IOUT)

  ! vph model
  call max_all_cr(maxval(model_vph_new),max_vph)
  call min_all_cr(minval(model_vph_new),min_vph)
  fname = 'vph_new'
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_vph_new
  close(IOUT)

  ! vsv model
  call max_all_cr(maxval(model_vsv_new),max_vsv)
  call min_all_cr(minval(model_vsv_new),min_vsv)
  fname = 'vsv_new'
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_vsv_new
  close(IOUT)

  ! vsh model
  call max_all_cr(maxval(model_vsh_new),max_vsh)
  call min_all_cr(minval(model_vsh_new),min_vsh)
  fname = 'vsh_new'
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_vsh_new
  close(IOUT)

  ! eta model
  call max_all_cr(maxval(model_eta_new),max_eta)
  call min_all_cr(minval(model_eta_new),min_eta)
  fname = 'eta_new'
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_eta_new
  close(IOUT)

  ! rho model
  call max_all_cr(maxval(model_rho_new),max_rho)
  call min_all_cr(minval(model_rho_new),min_rho)
  fname = 'rho_new'
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_'//trim(fname)//'.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) model_rho_new
  close(IOUT)


  if (myrank == 0) then
    print*,'new models:'
    print*,'  vpv min/max: ',min_vpv,max_vpv
    print*,'  vph min/max: ',min_vph,max_vph
    print*,'  vsv min/max: ',min_vsv,max_vsv
    print*,'  vsh min/max: ',min_vsh,max_vsh
    print*,'  eta min/max: ',min_eta,max_eta
    print*,'  rho min/max: ',min_rho,max_rho
    print*
  endif


end subroutine store_new_model

!
!-------------------------------------------------------------------------------------------------
!

subroutine store_perturbations()

! file output for new model

  use model_update_tiso
  implicit none
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: total_model

  ! vpv relative perturbations
  ! logarithmic perturbation: log( v_new) - log( v_old) = log( v_new / v_old )
  total_model = 0.0_CUSTOM_REAL
  where( model_vpv /= 0.0 ) total_model = log( model_vpv_new / model_vpv)
  ! or
  ! linear approximation: (v_new - v_old) / v_old
  !where( model_vpv /= 0.0 ) total_model = ( model_vpv_new - model_vpv) / model_vpv

  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_dvpvvpv.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) total_model
  close(IOUT)
  call max_all_cr(maxval(total_model),max_vpv)
  call min_all_cr(minval(total_model),min_vpv)

  ! vph relative perturbations
  total_model = 0.0_CUSTOM_REAL
  where( model_vph /= 0.0 ) total_model = log( model_vph_new / model_vph)
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_dvphvph.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) total_model
  close(IOUT)
  call max_all_cr(maxval(total_model),max_vph)
  call min_all_cr(minval(total_model),min_vph)

  ! vsv relative perturbations
  total_model = 0.0_CUSTOM_REAL
  where( model_vsv /= 0.0 ) total_model = log( model_vsv_new / model_vsv)
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_dvsvvsv.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) total_model
  close(IOUT)
  call max_all_cr(maxval(total_model),max_vsv)
  call min_all_cr(minval(total_model),min_vsv)

  ! vsh relative perturbations
  total_model = 0.0_CUSTOM_REAL
  where( model_vsh /= 0.0 ) total_model = log( model_vsh_new / model_vsh)
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_dvshvsh.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) total_model
  close(IOUT)
  call max_all_cr(maxval(total_model),max_vsh)
  call min_all_cr(minval(total_model),min_vsh)

  ! eta relative perturbations
  total_model = 0.0_CUSTOM_REAL
  where( model_eta /= 0.0 ) total_model = log( model_eta_new / model_eta)
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_detaeta.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) total_model
  close(IOUT)
  call max_all_cr(maxval(total_model),max_eta)
  call min_all_cr(minval(total_model),min_eta)

  ! rho relative model perturbations
  total_model = 0.0_CUSTOM_REAL
  where( model_rho /= 0.0 ) total_model = log( model_rho_new / model_rho)
  write(m_file,'(a,i6.6,a)') 'OUTPUT_MODEL/proc',myrank,'_reg1_drhorho.bin'
  open(IOUT,file=trim(m_file),form='unformatted',action='write')
  write(IOUT) total_model
  close(IOUT)
  call max_all_cr(maxval(total_model),max_rho)
  call min_all_cr(minval(total_model),min_rho)

  if (myrank == 0) then
    print*,'relative update:'
    print*,'  dvpv/vpv min/max: ',min_vpv,max_vpv
    print*,'  dvph/vph min/max: ',min_vph,max_vph
    print*,'  dvsv/vsv min/max: ',min_vsv,max_vsv
    print*,'  dvsh/vsh min/max: ',min_vsh,max_vsh
    print*,'  deta/eta min/max: ',min_eta,max_eta
    print*,'  drho/rho min/max: ',min_rho,max_rho
    print*
  endif

end subroutine store_perturbations

!
!-------------------------------------------------------------------------------------------------
!

subroutine compute_volume()

! computes volume element associated with points

  use model_update_tiso
  implicit none
  ! jacobian
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: jacobian
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC) :: &
    xix,xiy,xiz,etax,etay,etaz,gammax,gammay,gammaz
  real(kind=CUSTOM_REAL) xixl,xiyl,xizl,etaxl,etayl,etazl,gammaxl,gammayl,gammazl, &
    jacobianl,volumel
  ! integration values
  real(kind=CUSTOM_REAL) :: integral_bulk_sum,integral_betav_sum, &
    integral_betah_sum,integral_eta_sum
  real(kind=CUSTOM_REAL) :: integral_bulk,integral_betav,&
    integral_betah,integral_eta
  real(kind=CUSTOM_REAL) :: volume_glob,volume_glob_sum
  ! root-mean square values
  real(kind=CUSTOM_REAL) :: rms_vpv,rms_vph,rms_vsv,rms_vsh,rms_eta,rms_rho
  real(kind=CUSTOM_REAL) :: rms_vpv_sum,rms_vph_sum,rms_vsv_sum,rms_vsh_sum, &
    rms_eta_sum,rms_rho_sum
  real(kind=CUSTOM_REAL) :: dvpv,dvph,dvsv,dvsh,deta,drho
  ! dummy
  real(kind=CUSTOM_REAL),dimension(NGLOB) :: dummy
  integer :: ival

  ! Gauss-Lobatto-Legendre points of integration and weights
  double precision, dimension(NGLLX) :: xigll, wxgll
  double precision, dimension(NGLLY) :: yigll, wygll
  double precision, dimension(NGLLZ) :: zigll, wzgll
  ! array with all the weights in the cube
  double precision, dimension(NGLLX,NGLLY,NGLLZ) :: wgll_cube

  ! GLL points
  wgll_cube = 0.0d0
  call zwgljd(xigll,wxgll,NGLLX,GAUSSALPHA,GAUSSBETA)
  call zwgljd(yigll,wygll,NGLLY,GAUSSALPHA,GAUSSBETA)
  call zwgljd(zigll,wzgll,NGLLZ,GAUSSALPHA,GAUSSBETA)
  do k=1,NGLLZ
    do j=1,NGLLY
      do i=1,NGLLX
        wgll_cube(i,j,k) = wxgll(i)*wygll(j)*wzgll(k)
      enddo
    enddo
  enddo

  ! builds jacobian
  write(m_file,'(a,i6.6,a)') 'topo/proc',myrank,'_reg1_solver_data.bin'
  open(IIN,file=trim(m_file),status='old',form='unformatted',iostat=ier)
  if (ier /= 0) then
    print*,'Error opening: ',trim(m_file)
    call exit_mpi(myrank,'file not found')
  endif

  read(IIN) ival ! nspec
  read(IIN) ival ! nglob

  read(IIN) dummy ! x
  read(IIN) dummy ! y
  read(IIN) dummy ! z

  read(IIN) ibool(:,:,:,1:nspec)
  read(IIN) idoubling(1:nspec)
  read(IIN) ispec_is_tiso(1:nspec)

  read(IIN) xix
  read(IIN) xiy
  read(IIN) xiz
  read(IIN) etax
  read(IIN) etay
  read(IIN) etaz
  read(IIN) gammax
  read(IIN) gammay
  read(IIN) gammaz
  close(IIN)

  jacobian = 0.0
  do ispec = 1, NSPEC
    do k = 1, NGLLZ
      do j = 1, NGLLY
        do i = 1, NGLLX
          ! gets derivatives of ux, uy and uz with respect to x, y and z
          xixl = xix(i,j,k,ispec)
          xiyl = xiy(i,j,k,ispec)
          xizl = xiz(i,j,k,ispec)
          etaxl = etax(i,j,k,ispec)
          etayl = etay(i,j,k,ispec)
          etazl = etaz(i,j,k,ispec)
          gammaxl = gammax(i,j,k,ispec)
          gammayl = gammay(i,j,k,ispec)
          gammazl = gammaz(i,j,k,ispec)
          ! computes the jacobian
          jacobianl = 1._CUSTOM_REAL / (xixl*(etayl*gammazl-etazl*gammayl) &
                        - xiyl*(etaxl*gammazl-etazl*gammaxl) &
                        + xizl*(etaxl*gammayl-etayl*gammaxl))
          jacobian(i,j,k,ispec) = jacobianl

          !if (abs(jacobianl) < 1.e-8 ) then
          !  print*,'rank ',myrank,'jacobian: ',jacobianl,i,j,k,wgll_cube(i,j,k)
          !endif

        enddo
      enddo
    enddo
  enddo

  ! volume associated with global point
  volume_glob = 0._CUSTOM_REAL
  integral_bulk = 0._CUSTOM_REAL
  integral_betav = 0._CUSTOM_REAL
  integral_betah = 0._CUSTOM_REAL
  integral_eta = 0._CUSTOM_REAL
  norm_bulk = 0._CUSTOM_REAL
  norm_betav = 0._CUSTOM_REAL
  norm_betah = 0._CUSTOM_REAL
  norm_eta = 0._CUSTOM_REAL
  rms_vpv = 0._CUSTOM_REAL
  rms_vph = 0._CUSTOM_REAL
  rms_vsv = 0._CUSTOM_REAL
  rms_vsh = 0._CUSTOM_REAL
  rms_eta = 0._CUSTOM_REAL
  rms_rho = 0._CUSTOM_REAL
  do ispec = 1, NSPEC
    do k = 1, NGLLZ
      do j = 1, NGLLY
        do i = 1, NGLLX
          iglob = ibool(i,j,k,ispec)
          if (iglob == 0) then
            print*,'iglob zero',i,j,k,ispec
            print*
            print*,'ibool:',ispec
            print*,ibool(:,:,:,ispec)
            print*
            call exit_MPI(myrank,'Error ibool')
          endif

          ! volume associated with GLL point
          volumel = jacobian(i,j,k,ispec)*wgll_cube(i,j,k)
          volume_glob = volume_glob + volumel

          ! kernel integration: for each element
          integral_bulk = integral_bulk &
                                 + volumel * kernel_bulk(i,j,k,ispec)

          integral_betav = integral_betav &
                                 + volumel * kernel_betav(i,j,k,ispec)

          integral_betah = integral_betah &
                                 + volumel * kernel_betah(i,j,k,ispec)

          integral_eta = integral_eta &
                                 + volumel * kernel_eta(i,j,k,ispec)

          ! gradient vector norm sqrt(  v^T * v )
          norm_bulk = norm_bulk + kernel_bulk(i,j,k,ispec)*kernel_bulk(i,j,k,ispec)
          norm_betav = norm_betav + kernel_betav(i,j,k,ispec)*kernel_betav(i,j,k,ispec)
          norm_betah = norm_betah + kernel_betah(i,j,k,ispec)*kernel_betah(i,j,k,ispec)
          norm_eta = norm_eta + kernel_eta(i,j,k,ispec)*kernel_eta(i,j,k,ispec)

          ! checks number
          if (isNaN(integral_bulk)) then
            print*,'Error NaN: ',integral_bulk
            print*,'rank:',myrank
            print*,'i,j,k,ispec:',i,j,k,ispec
            print*,'volumel: ',volumel,'kernel_bulk:',kernel_bulk(i,j,k,ispec)
            call exit_MPI(myrank,'Error NaN')
          endif

          ! root-mean square
          ! integrates relative perturbations ( dv / v  using logarithm ) squared
          dvpv = log( model_vpv_new(i,j,k,ispec) / model_vpv(i,j,k,ispec) ) ! alphav
          rms_vpv = rms_vpv + volumel * dvpv*dvpv

          dvph = log( model_vph_new(i,j,k,ispec) / model_vph(i,j,k,ispec) ) ! alphah
          rms_vph = rms_vph + volumel * dvph*dvph

          dvsv = log( model_vsv_new(i,j,k,ispec) / model_vsv(i,j,k,ispec) ) ! betav
          rms_vsv = rms_vsv + volumel * dvsv*dvsv

          dvsh = log( model_vsh_new(i,j,k,ispec) / model_vsh(i,j,k,ispec) ) ! betah
          rms_vsh = rms_vsh + volumel * dvsh*dvsh

          deta = log( model_eta_new(i,j,k,ispec) / model_eta(i,j,k,ispec) ) ! eta
          rms_eta = rms_eta + volumel * deta*deta

          drho = log( model_rho_new(i,j,k,ispec) / model_rho(i,j,k,ispec) ) ! rho
          rms_rho = rms_rho + volumel * drho*drho

        enddo
      enddo
    enddo
  enddo

  ! statistics
  ! kernel integration: for whole volume
  call sum_all_cr(integral_bulk,integral_bulk_sum)
  call sum_all_cr(integral_betav,integral_betav_sum)
  call sum_all_cr(integral_betah,integral_betah_sum)
  call sum_all_cr(integral_eta,integral_eta_sum)
  call sum_all_cr(volume_glob,volume_glob_sum)

  if (myrank == 0) then
    print*,'integral kernels:'
    print*,'  bulk : ',integral_bulk_sum
    print*,'  betav : ',integral_betav_sum
    print*,'  betah : ',integral_betah_sum
    print*,'  eta : ',integral_eta_sum
    print*
    print*,'  total volume:',volume_glob_sum
    print*
  endif

  ! norms: for whole volume
  call sum_all_cr(norm_bulk,norm_bulk_sum)
  call sum_all_cr(norm_betav,norm_betav_sum)
  call sum_all_cr(norm_betah,norm_betah_sum)
  call sum_all_cr(norm_eta,norm_eta_sum)
  norm_bulk = sqrt(norm_bulk_sum)
  norm_betav = sqrt(norm_betav_sum)
  norm_betah = sqrt(norm_betah_sum)
  norm_eta = sqrt(norm_eta_sum)

  if (myrank == 0) then
    print*,'norm kernels:'
    print*,'  bulk : ',norm_bulk
    print*,'  betav : ',norm_betav
    print*,'  betah : ',norm_betah
    print*,'  eta : ',norm_eta
    print*
  endif

  ! root-mean square
  call sum_all_cr(rms_vpv,rms_vpv_sum)
  call sum_all_cr(rms_vph,rms_vph_sum)
  call sum_all_cr(rms_vsv,rms_vsv_sum)
  call sum_all_cr(rms_vsh,rms_vsh_sum)
  call sum_all_cr(rms_eta,rms_eta_sum)
  call sum_all_cr(rms_rho,rms_rho_sum)
  rms_vpv = sqrt( rms_vpv_sum / volume_glob_sum )
  rms_vph = sqrt( rms_vph_sum / volume_glob_sum )
  rms_vsv = sqrt( rms_vsv_sum / volume_glob_sum )
  rms_vsh = sqrt( rms_vsh_sum / volume_glob_sum )
  rms_eta = sqrt( rms_eta_sum / volume_glob_sum )
  rms_rho = sqrt( rms_rho_sum / volume_glob_sum )

  if (myrank == 0) then
    print*,'root-mean square of perturbations:'
    print*,'  vpv : ',rms_vpv
    print*,'  vph : ',rms_vph
    print*,'  vsv : ',rms_vsv
    print*,'  vsh : ',rms_vsh
    print*,'  eta : ',rms_eta
    print*,'  rho : ',rms_rho
    print*
  endif

end subroutine compute_volume
