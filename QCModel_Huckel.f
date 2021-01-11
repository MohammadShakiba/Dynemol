#include "GPU.h"

 module QCModel_Huckel

    use f95_precision
    use blas95
    use lapack95
    use type_m
    use omp_lib
    use constants_m
    use parameters_m     , only : EnvField_ , Induced_ , driver , verbose , restart , SOC 
    use Overlap_Builder  , only : Overlap_Matrix
    use Hamiltonians     , only : X_ij , even_more_extended_Huckel , spin_orbit_h
    use Matrix_Math

    public :: EigenSystem , S_root_inv 

    private

    interface EigenSystem
        module procedure EigenSystem
        module procedure EigenSystem_just_erg
    end interface

    ! module variables ...
    real*8 , allocatable :: S_root_inv(:,:) 

 contains
!
!
!
!==================================================
 subroutine EigenSystem( system , basis , QM , it )
!==================================================
use Matrix_math
implicit none
type(structure)             , intent(in)    :: system
type(STO_basis)             , intent(in)    :: basis(:)
type(C_eigen)               , intent(inout) :: QM
integer          , optional , intent(in)    :: it


! local variables ...
complex*16 , ALLOCATABLE :: h_spin(:,:) , h(:,:) , dumb_S(:,:) , S_complex(:,:)
complex*16 , ALLOCATABLE :: Lv(:,:) , Rv(:,:) 
real*8     , ALLOCATABLE :: h_orb(:,:)  , S_matrix(:,:) , S_root(:,:)
real*8     , ALLOCATABLE :: tool(:,:) , S_eigen(:)
integer                  :: i , N , info 
logical    , save        :: first_call_ = .true.

!xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

N = size(basis)

CALL Overlap_Matrix( system , basis , S_matrix )

If( .NOT. allocated(QM%erg) ) ALLOCATE(QM%erg(N))

Allocate(  h_orb(N,N) )
Allocate( dumb_S(N,N) )

! clone S_matrix because HEGVD will destroy it ...
dumb_s = dcmplx( S_matrix , D_zero )

If( EnvField_ .OR. Induced_ ) then
  h_orb(:,:) = even_more_extended_Huckel( system , basis , S_matrix , it ) 
else
  h_orb(:,:) = Build_Huckel( basis , S_matrix ) 
end If

if( SOC ) then

    CALL spin_orbit_h( basis , h_spin , S_matrix )
    allocate( h(N,N) , source = dcmplx( h_orb , D_zero ) + h_spin )
!    allocate( h(N,N) , source = dcmplx( h_orb , D_zero ) )
    deallocate( h_spin )

else

    allocate( h(N,N) , source = dcmplx( h_orb , D_zero ) )

end if

deallocate(h_orb)

CALL HEGVD( h , dumb_S , QM%erg , 1 , 'V' , 'L' , info )
if ( info /= 0 ) write(*,*) 'info = ',info,' in HEGVD in EigenSystem '

select case ( driver ) 

    case default

          !---------------------------------------------------
          !   ROTATES THE HAMILTONIAN:  H --> H*S_inv 
          !
          !   RIGHT EIGENVECTOR ALSO CHANGE: |C> --> S.|C> 
          !
          !   normalizes the L&R eigenvectors as < L(i) | R(i) > = 1 
          !---------------------------------------------------

          Allocate( Lv(N,N) )
          Allocate( Rv(N,N) )

          Lv = h
          Deallocate(h)

          If( .NOT. allocated(QM%L) ) ALLOCATE(QM%L(N,N)) 
          ! eigenvectors in the rows of QM%L
          QM%L = transpose(Lv) 

          allocate( S_complex , source = dcmplx(S_matrix,D_zero) )
          ! Rv = S * Lv ...
          call hemm( S_complex, Lv, Rv )
          deallocate( S_matrix , S_complex )

          If( .NOT. ALLOCATED(QM%R) ) ALLOCATE(QM%R(N,N))
          ! eigenvectors in the columns of QM%R
          QM%R = Rv

    case ("slice_FSSH" )    

          !--------------------------------------------------------
          ! Overlap Matrix Factorization: S^(1/2) ...

