#' -----------------------------------------------------------------------------
#' OKP Healthcare Cost Forecasting – Modular Evaluation Script
#' -----------------------------------------------------------------------------
#' @file        okp_forecast_evaluation.R
#' @author      Raphaël Radzuweit
#' @date        2025‑05‑18
#' @license     Proprietary License, file LICENSE
#'
#' @title Out‑of‑Sample Forecast Evaluation for Swiss Healthcare Costs
#'
#' @description
#' This script performs a rigorous, rolling‑origin evaluation of quarterly
#' healthcare costs per insured in Switzerland (OKP system). Three benchmark
#' models are compared across an eight‑quarter horizon:
#'
#' * **Seasonal ARIMA** – (1,1,1)(1,0,1)[4] with drift
#' * **Random Walk with Drift** – ARIMA(0,1,0)+drift
#' * **Structural Time Series** – local‑level + deterministic quarterly seasonality
#'   estimated via **KFAS** (Kalman filter / smoother)
#'
#' The codebase is fully modular – each logical step (data ingestion, model
#' fitting, forecasting, evaluation, plotting) lives in a self‑contained,
#' unit‑testable function and is documented using **roxygen2** tags.  Running
#' `main()` executes the entire pipeline and produces: (i) a tidy RMSE table
#' and (ii) two diagnostic plots (RMSE‑by‑horizon line chart, fan chart of all
#' forecast trajectories).
#'
#' ## Usage
#' ```r
#' source("okp_forecast_evaluation.R")  # brings all functions into scope
#' main()                                # run end‑to‑end study
#' ```
#'
#' ## Session Info (for reproducibility)
#' * R version 4.4.0 (nickname: "Puppy Cup")
#' * tidyverse 2.0.0
#' * forecast  8.23
#' * KFAS      1.5‑3
#' * zoo       1.8‑12
#' -----------------------------------------------------------------------------

# ---------------------------- Libraries --------------------------------------
# Use explicit calls so `renv::snapshot()` captures them.
library(tidyverse)    # dplyr, purrr, ggplot2, tidyr
library(lubridate)    # date manipulation helpers
library(zoo)          # yearqtr ⇄ Date conversion
library(readxl)       # XLSX import
library(forecast)     # ARIMA / naïve benchmarks
library(KFAS)         # structural time‑series & Kalman smoother
source("R/rmse_utils.R")
source("R/out_of_sample_plot_utils.R")
source("R/data_utils.R")
source("R/multivariate_kalman_utils.R")
source("R/forecast_utils.R")
source("R/growth_utils.R")

# ---------------------------- Constants --------------------------------------
FILE_PATH        <- "02_Monitoring-des-couts_Serie-temporelle-trimestre.xlsx"  # raw data
FORECAST_HORIZON <- 8      # eight quarters ≙ two years
CANTON           <- "Suisse"
COST_GROUP       <- "Total"  # default cost basket

# Corporate visual identity (neutral grey scale, printer‑friendly)
GREY_PALETTE <- c(Kalman = "#444444", ARMA = "#888888", RW = "#BBBBBB")
LINETYPES    <- c(Kalman = "solid", ARMA = "dashed", RW = "dotted", Actual = "solid")

