# build.R — Render agent-failure-taxonomy.Rmd to PDF
#
# Requirements:
#   install.packages(c("rmarkdown", "tinytex", "dplyr", "ggplot2",
#                      "tidyr", "stringr", "scales", "forcats",
#                      "knitr", "kableExtra"))
#   tinytex::install_tinytex()  # only needed once
#
# Data prerequisite:
#   data/runs_coded.csv must exist (see data/DATA-COLLECTION.md)
#   Without it, the paper renders with placeholder charts (no data).
#
# Run:
#   Rscript build.R

required <- c("rmarkdown", "tinytex", "dplyr", "ggplot2", "tidyr",
              "stringr", "scales", "forcats", "knitr", "kableExtra")
missing <- required[!sapply(required, requireNamespace, quietly = TRUE)]
if (length(missing) > 0) {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
}

if (!tinytex::is_tinytex()) {
  message("Installing TinyTeX (one-time, ~200 MB)...")
  tinytex::install_tinytex()
}

# Install required LaTeX packages
tinytex::tlmgr_install(c("setspace", "titlesec", "fancyhdr",
                          "microtype", "booktabs", "float",
                          "kableExtra"))

rmarkdown::render(
  input       = "agent-failure-taxonomy.Rmd",
  output_file = "agent-failure-taxonomy.pdf",
  clean       = TRUE
)

message("\n✅  Output: agent-failure-taxonomy.pdf")
