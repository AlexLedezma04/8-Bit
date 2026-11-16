# Summary of a vector.
values <- c(1.5, 2, NA, 4)
mean_value <- function(x, na.rm = TRUE) {
  if (is.null(x)) return(NULL)
  mean(x, na.rm = na.rm)
}
print(paste("mean:", mean_value(values)))