#' ------------------------- Main Orchestration ------------------------------
#' @title End‑to‑End Pipeline
#' @description Execute data loading, model estimation, evaluation, and
#'   diagnostic plotting in a single call.
#' @return Invisibly returns a list with components `rmse_table`, `rmse_plot`,
#'   and `fan_chart` for further manipulation.
#' @export
main <- function(file_path = FILE_PATH,
                 horizon    = FORECAST_HORIZON,
                 verbose    = TRUE,
                 plots      = TRUE) {
  # ---------------------------------------------------------------------------
  # 1 ▸ Data ingest ------------------------------------------------------------
  # ---------------------------------------------------------------------------
  raw_data <- load_okp_dataset(file_path)
  canton_df<- extract_series(raw_data)
  series   <- build_quarterly_ts(canton_df)
  y      <- series$ts
  dates  <- series$dates
  covid_dummy <- as.numeric(dates >= as.Date("2020-04-01") &
                              dates <= as.Date("2021-12-31"))
  covid_ts    <- ts(covid_dummy,
                    start = start(y),
                    frequency = frequency(y))
  
  # ---------------------------------------------------------------------------
  # ▸ Kalman smoother to estimate actual series (2016–2024) -------------------
  # ---------------------------------------------------------------------------
  model_kalman <- SSModel(y ~ covid_ts + SSMtrend(2, Q = list(NA, NA)) +
                            SSMseasonal(period = 4, sea.type = "dummy", Q = NA),
                          H = NA)
  fit_kalman <- fitSSM(model_kalman, inits = rep(log(var(y) * 10), 4))
  smooth_kalman <- KFS(fit_kalman$model, smoothing = "state")
  
  # Extract smoothed level + seasonality
  smoothed_vals <- rowSums(smooth_kalman$alphahat)
  kalman_actual_estimates <- tibble(
    Date = dates,
    Value = as.numeric(smoothed_vals),
    Model = "Kalman_Smoothed"
  )
  
  # Save to global environment
  assign("kalman_smoothed", kalman_actual_estimates, envir = .GlobalEnv)
  
  # ---------------------------------------------------------------------------
  # 2 ▸ Forecast generation (historical roll + future fan) --------------------
  # ---------------------------------------------------------------------------
  fc_hist <- rolling_origin_forecasts(y, dates, horizon, covid_ts)
  fc_fut  <- final_forecasts(y, dates, horizon, covid_ts)
  forecast_df <- dplyr::bind_rows(fc_hist, fc_fut)
  assign("kalman_forecast", forecast_df, envir = .GlobalEnv)
  
  # ---------------------------------------------------------------------------
  # 3 ▸ Actual observations table --------------------------------------------
  # ---------------------------------------------------------------------------
  actual_df <- tibble(Date = dates,
                      Value = as.numeric(y),
                      Model = "Actual")

  # ---------------------------------------------------------------------------
  # 4 ▸ Year-over-year growth tables ------------------------------------------
  # ---------------------------------------------------------------------------
  yoy_actual   <- compute_yoy_growth(actual_df)
  yoy_forecast <- compute_yoy_growth(forecast_df, actuals = actual_df)
  
  # ---------------------------------------------------------------------------
  # 5 ▸ RMSE evaluation -------------------------------------------------------
  # ---------------------------------------------------------------------------
  rmse_tbl <- compute_rmse_table(forecast_df, actual_df, horizon)
  
  # ---------------------------------------------------------------------------
  # 6 ▸ Prepare scored long table (for plotting) ------------------------------
  # ---------------------------------------------------------------------------
  scored_long <- forecast_df %>%
    dplyr::left_join(actual_df %>% rename(True = Value) %>% dplyr::select(Date, True), by = "Date") %>%
    dplyr::mutate(Horizon = as.integer((Date - Origin) / lubridate::dmonths(3))) %>%
    dplyr::filter(dplyr::between(Horizon, 1, horizon))
  
  # ---------------------------------------------------------------------------
  # 7 ▸ Diagnostics plots -----------------------------------------------------
  # ---------------------------------------------------------------------------
  rmse_plot <- plot_rmse(scored_long)
  fan_chart <- plot_forecast_paths(forecast_df, actual_df)
  
  # ---------------------------------------------------------------------------
  # 8 ▸ Output handling -------------------------------------------------------
  # ---------------------------------------------------------------------------
  if (verbose) {
    print(rmse_tbl)
    latest_kalman <- yoy_forecast %>%
    dplyr::filter(Model == "Kalman") %>%
    dplyr::filter(Origin == max(Origin)) %>%
      dplyr::arrange(Date)
    print(latest_kalman, n = nrow(latest_kalman))
  }
  if (plots) {
    print(rmse_plot)
    print(fan_chart)
  }

  invisible(list(
    rmse_table = rmse_tbl,
    rmse_plot  = rmse_plot,
    fan_chart  = fan_chart,
    forecasts  = forecast_df,
    actual     = actual_df,
    yoy_forecast = yoy_forecast,
    yoy_actual   = yoy_actual
  ))
}