!          dumb_s = S_matrix
!
!          Allocate( S_eigen(N)  )
!
!          CALL SYEVD(dumb_S , S_eigen , 'V' , 'L' , info)
!
!          Allocate( tool(N,N) , source = transpose(dumb_S) )
!
!          forall( i=1:N ) tool(:,i) = sqrt(S_eigen) * tool(:,i)
!
!          allocate( S_root(N,N) )
!          CALL gemm(dumb_S , tool , S_root , 'N' , 'N')
!
!          !now S_root   = S^(1/2) Lowdin Orthogonalization matrix ...
!          !now S_matrix = S ...
!
!          DEALLOCATE( S_eigen , tool )
!!          DEALLOCATE( S_eigen , dumb_S , tool )
!
!          dumb_S = S_matrix
!
!          !---------------------------------------------------
!          !RIGHT EIGENVECTOR ALSO CHANGE: |C> --> S^(1/2).|C> 
!          !
!          !normalizes the L&R eigenvectors as < L(i) | R(i) > = 1
!          !---------------------------------------------------
!
!          Allocate( Lv(N,N) )
!          Allocate( Rv(N,N) )
!
!          Lv = h
!          Deallocate( h )
!
!          If( .NOT. allocated(QM%L) ) ALLOCATE(QM%L(N,N)) 
!          ! eigenvectors in the rows of QM%L
!          ! keeping the nonorthogonal representation of %L for future use ...
!          QM%L = transpose(Lv) 
!
!          If( first_call_ .AND. (.NOT. restart) ) then
!
!              ! Rv = S * Lv ...
!              call symm( S_matrix, Lv, Rv )
!              call invert( S_root )
!              first_call_ = .false.
!          else
!
!              ! Rv = S^(1/2) * Lv ...
!              ! Lowding representation ...
!              CALL symm( S_root , Lv , Rv )
!          end If
!
!          If( .NOT. ALLOCATED(QM%R) ) ALLOCATE(QM%R(N,N))
!          ! eigenvectors in the columns of QM%R
!          QM%R = Rv
!          
!          Deallocate( Lv , Rv , S_matrix , S_root )

end select

!xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
! save energies of the TOTAL system ...
OPEN(unit=9,file='system-ergs.dat',status='unknown')
    do i = 1 , N
!        write(9,*) i , QM%erg(i)
        write(9,fmt='(i5,3f20.14)') i , QM%erg(i) , dreal(dot_product( QM%L(i,:) , QM%R(:,i) )) , &
                                                    dreal(dot_product( QM%L(i,:) , dcmplx( basis( : ) % s , D_zero ) * QM%R(:,i) ))
    end do
close(9)

If( verbose ) Print*, '>> EigenSystem done <<'

end subroutine EigenSystem
!
!
!
!===================================================
 function Build_Huckel( basis , S_matrix ) result(h)
!===================================================
implicit none
type(STO_basis) , intent(in) :: basis(:)
real*8          , intent(in) :: S_matrix(:,:)

! local variables ... 
real*8  , allocatable :: h(:,:)
integer :: i , j , N , N2

!----------------------------------------------------------
!      building  the  HUCKEL  HAMILTONIAN
!----------------------------------------------------------

N  = size(basis)
N2 = merge(N/2,N,SOC)

ALLOCATE( h(N,N) , source = D_zero )

! spin up orbital block
do j = 1 , N2
    do i = j , N2

        h(i,j) = X_ij( i , j , basis ) * S_matrix(i,j) 

    end do
end do

! spin down orbital block
if( SOC ) h( N2 + 1 : N , N2 + 1 : N ) = h( 1 : N2 , 1 : N2 )

end function Build_Huckel
!
!
!
!=======================================================
 subroutine EigenSystem_just_erg( system , basis , erg )
!=======================================================
 implicit none
 type(structure)  , intent(in)    :: system
 type(STO_basis)  , intent(in)    :: basis(:)
 real*8           , intent(out)   :: erg( size(basis) )

! local variables ...
 real*8  , ALLOCATABLE :: h(:,:) , S_matrix(:,:)
 integer               :: i , j , N , info 

 N = size(basis)

 CALL Overlap_Matrix(system,basis,S_matrix)

 ALLOCATE( h(N,N) )

 If( EnvField_ ) then

    h(:,:) = even_more_extended_Huckel( system , basis , S_matrix ) 

 else

    do j = 1 , N
        do i = 1 , j
     
            h(i,j) = X_ij( i , j , basis ) * S_matrix(i,j)

        end do
    end do  

 end If

 CALL SYGVD(h,S_matrix,erg,1,'N','U',info)

 If ( info /= 0 ) write(*,*) 'info = ',info,' in SYGVD in EigenSystem '

 DEALLOCATE( h , S_matrix )

 end subroutine EigenSystem_just_erg
!
!
!
!===========================
 subroutine invert( matrix )
!===========================
implicit none
real*8  , intent(inout) :: matrix(:,:) 

!local variables ...
integer :: N

N = size(matrix(:,1))

CALL syInvert( matrix, return_full ) ! <== matrix content is destroyed and matrix_inv is returned
#define matrix_inv matrix
allocate( S_root_inv(N,N) , source = matrix_inv )
#undef matrix_inv

end subroutine invert
!
!
!
end module QCModel_Huckel
