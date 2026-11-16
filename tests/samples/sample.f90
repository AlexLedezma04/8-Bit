! Sum of squares.
program squares
  implicit none
  integer :: i, total
  total = 0
  do i = 1, 10
    total = total + i**2
  end do
  print *, "total: ", total, .true.
end program squares
